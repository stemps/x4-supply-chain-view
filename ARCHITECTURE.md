# Runtime architecture

## Repository layout

`src/` is the mod: exactly the files the game loads and every release ships.
Everything else is development-only: `tests/lua/` (Lua behaviour suites with a
fake engine, loaded through `tests/lua/addon_loader.py` in `ui.xml` order),
`tests/release/` (release tooling), `tests/translations/`, `tools/` (Lua
syntax, globals, XML and schema checkers), `scripts/` (release and
publishing), `docs/`, `images/` and metadata.

## Layers and ownership

| Module | Responsibility and lifetime |
| --- | --- |
| `SCV_Support` | Engine-read error reporting and warning deduplication, addon lifetime. |
| `SCV_Store` | Singleton persistence. |
| `SCV_Metrics` | Pure calculations over plain station/ware records and shared thresholds. |
| `SCV_Graph` | Topology, cycle/budget handling and in-place metric publication. Existing calculation APIs forward to Metrics. |
| `SCV_Reader` | Engine station/ware reads; the lazy station-code index lasts for the addon environment. |
| `SCV_Logistics` | Subordinate and drone reads; receives a dock-request callback. |
| `SCV_DockSession` | One active session owned by the Data facade: requests, tokens, retained dock and dock-queue samples, bound event handler, and the stop event that disarms the MD queue watch. |
| `md/scv_logistics.xml` | The only MD script. `DockCapacity` answers one station per UI request through the token mailbox. `DockQueue` holds the queue watch, armed by the first request and disarmed by stop, watchdog or save load, so nothing runs while SCV is closed. |
| `SCV_Refresh` | One short-lived sweep scheduler owned by the menu, with copied membership, cursor and pending records. |
| `SCV_Data` | Public facade, initial scan cache, dynamic reader adapters and active dock session. |
| `SCV_Text` | Shared page-bound localization functions and per-addon-load missing-text diagnostics. |
| `SCV_Presentation` | Per-menu text formatting, warning text and logistics row measurement. No station reads. |
| `SCV_Details` | Per-menu station/ware expansion renderers and revision-keyed live fields. |
| `SCV_Management` | Per-menu toolbar, naming, settings, actions and station dialogs. |
| `SCV_Chart` | Per-menu node decoration, layout integration and flowchart rendering. |
| `SCV_LogisticsView` | Per-menu native overlay coordination, alignment, clipping inputs and failure handling. |
| `SCV_Overlay` | Native backend and closure-backed drawing view. |
| Menu controller | Registration, lifecycle, status, scan/refresh scheduling, publication and stable callback facades. |
| Hotkey/context adapters | Integration with external events. |

Stations, wares, saved records and graph nodes remain plain tables. Only the
dock and refresh sessions use metatable instances. UI factories close over the
menu, its configuration and presentation instance. The menu remains the
canonical owner of screen state and engine-visible callbacks; component methods
use that facade for cross-component calls so overrides remain live.

The reader preserves whether a ware allocation read succeeded in `limitKnown`.
Metrics treat a confirmed zero allocation as zero assigned capacity, retaining
stock independently and using shared-capacity estimates only for unknown allocations.
The reader also distinguishes future-only input roles from unavailable demand:
complete inventories and zero native consumption establish known zero demand while
the graph retains the planned connection.

