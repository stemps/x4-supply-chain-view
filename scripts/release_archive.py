"""Release archives of the src/ mod folder, shared by local and public builds."""
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import zipfile


class ReleaseError(Exception):
    pass


# The mod is exactly this folder: the game's dev junction points at it and every
# file in it ships. Names inside the package are relative to it.
MOD = 'src'


def repo_path(name):
    return f'{MOD}/{name}'


def identity(manifest):
    """(package folder, archive name prefix) from content.xml bytes: its id and name.

    Every mod-specific name in the release tooling comes from here, so the
    tooling itself is identical across mods.
    """
    from xml.etree import ElementTree
    import re
    root = ElementTree.fromstring(manifest)
    folder, name = root.get('id', ''), root.get('name', '')
    if not re.fullmatch(r'[a-z0-9_]+', folder) or not re.search(r'[A-Za-z0-9]', name):
        raise ReleaseError('content.xml needs a lowercase id and a name to name release packages.')
    return folder, re.sub(r'[^A-Za-z0-9]+', '-', name).strip('-')


def archive_path(root, suffix):
    """dist/<Name-With-Hyphens>-<suffix>.zip for the current src/ manifest."""
    _, prefix = identity((Path(root) / MOD / 'content.xml').read_bytes())
    return Path(root) / 'dist' / f'{prefix}-{suffix}.zip'


def mod_names(paths):
    prefix = MOD + '/'
    names = []
    for path in paths:
        if path.startswith(prefix):
            name = path[len(prefix):]
            if '\\' in name or '..' in PurePosixPath(name).parts:
                raise ReleaseError(f'Unsupported runtime path: {path}')
            names.append(name)
    return sorted(names)


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
    paths = [path for path in git_bytes(root, *args, '--', MOD).decode().split('\0') if path]
    if local:
        paths = [path for path in paths if (root / path).exists() or (root / path).is_symlink()]
    files = mod_names(set(paths))
    require_manifests(files)
    mod = root / MOD
    for name in files:
        path = mod / name
        if path.is_symlink() or mod.resolve() not in path.resolve().parents:
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
    folder, _ = identity(read('content.xml'))
    with zipfile.ZipFile(path, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name in files:
            info = zipfile.ZipInfo(f'{folder}/{name}')
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, read(name))
    verify_zip(path, files, lambda name, data: data == read(name), folder)


def verify_zip(path, files, matches, folder):
    with zipfile.ZipFile(path) as archive:
        if archive.namelist() != [f'{folder}/{name}' for name in files] or archive.testzip():
            raise ReleaseError('Archive integrity or membership verification failed.')
        for name in files:
            if not matches(name, archive.read(f'{folder}/{name}')):
                raise ReleaseError(f'Archive differs from source: {name}')


def local_zip(root):
    root = Path(root).resolve()
    files = working_files(root, local=True)
    final = archive_path(root, 'local')
    final.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release-local-', dir=final.parent) as directory:
        temporary = Path(directory) / final.name
        write_zip(temporary, files, lambda name: (root / MOD / name).read_bytes())
        temporary.replace(final)
    print(f'Local ZIP: {final}')
    return final


def tagged_zip(root, tag):
    """Verify remote identity and package blobs without checking out the release."""
    commit, files, read, annotation = tagged_files(root, tag)
    folder, prefix = identity(read('content.xml'))
    final = root / 'dist' / f'{prefix}-{tag[1:]}.zip'
    final.parent.mkdir(exist_ok=True)
    if final.exists():
        # Older release ZIPs can contain checkout line endings. Apply Git's clean
        # filters, as the original release script does, when validating them.
        verify_zip(final, files, lambda name, data:
                   git_bytes(root, 'hash-object', '--stdin', '--path', repo_path(name), data=data).strip()
                   == git_bytes(root, 'rev-parse', f'{commit}:{repo_path(name)}').strip(), folder)
    else:
        with tempfile.TemporaryDirectory(prefix='release-tag-', dir=final.parent) as directory:
            temporary = Path(directory) / final.name
            write_zip(temporary, files, read)
            # No overwrites of a concurrently created public release archive.
            with final.open('xb') as output:
                output.write(temporary.read_bytes())
    return final, commit, annotation


def tagged_files(root, tag):
    """Verified release tag: (commit, runtime files, blob reader, reviewed notes)."""
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
    show = lambda path: git_bytes(root, 'show', f'{commit}:{path}')
    read = lambda name: show(repo_path(name))
    if show('VERSION').decode().strip() != tag[1:]:
        raise ReleaseError('Tagged VERSION disagrees with the release tag.')
    parts = tuple(map(int, tag[1:].split('.')))
    if parts[1] >= 100 or parts[2] >= 100:
        raise ReleaseError('Minor and patch must be below 100.')
    if not git_bytes(root, 'ls-tree', commit, '--', repo_path('content.xml')).strip():
        raise ReleaseError(f'{tag} predates the {MOD}/ layout and cannot be packaged by this version.')
    manifest = ElementTree.fromstring(read('content.xml'))
    if manifest.get('version') != str(parts[0] * 10000 + parts[1] * 100 + parts[2]):
        raise ReleaseError('Tagged manifest version disagrees with the release tag.')
    entries = git_bytes(root, 'ls-tree', '-rz', commit, '--', MOD).decode().split('\0')
    paths = []
    for entry in filter(None, entries):
        attributes, path = entry.split('\t', 1)
        if not attributes.startswith(('100644 blob ', '100755 blob ')):
            raise ReleaseError(f'Unsupported runtime entry: {path}')
        paths.append(path)
    files = mod_names(paths)
    require_manifests(files)
    annotation = git_bytes(root, 'cat-file', 'tag', tag_object).split(b'\n\n', 1)[1].decode().strip()
    if not annotation:
        raise ReleaseError('Release tag has no reviewed notes.')
    return commit, files, read, annotation
