"""Source checks used by the justfile; no game code is executed."""

import argparse
from pathlib import Path
import re


# The focused tooltip contract, including reused short labels and exclusions.
# Other UI strings may intentionally use neutral-language fallback.
TOOLTIP_IDS = {
    3035, 3036, 3037, 3041, 3042, 3043, 3044, 3045, 3046, 3064,
    3070, 3071, 3082, 3083, 3086, 3087, 3088, 3092, 3093, 3098,
    *range(3126, 3131), *range(3140, 3153),
}
LANGUAGES = {7, 33, 34, 39, 42, 48, 49, 55, 81, 82, 86, 88, 90, 359, 380}


def check_tooltip_translations(etree):
    def read(path):
        page = etree.parse(str(path)).find("page[@id='90210']")
        if page is None:
            raise AssertionError(f"{path.name}: missing page 90210")
        entries = page.findall('t')
        values = {int(item.attrib['id']): ''.join(item.itertext()) for item in entries}
        if len(entries) != len(values):
            raise AssertionError(f"{path.name}: duplicate text IDs")
        return values

    neutral = read(ROOT / 't/0001.xml')
    paths = sorted((ROOT / 't').glob('0001-l*.xml'))
    assert {int(path.stem.split('-l')[1]) for path in paths} == LANGUAGES
    for path in [ROOT / 't/0001.xml', *paths]:
        values = read(path)
        assert TOOLTIP_IDS <= values.keys(), f"{path.name}: missing tooltip IDs {TOOLTIP_IDS - values.keys()}"
        for key in TOOLTIP_IDS:
            text = values[key]
            expected = re.findall(r'%(?:%|[-+ #0]*\d*(?:\.\d+)?[cdiouxXeEfgGqs])', neutral[key])
            actual = re.findall(r'%(?:%|[-+ #0]*\d*(?:\.\d+)?[cdiouxXeEfgGqs])', text)
            assert actual == expected, f"{path.name}/{key}: formatting placeholders differ"
            assert not re.search(r'(?<!\\)[()]', text), f"{path.name}/{key}: X4 would strip parentheses"
            assert '\n' not in text and r'\n' not in text, f"{path.name}/{key}: spacing belongs in Lua"
        print(f"PASS tooltip translations: {path.name}")

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("syntax", "xml"))
    parser.add_argument("reference", nargs="?", type=Path)
    args = parser.parse_args()

    if args.check == "syntax":
        from lupa import LuaRuntime

        lua = LuaRuntime()
        paths = sorted((ROOT / "ui").rglob("*.lua"))
        if not paths:
            raise RuntimeError("No Lua sources found")
        for path in paths:
            lua.compile(path.read_text(encoding="utf-8"), name=str(path))
            print(f"PASS syntax: {path.relative_to(ROOT)}")
    else:
        from lxml import etree

        if args.reference is None:
            parser.error("xml requires the unpacked game reference directory")
        for path in sorted(ROOT.rglob("*.xml")):
            etree.parse(str(path))
            print(f"PASS XML: {path.relative_to(ROOT)}")
        schema = etree.XMLSchema(etree.parse(str(args.reference / "ui/core/addon.xsd")))
        schema.assertValid(etree.parse(str(ROOT / "ui.xml")))
        print("PASS schema: ui.xml (addon.xsd)")
        check_tooltip_translations(etree)


if __name__ == "__main__":
    main()
