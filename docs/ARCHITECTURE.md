# Runtime architecture

This behavior-preserving refactor starts from `623baaa`. X4 still loads all runtime
files through `ui.xml`, in order, into the addon environment. There is no custom
Lua loader and no new runtime dependency. `-- Depends:` comments document direct
module prerequisites for tests; they are not interpreted by the game.

## Layers and ownership

| Module | Responsibility and lifetime |
| --- | --- |
| `SCV_Support` | Engine-read error reporting and warning deduplication, addon lifetime. |
| `SCV_Store` | Existing singleton persistence, version 6, unchanged. |
| `SCV_Metrics` | Pure calculations over plain station/ware records and shared thresholds. |
| `SCV_Graph` | Topology, cycle/budget handling and in-place metric publication. Existing calculation APIs forward to Metrics. |
| `SCV_Reader` | Engine station/ware reads; the lazy station-code index lasts for the addon environment. |
| `SCV_Logistics` | Subordinate and drone reads; receives a dock-request callback. |
| `SCV_DockSession` | One active session owned by the Data facade: requests, tokens, retained dock samples and bound event handler. |
| `SCV_Refresh` | One short-lived sweep scheduler owned by the menu, with copied membership, cursor and pending records. |
| `SCV_Data` | Existing public facade, initial scan cache, dynamic reader adapters and active dock session. |
| `SCV_Text` | Shared page-bound localization functions and per-addon-load missing-text diagnostics. |
| `SCV_Presentation` | Per-menu text formatting, warning text and logistics row measurement. No station reads. |
| `SCV_Details` | Per-menu station/ware expansion renderers and revision-keyed live fields. |
| `SCV_Management` | Per-menu toolbar, naming, settings, actions and station dialogs. |
| `SCV_Chart` | Per-menu node decoration, layout integration and flowchart rendering. |
| `SCV_LogisticsView` | Per-menu native overlay coordination, alignment, clipping inputs and failure handling. |
| `SCV_Overlay` | Existing native backend and closure-backed drawing view, retained. |
| Menu controller | Registration, lifecycle, status, scan/refresh scheduling, publication and stable callback facades. |
| Hotkey/context adapters | Existing integration with external events, retained. |

Stations, wares, saved records and graph nodes remain plain tables. Only the dock
and refresh sessions use metatable instances. UI factories close over the menu,
its configuration and presentation instance. The menu remains the canonical owner
of screen state and engine-visible callbacks; component methods use that facade
for cross-component calls so overrides remain live.

## Data flow and identity

Initial scanning reads at most four stations per call and populates the shared
cache. Periodic refresh uses a separate cursor: one station per tick, five-second
sweep-start cadence, publication only after every member has been read. Dropping
the scheduler cancels an incomplete sweep without publishing partial records.

Publication changes values in existing graph tables. It preserves topology,
predecessors, node identity, ware-table identity and each displayed ware record.
The structural baseline includes hidden/budgeted wares and is replaced only by an
explicit rebuild. Planned modules affect classification, not operating capacity.
Known zero and unknown values remain different states.

The cache and published graph share the same logistics record. A dock response
before publication updates a pending record; a response after publication updates
the displayed record. Copying these records would break that contract.

The dock session accepts both blackboard key spellings, validates persistent
station codes and payload bounds, and rejects superseded/session-stale responses.
It retains previous successful counts while replacements are pending, preserves
the earliest replacement deadline, and clears retained counts on timeout or stop.
Registration and unregistration use the identical bound handler.

## Screen lifecycle

UI components are constructed before the menu is registered. Thin menu wrappers
preserve callback names and call the component methods dynamically. Factories do
not register menus or start engine sessions themselves.

`showLogistics=false` suppresses strip measurement/rendering and node spacing;
it does not stop collection, dock requests, warning calculations or expanded dock
details. Settings redraws retain the graph, layout and refresh cursor.

Native overlay failure hides visuals/hover and latches until reopening the screen.
There is no table renderer. Individual native visuals remain the fallback for
unsupported text batching. Existing native backend reuse across UI reload remains.

Naming dialogs retain per-entry identity, deferred focus and confirmation guards.
Scan/redraw completion must not replace an active edit box. Expansion/collapse
callbacks keep paired node/frame ownership, and cleanup completes before opening
vanilla menus which reuse the same layers.

## Localization policy

The main screen and map context menu use `SCV_Text.forPage(page)`. It returns a
`T(id, ...)` function; presentation retains its `T` interface. Each call reads the
engine text again, allowing a failed lookup to recover without a cached fallback.
Failed reads, non-string/empty results and `=ReadText` placeholders produce
`SCV#<id>: <values>` or `SCV#<id>` with no arguments. Arguments are converted with
`tostring` and joined with spaces, including explicit nil/false values. For example,
a missing action label for Energy Chain becomes `SCV#2001: Energy Chain`.