A plain trade ware a station both buys and sells is an output by default ("output
wins"); the reader marks it `dualTrade`. The player may store a consumer role per
chain, station code and ware (each chain's `consumerRoles`, built for the graph by
`SCV_Store.consumerRolePolicy`), so one station can sell in one chain and buy in
another. The policy is bound to the chain record, not its index, because the graph
keeps it for refreshes. `SCV_Graph.applyRoleOverrides`
sets the role in both directions, because the scan cache reuses station tables
between builds. `build` and `refreshMetrics` both apply it before roles are
compared, so an override never reads as a structure change. A role change moves
edges, so the per-ware icon and the station-wide switch in the station popup
rebuild the chain instead of republishing metrics.

`menu.display(presentationOnly, reason)` is the single redraw entry. It logs the
reason, remembers the open detail panel by node key, and `onUpdate` re-expands the
matching node of the new chart in the same chain.

## Component integration

UI components are constructed before the menu is registered. Thin menu wrappers
preserve callback names and call the component methods dynamically. Factories do
not register menus or start engine sessions themselves.

Reader separates metric inputs and outputs from visible graph endpoints. Graph
owns cycle handling and budgeting; Chart coordinates layout fitting through
`SCV_Graph.fitLayout` and the native layout helper. The helper orders each column
by neighbour median, then edge slot weight, then input order; Graph feeds it stations
and wares sorted by display name, so the ties it decides are readable and do not
depend on chain insertion order or scan-cache state. Presentation owns the shared
footnote registry used by Chart for caption markers, tooltips and footer lines.

Optional Civilian Economy integration is a Reader-only demand source:
`readCivilianDemand` reads CE's `CEHubStatus` global when present and turns each
unlocked hub ware into an input whose CE rate adds to `consMax`. For those wares,
the CE reserve and its two-hour target replace cargo stock and storage limit.
Graph and the UI see ordinary records; only the rate tooltip names the
`civilian` share.

Runtime contracts, engine constraints and implementation findings are documented
in [KNOWLEDGEBASE.md](KNOWLEDGEBASE.md).

## Release tooling

`scripts/`, `tests/release/` and the "Shared tasks" block of the `justfile` are
identical in every mod repository (Civilian Economy, Supply Chain View); change
them in one repo and copy them to the other. Mod-specific values come only from
`src/content.xml` (its `id` names the package folder, its `name` the ZIP prefix),
`nexus.json` and `steam.json`.

`just release` requires clean `main` tracking and matching `origin/main`. It
suggests the next minor version (with an editable override), opens commit subjects
in Git's configured editor, checks Nexus and Steam, updates `VERSION`,
`CHANGELOG.md` and the manifest version/date, runs `just check-release`, commits
only that metadata, creates an annotated tag and atomically pushes both. It then
publishes to Nexus and afterwards to the Steam Workshop. Before the first tag the
suggestion comes from the manifest version; later releases use the latest tag.

- `scripts/release.py`: preflight, version/notes, metadata, validation and Git
  orchestration; preserves concurrent edits and rolls back pre-commit failures.
  Edited notes are saved to `.git/release-notes/v<version>.json` right after the
  editor closes; a later attempt at the same version reopens them (plus subjects of
  commits made since) and the file is deleted once the release tag exists.
- `scripts/release_archive.py`: deterministic ZIPs of `src/` under the manifest
  id, local working-tree builds and reconstruction from verified remote tags.
  Every file in `src/` ships and nothing outside it does. The game's junction
  points at `src/`, so in-game tests see the same files as the ZIP.
  `src/MIT-LICENSE` is a copy of the root licence (kept for GitHub); a test keeps
  them identical. Tags from before the `src/` layout cannot be repackaged.
- `scripts/nexus_publish.py`: Nexus upload/version/changelog publication with
  resumable receipts in ignored `dist/nexus/`; `X4_NEXUS_KEY` supplies
  credentials. A `file_id` in `nexus.json` pins the main file; with `null`,
  exactly one main file must exist. `create_new_file: true` is only for an empty
  page and is not safe to leave on once a file exists.
- `scripts/workshop_build.py`: stages `dist/workshop/<tag|local>/<id>/` from the
  same files as the ZIP. Its `content.xml` gets `id="ws_<published_file_id>"`
  and `sync="false"`; each dependency mapped in `steam.json` gets its Workshop id,
  added beside an optional dependency and replacing a required one. Root `.mkv`
  files stay loose; everything else is packed into `ext_01.cat/.dat` with
  XRCatTool and verified against the sources. `just workshop-placeholder` builds
  the folder for the one-time item creation.
- `scripts/steam_publish.py`: uploads that folder with `WorkshopTool update
  -batchmode` (Steam client must be online) and keeps resumable receipts in
  `dist/steam/`. Uncertain outcomes are resolved with `--confirm-uploaded` or
  `--retry-upload`; `--minor` is for an unchanged version. Releases skip Steam
  while `steam.json` is absent or has no `published_file_id`.
  The change note is the release notes as Steam BBCode: WorkshopTool reads a
  value starting with `-` (a Markdown list) as the next switch and uploads nothing.
- `scripts/discord_publish.py`: posts the release announcement (title, Nexus/Steam
  links, tag notes) through the webhook of the channel in `discord.json`. The URL
  is a secret read from the env var that file names, never written anywhere. Release
  preflight checks the webhook points at that channel and the text fits 2000
  characters; the post runs last, only after Nexus (and Steam, if recorded) are done.
  Receipts in `dist/discord/`; uncertain outcomes are resolved with
  `--confirm-posted` or `--retry-post`. Releases skip Discord without `discord.json`.
- `scripts/manual_bbcode.py`: converts the released `docs/MANUAL.md` to Nexus or
  Steam BBCode (`dist/<nexus|steam>/<tag>/description-<nexus|steam>.bbcode.txt`) and opens
  Notepad for copy/paste. Unsupported Markdown fails before releasing, and so does
  Steam output over 8000 characters (Steam preflight). Continued numbered lists
  use explicit numbers because neither site has a list-start attribute.
- `scripts/game_link.ps1` (`just link` / `unlink` / `link-status`): manages the
  `extensions/<repo folder>` junction to `src/`. The extensions dir comes from
  `X4_EXTENSIONS`, then the toolkit's `.claude/x4-paths.env`, then
  `X4_GAME\extensions`. It refuses to replace or delete a regular folder, and
  unlink removes only the reparse point (non-recursive delete).
- `scripts/game_log.ps1` (`just log`): follows `debug.txt` from `X4_DEBUGLOG`,
  the toolkit's `X4_DEBUGLOG`/`X4_PROFILE`, or the newest profile.
- `tests/release/`: isolated release repositories/local remotes and fake HTTP
  responses around a neutral `example_mod` fixture; run via `just test-release`,
  also included in `just check-release`.

`just build-zip` packages dirty and untracked `src/` files without changing Git
or versions. `just publish-nexus vX.Y.Z` and `just publish-steam vX.Y.Z` resume
one platform; `just nexus-description <ref>` regenerates only the manual handoff
(`just steam-description <ref>` for Steam)
for a release tag or any branch/commit. Release tasks use `uv` with pinned
`markdown-it-py==4.0.0`. Retain `dist/` receipts to resume uncertain uploads safely.

Supply Chain View settings: `nexus.json` targets mod 2371 without a pinned
file; `steam.json` targets Workshop item 3811818873 and replaces the required UI
Extensions dependency with `ws_3477279743` in the Workshop manifest.
