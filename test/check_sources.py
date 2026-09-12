"""Source checks used by the justfile; no game code is executed."""

import argparse
from pathlib import Path

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


if __name__ == "__main__":
    main()
