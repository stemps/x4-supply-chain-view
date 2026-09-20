# Runtime architecture

## Layers and ownership

| Module | Responsibility and lifetime |
| --- | --- |
| `SCV_Support` | Engine-read error reporting and warning deduplication, addon lifetime. |
| `SCV_Store` | Singleton persistence. |
| `SCV_Metrics` | Pure calculations over plain station/ware records and shared thresholds. |
| `SCV_Graph` | Topology, cycle/budget handling and in-place metric publication. Existing calculation APIs forward to Metrics. |
| `SCV_Reader` | Engine station/ware reads; the lazy station-code index lasts for the addon environment. |
| `SCV_Logistics` | Subordinate and drone reads; receives a dock-request callback. |
| `SCV_DockSession` | One active session owned by the Data facade: requests, tokens, retained dock samples and bound event handler. |
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

## Component integration

UI components are constructed before the menu is registered. Thin menu wrappers
preserve callback names and call the component methods dynamically. Factories do
not register menus or start engine sessions themselves.

Reader separates metric inputs and outputs from visible graph endpoints. Graph
owns cycle handling and budgeting; Chart coordinates layout fitting through
`SCV_Graph.fitLayout` and the native layout helper. Presentation owns the shared
footnote registry used by Chart for caption markers, tooltips and footer lines.

Runtime contracts, engine constraints and implementation findings are documented
in [KNOWLEDGEBASE.md](KNOWLEDGEBASE.md).
