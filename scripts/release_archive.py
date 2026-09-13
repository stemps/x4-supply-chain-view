"""Runtime archive selection and verification shared by local and public builds."""
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import zipfile


class ReleaseError(Exception):
    pass


def runtime_path(name):
    path = PurePosixPath(name)
    return (not path.is_absolute() and '..' not in path.parts and '\\' not in name
            and (name in ('content.xml', 'ui.xml')
                 or (name.startswith('ui/') and name.endswith('.lua'))
                 or (name.startswith('t/') and name.endswith('.xml'))))


def git_bytes(root, *args, data=None):
    result = subprocess.run(['git', *args], cwd=root, input=data, capture_output=True)
    if result.returncode:
        raise ReleaseError(result.stderr.decode('utf-8', errors='replace').strip()
                           or 'Git command failed')
    return result.stdout


def working_files(root, local=False):
    args = ['ls-files', '-z', '--cached']
    if local:
        args += ['--others', '--exclude-standard']
    names = git_bytes(root, *args).decode().split('\0')
    files = sorted({name for name in names if runtime_path(name)})
    if local:
        files = [name for name in files if (root / name).exists() or (root / name).is_symlink()]
    require_manifests(files)
    for name in files:
        path = root / name
        if path.is_symlink() or root.resolve() not in path.resolve().parents:
            raise ReleaseError(f'Runtime symlinks cannot be packaged: {name}')
        if any(parent.is_symlink() for parent in path.parents if parent != root.parent):
            raise ReleaseError(f'Runtime symlink directory: {name}')
    return files


def require_manifests(files):
    if not {'content.xml', 'ui.xml'}.issubset(files):
        raise ReleaseError('Missing runtime manifests: content.xml and ui.xml are required.')


def write_zip(path, files, read):
    """Use fixed ZIP metadata, making reconstruction from identical bytes reproducible."""
    require_manifests(files)
    with zipfile.ZipFile(path, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            info = zipfile.ZipInfo('supply_chain_view/' + name)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, read(name))
    verify_zip(path, files, lambda name, data: data == read(name))


def verify_zip(path, files, matches):
    with zipfile.ZipFile(path) as archive:
        if archive.namelist() != ['supply_chain_view/' + name for name in files] or archive.testzip():
            raise ReleaseError('Archive integrity or membership verification failed.')
        for name in files:
            if not matches(name, archive.read('supply_chain_view/' + name)):
                raise ReleaseError(f'Archive differs from source: {name}')


def local_zip(root):
    root = Path(root).resolve()
    files = working_files(root, local=True)
    final = root / 'dist' / 'Supply-Chain-View-local.zip'
    final.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='scv-local-', dir=final.parent) as directory:
        temporary = Path(directory) / final.name
        write_zip(temporary, files, lambda name: (root / name).read_bytes())
        temporary.replace(final)
    print(f'Local ZIP: {final}')
    return final


def tagged_zip(root, tag):
    """Verify remote identity and package blobs without checking out the release."""
    from xml.etree import ElementTree
    import re
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag):
        raise ReleaseError('Expected a release tag: vX.Y.Z')
    ref = 'refs/tags/' + tag
    tag_object = git_bytes(root, 'rev-parse', ref).decode().strip()
    if git_bytes(root, 'cat-file', '-t', tag_object).strip() != b'tag':
        raise ReleaseError('Publication requires an annotated release tag.')
    commit = git_bytes(root, 'rev-parse', ref + '^{commit}').decode().strip()
    remote = dict(line.split()[::-1] for line in
                  git_bytes(root, 'ls-remote', 'origin', ref, ref + '^{}').decode().splitlines())
    if remote.get(ref) != tag_object or remote.get(ref + '^{}') != commit:
        raise ReleaseError('Local and remote release tags do not match.')
    read = lambda name: git_bytes(root, 'show', f'{commit}:{name}')
    if read('VERSION').decode().strip() != tag[1:]:
        raise ReleaseError('Tagged VERSION disagrees with the release tag.')
    parts = tuple(map(int, tag[1:].split('.')))
    if parts[1] >= 100 or parts[2] >= 100:
        raise ReleaseError('Minor and patch must be below 100.')
    manifest = ElementTree.fromstring(read('content.xml'))
    if manifest.get('version') != str(parts[0] * 10000 + parts[1] * 100 + parts[2]):
        raise ReleaseError('Tagged manifest version disagrees with the release tag.')
    entries = git_bytes(root, 'ls-tree', '-rz', commit).decode().split('\0')
    files = []
    for entry in filter(None, entries):
        attributes, name = entry.split('\t', 1)
        if runtime_path(name):
            if not attributes.startswith(('100644 blob ', '100755 blob ')):
                raise ReleaseError(f'Unsupported runtime entry: {name}')
            files.append(name)
    files.sort()
    require_manifests(files)
    final = root / 'dist' / f'Supply-Chain-View-{tag[1:]}.zip'
    final.parent.mkdir(exist_ok=True)
    if final.exists():
        # Older release ZIPs can contain checkout line endings. Apply Git's clean
        # filters, as the original release script does, when validating them.
        verify_zip(final, files, lambda name, data:
                   git_bytes(root, 'hash-object', '--stdin', '--path', name, data=data).strip()
                   == git_bytes(root, 'rev-parse', f'{commit}:{name}').strip())
    else:
        with tempfile.TemporaryDirectory(prefix='scv-tag-', dir=final.parent) as directory:
            temporary = Path(directory) / final.name
            write_zip(temporary, files, read)
            # No overwrites of a concurrently created public release archive.
            with final.open('xb') as output:
                output.write(temporary.read_bytes())
    annotation = git_bytes(root, 'cat-file', 'tag', tag_object).split(b'\n\n', 1)[1].decode().strip()
    if not annotation:
        raise ReleaseError('Release tag has no reviewed notes.')
    return final, commit, annotation
