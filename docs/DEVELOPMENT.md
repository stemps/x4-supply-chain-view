# Development of the Mod

See [Runtime architecture](ARCHITECTURE.md) for module responsibilities, state
lifetimes, compatibility contracts and the native acceptance checklist.

## Dependencies

- [uv](https://docs.astral.sh/uv/) Python package manager
- [Just](https://github.com/casey/just) for running convenience tasks
- [X4 Claude Toolkit](https://github.com/WingedGuardian/x4-claude-toolkit)
  (optional but recommended)

## Local development setup

The repository assumes that it's located in a `dev` subfolder of a working
checkout of the X4 Claude Toolkit. Make sure to run through the full toolkit
setup first and then check out this repo into a `dev` subfolder.

Without the X4 Claude Toolkit some of the checks won't work due to missing game
files. Set `X4_TOOLKIT` and/or `X4_REFERENCE` to absolute paths for a different
layout.

## Running checks

Install `just` and `uv`, then run commands from the mod directory (or any subdirectory):

```text
just                 # list tasks
just check           # all automated checks; fail fast
just test            # all behavioral suites
just lint            # undefined Lua globals
just syntax          # compile all Lua files without executing them
just xml             # XML parsing and UI addon schema validation
just validate        # x4validate against base game + DLC
just test-release    # release workflow against temporary local Git remotes
just build-zip       # package current working files for local testing
```

Windows recipes use PowerShell; other platforms use just's default shell.

## Building a local test ZIP

Run `just build-zip` to create `dist/Supply-Chain-View-local.zip`. This accepts
uncommitted edits, untracked runtime files (unless ignored), any branch, and
unpushed commits. It omits deleted files and requires both manifests. The old
local ZIP is replaced only after the new archive passes integrity/content checks.

This task packages only: run `just check` separately before in-game testing.
It does not update version metadata, create commits or tags, contact Nexus, or
require an API key. Both ZIP tasks include only `content.xml`, `ui.xml`,
`ui/**/*.lua`, and `t/**/*.xml`, under `supply_chain_view/`. Documentation,
promotional images, scripts, and tests are excluded. Runtime symlinks are rejected.

## Nexus description after release

Maintain the main Nexus page description in `docs/MANUAL.md`. `just release`
validates its conversion before changing release metadata. After a successful
Nexus publication, both `just release` and `just publish-nexus <tag>` generate
`dist/nexus/<tag>/description.bbcode.txt` from the released commit's manual and
open it in Windows Notepad. Copy the text into Nexus's description editor and
preview it before saving; the main page description is not published by the API.

The converter uses `markdown-it-py==4.0.0`, supplied automatically by `uv` in the
relevant Just recipes. It supports paragraphs, headings (H1 size 5, H2 size 4,
H3 size 3, H4–H6 size 2), bold, italic, absolute HTTP/HTTPS/mailto links, and
nested bullet or numbered lists starting at 1. Markdown source line wraps become
spaces; explicit line breaks are preserved. Explicit BBCode colour tags pass
through unchanged. Tables, images, code, HTML, blockquotes, horizontal rules,
strikethrough and task lists are rejected with an actionable error.

Generated descriptions are ignored by Git and excluded from mod ZIPs. A failed
Notepad launch does not undo publication or trigger another upload. Reopen or
regenerate the file without publishing anything using:

```text
just nexus-description v0.1.0
```

This requires the requested tag to contain `docs/MANUAL.md` in supported syntax.
On systems without Windows Notepad, the generated file remains available at the
printed path even though opening the editor fails. `just build-zip` does not
convert or open the manual.