Missing-text warnings include page/id and restart guidance, once per page/id pair
across both menus per addon load. `/reloadui` does not reload translation files.
Successful templates retain normal formatting; formatting failures still return
the original template. Vanilla-page lookups and hotkey labels retain their prior
handling. This resolves the former main-screen/context-menu fallback difference.

## Validation and development

Run `just check` from this repository. Tests load selected runtime modules in
manifest order using `test/addon_loader.py`; explicit fixture stubs may replace
engine-facing dependencies. The manifest check rejects unlisted, missing,
duplicate or incorrectly ordered modules. Reload tests explicitly reload their
target rather than silently reconstructing all prerequisites.

The globals linter no longer shares local helpers or parameters between files.
It remains a lightweight file-level check, not a complete lexical-scope analyzer.
Behavioral tests and Lua/LuaJIT execution remain necessary.

Worker ownership during the refactor was split into model, data and presentation,
then details, management and chart/logistics coordination. The coordinator alone
integrated menu cutovers, manifest ordering and shared test runners.

## Resolved cleanup and compatibility decision

The follow-up to `c42c179` removes only the reviewed leftovers:

| Removed item | Evidence and replacement |
| --- | --- |
| Menu `config.savedVersion` | No configuration consumer; persistence versioning remains in Store. |
| Menu-local `availableHeight` | No lexical caller; the used Management helper retains the explanatory scrolling comment. |
| Menu-local `C` and `ffi` | No native calls in the controller; native bindings remain in their owning modules. |
| `menu.hasWarning` | No production/test caller or matching vanilla callback contract; live warning calculations and status collection remain. |
| `menu.logisticsSummary` and `menu.logisticsTooltip`, plus Presentation equivalents | Their only remaining callers were tests; assertions now exercise rendered entries and their tooltip text. `idleText`, `logisticsEntries`, `logisticsRows` and dynamic dispatch remain. |

Searches found no callers for the three public menu methods in SCV, its
documentation, vanilla UI or searched loose installed sources. This does not
exclude packed or uninstalled third-party consumers. Removing these three methods
accepts that residual compatibility risk explicitly; it grants no permission to
remove other methods based only on missing search results. Engine lifecycle,
flowchart and integration callbacks remain registered and callable.

## Deferred findings

- Nexus API research was unavailable (no configured key and failed metadata
  request). This refactor is grounded in local source and vanilla patterns.
- The workspace canary cannot inspect its configured non-Git game/mod roots;
  it provides no clean verdict on the installed modlist.

## Native acceptance checklist

Automated acceptance completed on 2026-09-18: full `just check` passed, including
Lua/LuaJIT session/component tests, complete addon boot/reload, real-manifest
archive inclusion, existing behavior suites, translations, lint, syntax,
standalone addon/MD XSD validation and x4validate. `git diff --check` passed.
The refactor run log is `.cache/refactor-check.log` (ignored by Git).
The localization/cleanup follow-up also passed full `just check` on 2026-09-18;
its log is `.cache/text-cleanup-check.log`. Expanded registration checks passed
again in Lua and LuaJIT after the full run. Working and staged diff checks passed.

The original refactor retained 13 Data, 22 Graph and 46 menu functions. The
approved cleanup removes three menu functions; all Data/Graph APIs remain.
Storage, the MD protocol, content manifest, version, translations and native
backend remain unchanged. The context adapter now uses the shared text service.

The follow-up runs in the existing development checkout exposed by the installed
junction. Fully restart X4 for the new addon file list; `/reloadui` alone is not
the acceptance step. Check the main screen, map actions, logistics tooltips and
resulting `debug.txt`. Missing-text cases are tested offline without altering
installed translations. Native acceptance of this follow-up remains pending.
Automated tests do not establish rendering/input acceptance. The broader
regression checklist remains:

- Save/load and UI reload; saved false/true logistics preferences survive.
- Repeated open/close and chain switching; no stale hover, requests or visuals.
- Rename with Enter and the button while scans/refreshes are active.
- Settings dismissal and checkbox sizing; graph position and refresh continue.
- Station and ware expansion/collapse; values update while panels stay open.
- Scrolling and UI scales; clipping, panel occlusion, station clicks and tooltips.
- Large-chain docks/subordinates update; hiding strips retains expanded details.
- Navigation to vanilla station overview/map/build menus and back.

Release publication is separate from this implementation.
