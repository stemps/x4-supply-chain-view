"""Test-only loading of selected addon modules in the real manifest order.

Runtime loading remains entirely owned by X4. Depends comments document direct
prerequisites; fixtures may explicitly provide an engine-facing module as a stub.
"""
from pathlib import Path
import re
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def module_order(root=ROOT):
    names = [item.attrib['name'] for item in ET.parse(root / 'ui.xml').findall('.//file')]
    if len(names) != len(set(names)):
        raise AssertionError('duplicate addon file')
    return names


def dependencies(source):
    result = []
    for line in re.findall(r'^-- Depends: (.+)$', source, re.M):
        result.extend('ui/' + name.strip() for name in line.split(','))
    return result


def validate_manifest(root=ROOT):
    order = module_order(root)
    actual = {path.relative_to(root).as_posix() for path in (root / 'ui').rglob('*.lua')}
    assert set(order) == actual, 'manifest and runtime Lua files differ'
    seen = set()
    for name in order:
        for dependency in dependencies((root / name).read_text(encoding='utf-8')):
            assert dependency in seen, f'{name} requires earlier {dependency}'
        seen.add(name)


def load_modules(lua, *names, provided=(), reload=False):
    """Load prerequisites once; reload=True reexecutes only explicitly requested files."""
    order = module_order()
    targets = ['ui/' + name.removeprefix('ui/') for name in names]
    supplied = {'ui/' + name.removeprefix('ui/') for name in provided}
    loaded = lua.globals().__scv_test_loaded
    if loaded is None:
        loaded = lua.table()
        lua.globals().__scv_test_loaded = loaded
    selected, visiting = set(), set()

    def select(name):
        if name in supplied or name in selected:
            return
        assert name in order, f'{name} is not in ui.xml'
        assert name not in visiting, f'cyclic dependency: {name}'
        visiting.add(name)
        for dependency in dependencies((ROOT / name).read_text(encoding='utf-8')):
            select(dependency)
        visiting.remove(name)
        selected.add(name)

    for name in targets:
        select(name)
    results = {}
    seen = set(supplied)
    for name in order:
        if name not in selected:
            continue
        source = (ROOT / name).read_text(encoding='utf-8')
        assert set(dependencies(source)) <= seen, f'load-order violation: {name}'
        if not loaded[name] or (reload and name in targets):
            result = lua.execute(source)
            loaded[name] = lua.table_from({'done': True, 'result': result})
        results[name] = loaded[name]['result']
        seen.add(name)
    return results.get(targets[-1]) if targets else None
