# Development of the Mod

See [Runtime architecture](../ARCHITECTURE.md) for module responsibilities, state
lifetimes, compatibility contracts and the native acceptance checklist.

## Dependencies

- [uv](https://docs.astral.sh/uv/) Python package manager
- [Just](https://github.com/casey/just) for running convenience tasks
- [x4-modkit](https://github.com/stemps/x4-modkit), the shared release,
  publishing, `just link` and `just log` tooling. Install it once with
  `uv tool install git+https://github.com/stemps/x4-modkit` (or
  `uv tool install --editable <path to a local checkout>`) so `x4mod` is on PATH
- [X4 Claude Toolkit](https://github.com/WingedGuardian/x4-claude-toolkit)
  (optional but recommended)
- For Steam Workshop releases: Egosoft's "X Tools" (free, in the Steam library
  under Tools), which provides `WorkshopTool.exe` and `XRCatTool.exe`

## Repository layout

- `src/` is the mod: exactly the files the game loads and every release ships.
- `tests/lua/` holds the Lua behaviour suites with a fake engine.
- `tools/` holds the source checkers (Lua syntax, globals, XML and schemas).
  `docs/` and `images/` hold documentation and promotional material.
- Release, publishing, `just link` and `just log` come from x4-modkit. The
  "Shared tasks" block at the end of the `justfile` must stay identical to
  `x4mod justfile`; `just test-release` fails when it drifts.

## Local development setup

The repository assumes that it's located in a `dev` subfolder of a working
checkout of the X4 Claude Toolkit. Make sure to run through the full toolkit
setup first and then check out this repo into a `dev` subfolder.

Without the X4 Claude Toolkit some of the checks won't work due to missing game
files. Set `X4_TOOLKIT` and/or `X4_REFERENCE` to absolute paths for a different
layout.

`just link` creates a junction from the game's `extensions/supply_chain_view` to
`src/`, so the game loads your working copy directly. `just unlink` removes only
the junction and `just link-status` shows its target. The extensions folder comes
from `X4_EXTENSIONS`, then `X4_GAME\extensions`, each read from the environment
or from x4-modkit's `~/.config/x4-modkit/paths.env` (`x4mod config` shows what
resolved). `just log` follows the game's `debug.txt`.

## Running checks

Install `just` and `uv`, then run commands from the repository root (or any
subdirectory):

```text
just                 # list tasks
just check           # every mod check; fail fast
just check-release   # check plus the release tooling tests
just translations    # all game languages match the English source (see below)
just test            # all behavioral suites
just lint            # undefined Lua globals
just syntax          # compile all Lua files without executing them
just xml             # XML parsing and UI addon schema validation
just validate        # x4validate on src/ against base game + DLC
just test-release    # x4-modkit drift check and release tooling tests against this repo
just build-zip       # package the current src/ for local testing
```

The recipes are written for PowerShell (Windows).

## Translations

English lives only in `src/t/0001.xml` (root `<language>`, no id); do not add a
`0001-l044.xml`. Each of the 15 other game locales has `src/t/0001-lNNN.xml` with
`<language id="NNN">` and exactly the English page/text ids. `just translations`
(x4-modkit, part of `just check`) also rejects empty or duplicate entries, unescaped
parentheses (write `\(` and `\)`), em dashes, and placeholders, `{page,t}`
references or `\n` line breaks that differ from English. An entry whose formatting
legitimately differs is listed in `translations.json` with its reason.
Translation files need a full game restart; `/reloadui` does not reload them.

## Building a local test ZIP

Run `just build-zip` to create `dist/Supply-Chain-View-local.zip`. It contains
every file in `src/` under `supply_chain_view/`, including uncommitted edits and
untracked files (unless ignored), from any branch. Nothing outside `src/` is
packaged. Both manifests (`content.xml`, `ui.xml`) are required and runtime
symlinks are rejected. The old local ZIP is replaced only after the new archive
passes integrity/content checks.

This task packages only: run `just check` separately before in-game testing.
It does not update version metadata, create commits or tags, or contact Nexus or
Steam.

## Releasing

`just release` runs from a clean, pushed `main`. It asks for the version and
release notes, runs `just check-release`, commits the version metadata, tags and
pushes, then publishes to Nexus and afterwards to the Steam Workshop.

- Nexus needs `X4_NEXUS_KEY` (your personal API key); `nexus.json` names the mod.
- Steam needs the Steam client running and online; `steam.json` names the
  Workshop item. The Workshop copy gets its own `content.xml` with the
  Workshop id `ws_<item id>`, and requires the Workshop copy of UI Extensions
  (`ws_3477279743`) instead of `kuerteeUIExtensionsAndHUD`.
- `XRCATTOOL` must point to `XRCatTool.exe` (environment variable or
  x4-modkit's `paths.env`) to pack the Workshop catalog.

Until the Workshop item exists, `steam.json` has no `published_file_id` and
releases stop at the Steam check. Create it once: run `just workshop-placeholder`
and publish the printed folder with WorkshopTool from the X Tools console, then
put the new id into `steam.json`.

If a platform fails, the Git release stays. Resume it with
`just publish-nexus vX.Y.Z` or `just publish-steam vX.Y.Z`; both keep receipts
in `dist/` so a resumed upload never runs twice. `just build-workshop` stages the
Workshop folder from the working copy for inspection.

## Store page descriptions after release

Maintain the main Nexus and Steam Workshop page description in `docs/MANUAL.md`.
`just release` validates its conversion for both sites before changing release
metadata. After a successful publication, each platform step generates its own
BBCode from the released commit's manual and opens it in Windows Notepad:
`dist/nexus/<tag>/description-nexus.bbcode.txt` and
`dist/steam/<tag>/description-steam.bbcode.txt`. Copy the text into the site's
description editor and preview it before saving; neither page description is
published by an API.

The converter uses `markdown-it-py==4.0.0`, installed with x4-modkit. It supports paragraphs, headings, bold, italic, absolute
HTTP/HTTPS/mailto links, and nested bullet or numbered lists. Markdown source line
wraps become spaces; explicit line breaks are preserved. Tables, images, code,
HTML, blockquotes, horizontal rules, strikethrough and task lists are rejected
with an actionable error, so one manual stays valid for both sites.

| Markdown | Nexus | Steam |
|---|---|---|
| Headings H1/H2/H3, H4-H6 | `[size=5]`/`[size=4]`/`[size=3]`, `[size=2]`, all bold | `[h1]`/`[h2]`/`[h3]`, `[h3]` |
| Numbered list | `[list=1]`, items closed with `[/*]` | `[olist]`, items without a closing tag |
| Raw BBCode colour tags in the source | passed through | not supported by Steam; avoid |

Steam descriptions are assumed to be limited to 8000 characters (Steamworks
constant, not yet confirmed on an item page); a longer manual fails the release
preflight. Generated descriptions are ignored by Git and excluded from
mod ZIPs. A failed Notepad launch does not undo publication or trigger another
upload. Reopen or regenerate a file without publishing anything using:

```text
just nexus-description v0.1.0
just steam-description v0.1.0
```

This requires the requested tag to contain `docs/MANUAL.md` in supported syntax.
On systems without Windows Notepad, the generated file remains available at the
printed path even though opening the editor fails. `just build-zip` does not
convert or open the manual.
