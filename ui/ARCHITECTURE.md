# Runtime architecture

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

## Export visibility and cycle cuts

Reader separates `metricOutput` / `metricInput` from visible `output` / `input`.
Completed recipe membership is collected before operational eligibility; real
recipe/build/future consumers remain exclusions. `inputProvenance` is `workforce`
only with complete, unambiguous consumer coverage; trade and uncertain use are
`other`. `export` records P, D, N, P-D, P/N and the decision state.

The reserve follows vanilla workforce resource recipes and rounding. A single
habitat race gets global `GetWorkForceInfo(..., "").optimal`; mixed races use native
workforce influence targets only when their sum equals that global requirement.
Current and capacity coverage must also match global values. No normalization or
per-race duplication of the whole requirement is allowed. Actual demand and the
full-staffing reserve remain separate. Production retains current modifiers.

Shared ware nodes use visible endpoints for edges, and `metricProducers` /
`metricConsumers` over `metricStations` for numbers and details. Their union
supplies deduplicated stock. This also preserves contributors removed by budgeting.
Failed reads retain demand obligations as unknown. Contributor signatures govern
popup rebuilding; numeric refreshes preserve ware table identity and displayed roles.

Cycle handling uses iterative Kosaraju SCCs, removes one eligible input edge per
pass, then attempts reverse-order restoration. Candidates sort by workforce-only
priority, ware ID, destination code and ID. Restoration tests reachability from
destination to source. Every remaining cut is individually necessary; this is not
a globally minimum feedback-edge set. Output edges and nodes are untouched by this
step. Budgeting remains a separate pass; the cycle note counts only cuts whose
endpoints survive the budget.

### Layout-aware budget fallback

The chart requests `deferBudget` and calls `SCV_Graph.fitLayout` with the native
layout helper. Each trial rematerializes predecessors from logical edges, because
vanilla mutates those maps to insert routing junctions. Routed node/edge counts and
column count are measured, not estimated. Cuts prefer workforce-only inputs, then
more routed segments, with ware/code/ID tie breaks. Reverse-order restoration tests
the full native allocation again. A rejected trial restores the last accepted
predecessor maps and positions, including its junction references.

`budgetDroppedEdges` is separate from cyclic `droppedEdges`. No metric contributor
lists change. Existing common-ware/station reductions are a last resort after input
cuts cannot fit; their lost endpoints are excluded from restoration. Layout is cached
for ordinary metric refreshes and status redraws. Local regression tests extract
only the relevant helper into memory from the user's reference tree; no game source
is copied into the mod or tests.

### Shared footnotes and compact station spacing

Presentation owns an ordered footnote registry: partial rates (`*`), cycle cuts
(`[1]`) and layout-budget cuts (`[2]`). The registry supplies caption markers,
tooltip text and footer lines. Translations contain the explanation without a
hardcoded marker. Chart decoration attributes cut footnotes to the destination
station only when both endpoints survive, preserving the underlying name. Footer
height reserves every wrapped line before setting the chart's visible height.

Native flowchart node Y padding is symmetric and nodes remain centered in their
cells. Restore the original compact padding for interior rows; apply full strip
containment padding only to logistics nodes in the final layout row. This avoids
growing every inter-station gap to solve a lower-border clearance issue. Native
content-rectangle clipping remains unchanged at intermediate scroll positions;
partly visible strips remain hidden. No extra graph nodes, edges or rows are added.
