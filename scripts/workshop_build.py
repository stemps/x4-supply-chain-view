"""Stage the Steam Workshop folder: ws_ manifest, packed ext_01 catalog and loose root videos.

Workshop items need content.xml id="ws_<publishedfileid>" (Egosoft, confirmed by
Workshop authors), so the Workshop copy gets its own manifest while the repository
keeps the Nexus id. Runtime files come from the same selection as the Nexus ZIP.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile

from release_archive import ReleaseError, MOD, identity, working_files, tagged_files

CATALOG = 'ext_01.cat'
# MEASURED (WorkshopTool 1.15): uploads .mkv files only from the folder root and
# rejects a videos/ subfolder. Videos are not packed, like every Egosoft video.
LOOSE_SUFFIXES = ('.mkv',)
CONFIG_KEYS = {'appid', 'published_file_id', 'workshop_dependencies'}


def config(root):
    path = Path(root) / 'steam.json'
    if not path.exists():
        return None
    cfg = json.loads(path.read_text(encoding='utf-8'))
    if set(cfg) - CONFIG_KEYS:
        raise ReleaseError('Unknown steam.json settings: ' + ', '.join(sorted(set(cfg) - CONFIG_KEYS)))
    if cfg.get('appid') != 392160:
        raise ReleaseError('steam.json appid must be 392160 (X4: Foundations).')
    item = cfg.get('published_file_id')
    if item is not None and not (isinstance(item, str) and re.fullmatch(r'[1-9][0-9]*', item)):
        raise ReleaseError('steam.json published_file_id must be a numeric string or null.')
    deps = cfg.get('workshop_dependencies', {})
    if not isinstance(deps, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                             and re.fullmatch(r'ws_[1-9][0-9]*', v) for k, v in deps.items()):
        raise ReleaseError('workshop_dependencies must map dependency ids to ws_<id> strings.')
    return cfg


def toolkit_setting(root, key):
    """Read a key from the toolkit's .claude/x4-paths.env when the mod lives in dev/<mod>."""
    path = Path(root).resolve().parents[1] / '.claude' / 'x4-paths.env'
    if not path.exists():
        return None
    for line in path.read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'\s*' + key + r'\s*=\s*"?([^"]*)"?\s*', line)
        if match and match[1]:
            return match[1]
    return None


def tool(root, env, toolkit_key, fallback):
    candidate = os.environ.get(env) or (toolkit_key and toolkit_setting(root, toolkit_key)) or fallback
    found = shutil.which(candidate) or (candidate if Path(candidate).is_file() else None)
    if not found:
        raise ReleaseError(f'{fallback} not found. Set {env} to its full path.')
    return found


def xrcattool(root):
    return tool(root, 'XRCATTOOL', 'XRCATTOOL', 'XRCatTool')


def opening_tag(manifest):
    match = re.search(rb'<content\b[^>]*>', manifest)
    if not match:
        raise ReleaseError('Missing content manifest root.')
    return match


def set_attribute(opening, name, value):
    pattern = rb'(\s' + name + rb'\s*=\s*)(["\'])(.*?)\2'
    updated, count = re.subn(pattern, lambda m: m[1] + m[2] + value + m[2], opening)
    if count > 1:
        raise ReleaseError(f'Duplicate {name.decode()} attribute on content root.')
    if count == 0:
        updated = opening[:-1].rstrip(b'/') + b' ' + name + b'="' + value + b'"' + opening[-1:]
    return updated


def workshop_manifest(manifest, published_file_id, dependencies):
    """Rewrite the root id/sync and map dependencies to their Workshop ids.

    An optional dependency keeps its entry and gains a ws_ twin, so either copy
    satisfies it. A required one is replaced: a manifest cannot require one of two
    ids, and Workshop players have the Workshop copy.
    """
    if not published_file_id:
        raise ReleaseError('steam.json has no published_file_id. Create the Workshop item first.')
    match = opening_tag(manifest)
    opening = set_attribute(match.group(), b'id', b'ws_' + published_file_id.encode())
    # sync="false" stops the game overwriting a developer's local copy (Egosoft wiki).
    opening = set_attribute(opening, b'sync', b'false')
    manifest = manifest[:match.start()] + opening + manifest[match.end():]
    for original, workshop in dependencies.items():
        line = re.search(rb'(?m)^([ \t]*)<dependency\b[^>]*\bid="' + re.escape(original.encode())
                         + rb'"[^>]*/>[ \t]*\r?\n', manifest)
        if not line:
            raise ReleaseError(f'Mapped Workshop dependency {original} is not declared in content.xml.')
        entry = line.group()
        if re.search(rb'\bid="' + re.escape(workshop.encode()) + rb'"', manifest):
            raise ReleaseError(f'content.xml already declares {workshop}.')
        twin = entry.replace(b'id="' + original.encode() + b'"', b'id="' + workshop.encode() + b'"', 1)
        if re.search(rb'\boptional="true"', entry):
            manifest = manifest[:line.end()] + twin + manifest[line.end():]
        else:
            manifest = manifest[:line.start()] + twin + manifest[line.end():]
    return manifest


