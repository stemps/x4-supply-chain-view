# Runtime architecture

## Repository layout

`src/` is the mod: exactly the files the game loads and every release ships.
Everything else is development-only: `tests/lua/` (Lua behaviour suites with a
fake engine, loaded through `tests/lua/addon_loader.py` in `ui.xml` order),
`tools/` (Lua
syntax, globals, XML and schema checkers), `docs/`, `images/` and metadata.

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

Release, publication, `just link` and `just log` come from x4-modkit (`x4mod` on
PATH), shared with every mod repository; see its README and ARCHITECTURE.md. This
repository holds only the "Shared tasks" block of the `justfile`, which must stay
identical to `x4mod justfile` (`x4mod doctor`, part of `just test-release`, fails
otherwise). Mod-specific values come only from `src/content.xml` (its `id` names
the package folder, its `name` the ZIP prefix), `nexus.json`, `steam.json` and
`discord.json`. `just test-release` runs the kit's tests with live checks of this
repository's manifests, manual, licence copies and publication configs.

Supply Chain View settings: `nexus.json` targets mod 2371 without a pinned
file; `steam.json` targets Workshop item 3811818873 and replaces the required UI
Extensions dependency with `ws_3477279743` in the Workshop manifest.