def is_loose(name):
    path = PurePosixPath(name)
    return name == 'content.xml' or (len(path.parts) == 1 and path.suffix.lower() in LOOSE_SUFFIXES)


def parse_catalog(path):
    entries = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line:
            continue
        name, size, _mtime, md5 = line.rsplit(' ', 3)
        if name in entries:
            raise ReleaseError(f'Duplicate catalog entry: {name}')
        entries[name] = (int(size), md5)
    return entries


def verify_catalog(catalog, expected):
    """expected maps packed names to their bytes; a silently dropped file is a hard error."""
    entries = parse_catalog(catalog)
    if set(entries) != set(expected):
        missing = sorted(set(expected) - set(entries))
        extra = sorted(set(entries) - set(expected))
        raise ReleaseError(f'Catalog contents differ from the release: missing {missing}, unexpected {extra}.')
    for name, data in expected.items():
        if entries[name] != (len(data), hashlib.md5(data).hexdigest()):
            raise ReleaseError(f'Catalog entry differs from source: {name}')
    data = catalog.with_suffix('.dat')
    if not data.exists() or data.stat().st_size != sum(len(d) for d in expected.values()):
        raise ReleaseError('Catalog data file is missing or has the wrong size.')


def content_digest(files):
    """Stable identity of the staged release; catalog mtimes make the .cat bytes unstable."""
    digest = hashlib.sha256()
    for name in sorted(files):
        digest.update(name.encode() + b'\0' + hashlib.sha256(files[name]).digest())
    return digest.hexdigest()


def stage(root, names, read, destination, cfg, pack=None):
    """Build destination/<mod id> and return (folder, content digest)."""
    root = Path(root)
    files = {name: read(name) for name in names}
    package, _ = identity(files['content.xml'])
    files['content.xml'] = workshop_manifest(files['content.xml'], cfg.get('published_file_id'),
                                             cfg.get('workshop_dependencies', {}))
    packed = {name: data for name, data in files.items() if not is_loose(name)}
    if not packed:
        raise ReleaseError('Nothing to pack into the Workshop catalog.')
    if destination.exists():
        shutil.rmtree(destination)
    folder = destination / package
    folder.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='workshop-stage-') as directory:
        source = Path(directory) / 'src'
        for name, data in packed.items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (pack or run_xrcattool)(root, source, folder / CATALOG)
    verify_catalog(folder / CATALOG, packed)
    for name, data in files.items():
        if is_loose(name):
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    return folder, content_digest(files)


def run_xrcattool(root, source, catalog):
    result = subprocess.run([xrcattool(root), '-in', str(source), '-out', str(catalog)],
                            capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if result.returncode or not catalog.exists():
        raise ReleaseError('XRCatTool failed: ' + (result.stderr or result.stdout).strip())


def local_stage(root):
    root = Path(root).resolve()
    cfg = config(root) or {}
    if not cfg:
        raise ReleaseError('steam.json is missing.')
    names = working_files(root, local=True)
    folder, _ = stage(root, names, lambda name: (root / MOD / name).read_bytes(),
                      root / 'dist' / 'workshop' / 'local', cfg)
    print(f'Workshop folder: {folder}')
    return folder


def tagged_stage(root, tag, cfg):
    root = Path(root).resolve()
    commit, names, read, notes = tagged_files(root, tag)
    folder, digest = stage(root, names, read, root / 'dist' / 'workshop' / tag, cfg)
    return folder, digest, commit, notes


def placeholder(root):
    """Minimal folder for WorkshopTool's first publish, which assigns the ws_ id."""
    root = Path(root).resolve()
    manifest = (root / MOD / 'content.xml').read_bytes()
    match = opening_tag(manifest)
    # Keep the root attributes WorkshopTool reads (name, description, version);
    # drop dependencies so the first upload needs nothing else on Workshop.
    body = match.group() + b'\n</content>\n'
    package, _ = identity(manifest)
    name = opening_tag(manifest).group().decode('utf-8')
    name = re.search(r'\sname\s*=\s*"([^"]*)"', name)[1]
    destination = root / 'dist' / 'workshop' / 'placeholder' / package
    if destination.parent.exists():
        shutil.rmtree(destination.parent)
    destination.mkdir(parents=True)
    (destination / 'content.xml').write_bytes(b'<?xml version="1.0" encoding="utf-8"?>\n' + body)
    (destination / 'readme.txt').write_text(f'{name} - placeholder upload, replaced by the first release.\n',
                                            encoding='utf-8')
    # MEASURED (WorkshopTool 1.15): publishx4 refuses a folder without a catalog
    # unless -buildcat packs one; that catalog only exists until the first release.
    print(f'Placeholder folder: {destination}\n'
          'Create the item from the X Tools console (Steam running and logged in):\n'
          f'WorkshopTool publishx4 -path "{destination}" -preview "<image>" -buildcat')
    return destination
