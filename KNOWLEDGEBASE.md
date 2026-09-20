# Mod-local Knowledgebase

Runtime behavior and findings for this mod. Code ownership and component
relationships are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## Game Engine Findings

### Persistence and addon startup

Runtime component IDs change across save loads and can resolve to a different
object. Persist station `idcode` alongside the ID, verify both on the fast path,
and relink by code through `GetClusters(true)` / `GetContainedStations(..., true)`.
Check `IsValidComponent` before class/data reads: `pcall` cannot suppress native
missing-component diagnostics. A lookup miss is not proof of destruction.

The original nested saved-variable shape lost member arrays while retaining
names on UI reload. Whether nesting or numeric-string conversion caused it was
not isolated. Flat parallel arrays of encoded strings survived both UI reload
and save/load. Every mutation must serialize explicitly. Addon-load diagnostics
must not call lazy store accessors: a September 14 probe initialized an empty
store before engine restoration and hid intact saved chains. The probe was
removed; the delayed-restoration regression remains.

`ui.xml` file order controls availability of published globals; `Depends` comments
are validation metadata. Addon names cannot start with `ego_`, saved variables
cannot start with `__CORE`, and Lua file paths require a directory component.
`ui.xml` dependencies have no optional flag; extension dependencies are separate.
New addon files, MD changes and translations require a full restart; `/reloadui`
alone is suitable for Lua edits to already-loaded files.

### Native API and data boundaries

- `GetContainerWareConsumption` is FFI-only (`C.`); `GetProcessingModuleData` is
  a global. Check each API against vanilla callers instead of generalizing.
  Log protected-read failures with deduplication; never disguise failed reads as zero.
- Convert native `size_t` counts with `tonumber` before allocation and Lua loops.
  `GetPlannedStationModules` produced a real LuaJIT `for limit must be a number`
  failure; a regression using actual FFI counts reproduced it.
- `GetComponentData(..., "products"/"allresources")` yields arrays of ware IDs,
  not records. `StorageInfo.capacity` is volume; divide by ware volume for units.
  `StorageInfo.transport` may contain multiple whitespace-separated tags.
- `GetContainedStationsByOwner("player", nil, true)` missed saved members in
  SCV's earlier enumeration. Its vanilla callers concern build plots; do not use
  it to validate all chain membership. Resolve the selected/stored stations instead.
- MD string table keys begin with `$`; the blackboard bridge may strip it on
  Lua reads. SCV uses `$scv_` correlation tokens and accepts both spellings.
  MD list membership uses `$list.indexof.{$value}`, not Lua-style `in`.
  XSD validation did not catch the original invalid expressions.
- A station's full expansion plan can live in a separate build task referenced
  by `buildtasks`; its local construction sequence is not necessarily complete.

### Widget construction and interaction

A bad cell descriptor can abort the entire frame while state changes still
succeed, making buttons appear dead. Dropdown options need `id`, `text`,
`icon = ""` and `displayremoveoption = false`, including empty-list placeholders.
Text must not be nil. Status bars need explicit height when no text cell supplies it.

Variable-length tables need `maxVisibleHeight` and selectable rows per logical
item. Native minimum height includes the entire run between selectable rows;
an all-unselectable list can still be refused instead of scrolling. Fixed action
rows must precede variable rows. Use `highlightMode = "off"` to hide selection
without disabling scrolling. Embedded frames need `standardButtons = {}` to
avoid duplicate Back/Close controls.

Flowchart expansion requires rows in the provided table. Its outline stays
node-width even if the content frame is widened. Stadium nodes have larger side
insets than rectangles; SCV normalizes content insets while retaining the native
outline. Collapse cleanup must match both node and frame before clearing the
layer, or a previous node's callback can erase the newly opened panel. Node
captions/status icons do not expose separate click handlers.

Lower frame numbers draw in front. Keep vanilla's graph layer 5 / expanded layer
4 pairing: moving expanded ware headers to layer 2 produced fill occlusion despite
stable native value/max. SCV's selector stays in the main frame, with status on
layer 3 and management on layer 1. Clean up before opening another menu, because
destination menus reuse the global layer handlers.

Function-valued mouseovers must be registered during widget creation to enter
`functionCells`. Refresh via `frame:update()` and explicitly restore default
colours when warnings clear. Avoid double scaling: already measured pixel widths
and icon offsets need `scaling=false`. Use `Helper.uiScale` as a scale factor;
`Helper.scaleY(1)` is rounded. Font measurements must match `Helper.scaleFont`.

### Translation boundaries

X4 removes unescaped ASCII parentheses as translator comments. Write visible
parentheses as `\(` and `\)` in text XML; use XML comments for translator notes.
`ReadText` resolves the escapes before `string.format`, so `\(%s\)` works.
Raw-XML text mocks hid this bug; tests now model comment removal. Extra Lua format
arguments are ignored, which can conceal stale localized placeholder contracts.
Avoid `station(s)` for pluralization; use the native singular/plural labels.

The September reference snapshot had 16 language files but enabled only 13 in
`libraries/languages.xml`: Turkish/Ukrainian were commented out and Bulgarian
absent. Supplying translations does not enable additional game languages.

### Native layout and clipping

The vanilla layout helper mutates predecessor maps to insert routing junctions.
Routed node/edge counts and column count must be measured, not estimated.

Native flowchart node Y padding is symmetric and nodes remain centered in their
cells. Native content-rectangle clipping hides partly visible logistics strips at
intermediate scroll positions.

Stock widget pools allow one flowchart, 100 nodes, 150 edges and 30 columns.
These are Lua-allocated UI pools, not established immutable engine maxima.
Junctions and routed segments consume the same pools. Exhaustion logs an error
and skips the remaining edge-render pass; one log line is not one missing edge.
Visible allocation and cleanup timing differ from logical graph size.

The native visible-cell loop uses strict `<` fitting: an exact-fit single row can
trigger the average-visible-height diagnostic. SCV adds one pixel of bounded
height slack to the single-row instance. Clip logistics to the inner content
rectangle, subtracting borders and occupied scrollbars, rather than `GetSize`'s
outer rectangle. Preserve clipping when repairing insufficient row space.

## Relevant Vanilla Concepts this Mod Interacts with

### Ware roles, reservations and maximum rates

Configured `availableproducts`, `pureresources`, `intermediatewares` and trade
flags survive stock shortages; standing offers may disappear when stock is empty.
Build resources must be read separately for shipyards/wharves. Engine intermediate
membership alone cannot veto a workforce-consumed product: water, BoFu and medical
supplies can be both products and workforce resources. Completed/future recipe
membership distinguishes workforce-only use from real production intermediates.
Do not gate structural recipe membership on operational rate eligibility.

SCV uses native `GetContainerWareProduction/Consumption(..., true)` for effective
maximum ordinary rates, with modifiers retained. Current (`false`) rates can drop
to zero when starved, hiding the demand that needs attention. Workforce demand is
added once through `Helper.getWorkforceConsumption`; station consumption excludes
it. Rates are per hour. Mining/trading throughput and build-queue demand remain
unknown rather than zero. Production balance is not an observed stock trend.

Ordinary recipe rates use `amount * 3600 / sum(all product cycle durations)`;
dividing each product by its own cycle overstates multi-product modules. Base
recipes identify activity, not effective capacity under sunlight/workforce bonuses.
Planned and unfinished modules establish roles but add no operating capacity.
Committed plans use `GetPlannedStationModules(..., false)`, deduplicate component
IDs, and use macro IDs where no component exists. Planned build resources describe
the module's operating demand, not station construction materials.

Trade offers use the station's perspective: `isselloffer` means output. Reservation
direction is reversed: `isbuyreservation == false` is incoming and true outgoing.
Skip `issupply` and `Helper.dirtyreservations`. Native status bars use current stock
as `start`, stock plus incoming minus outgoing as `current`, and allocation as `max`.
Clip drawing endpoints without changing the reported overfilled quantities.

### Processing modules and feedstocks

Vanilla excludes processing modules from ordinary recipe-cycle arithmetic and
reads global `GetProcessingModuleData().products/resources[].amountperhour`.
`GetWareData(ware, "isprocessed")` identifies feedstocks without hardcoded ware IDs.
Read their stock from `resourcebuffer`, not `cargo`.

A September 13 live capture showed native station energy consumption of
1,728,000/h, exactly the ordinary recyclers' recipe demand, while processors
required another 1,500,000/h. Native processor-output production and raw-input
consumption were zero. SCV therefore adds eligible processor rates once to ordinary
native rates and workforce demand. Waiting Kha'ak processors still reported full
`amountperhour`; this is capacity, not proof of current activity. Paused/hacked and
output-blocked transitions were not established by that capture.

Check construction/eligibility before querying processing data: intended class
can be reported for unfinished modules, but querying them emitted native errors.
Missing eligible rates remain unknown. Feedstocks use ordinary coverage/warning
rules; ware allocation is a display denominator, not proof of physical batch
storage. Recipe conversion cycles and variable-size towed wrecks are distinct.

### Menu integration and logistics queries

SCV requires kuertee UI Extensions and HUD: extension ID
`kuerteeUIExtensionsAndHUD`, addon name `kuertee_ui_extensions`. The flat-group
API uses `Add_Custom_Actions_Group`, `prepareSections_on_end` and
`insertInteractionContent`. Group registration persists; actions are rebuilt on
every menu open. `selectedotherobjects` includes selected stations, while
`selectedplayerships` does not. The earliest compatible UIX release was not
established by its nested-group changelog; keep runtime capability checks.

Optional Native Hotkey API registers `scv_open_supply_chain` through
`HotkeyApi.RegisterAction` on `HotkeyApi.Register_Request`, in `map;pilot;fps`
contexts. It starts unassigned. `C.IsEditBoxActive` indicates widget availability,
not typing focus; use menu state guards. Preserve the action ID across label
changes. Opening through MD requires `open_menu`, since a bare show event does
not set `GetMenuParameters2`. The player-owned build shortcut follows vanilla
`StationConfigurationMenu` parameters `{0, 0, stationID}` and rechecks ownership.

Subordinate reads recurse and deduplicate IDs, using real size and macro purpose.
Idle means `C.GetNumOrders(ship) == 0`, not zero speed. Cargo drones use
`C.GetNumStoredUnits(station, "transport", false)` with information-unlock gates.
Dock queries follow `find_dockingbay` / `match_dock free="true"`: operational
external trading berths only, each assigned to its largest size, with L/XL combined.
Free berths exclude reservations; never infer them as total minus docked ships.

### Workforce demand and full-staffing reserve

The reserve follows vanilla workforce resource recipes and rounding. A single
habitat race gets global `GetWorkForceInfo(..., "").optimal`; mixed races use
native workforce influence targets only when their sum equals that global
requirement. Current and capacity coverage must also match global values. No
normalization or per-race duplication of the whole requirement is allowed.
Actual demand and the full-staffing reserve remain separate. Production retains
current modifiers.

Vanilla reads race recipes via `GetWorkForceRaceResources`, rounding each race's
resource consumption before summing. Workforce influence buffers require the
count query before `GetContainerWorkforceInfluence`. On 64-bit LuaJIT the native
`WorkforceInfluenceInfo` size is 56 bytes with `target` at offset 48; ABI/reload
tests cover this. Per-race `.optimal` was not established as a valid allocation.
Live mixed-race allocation remains an in-game verification item.

## Core mechanisms of this Mod

### Persistence

The singleton store uses persistence version 6.

`__SCV_GROUPS` stores `selected`, parallel `names`/encoded `members` arrays,
`ignoredWarnings` as `stationCode|wareId` strings, and boolean `showLogistics`.
Warning exclusions survive chain removal and apply across chains. Invalid or
missing display preferences default true; explicit false persists. A read miss
retains the member for later relinking.

### Metric presentation and warning policy

Input coverage is stock divided by known positive maximum demand: below 15 minutes
is critical, 15 to under 30 minutes warns, and 30 minutes or more is normal.
Output fullness never changes station severity. Warning exclusions suppress only
severity, preserving rates, coverage and graph relationships. Trader/miner idle
counts warn at 50% and become critical at 75%; zero/unknown totals remain neutral.

Output fill time is `max(capacity-stock, 0)/prodMax`; time from empty uses
`capacity/prodMax`. Coverage excludes reservations/deliveries/collections.
Known ware allocation, including zero, takes precedence over approximate shared
transport capacity. A successful unlocked `GetWareProductionLimit` zero contributes
zero assigned capacity; failed/locked reads cannot establish that zero. The user
observed this for unfinished stations without production modules and mining hubs
with leftover stock of formerly traded wares. Leftover stock remains in totals.
Known-zero capacity contributes zero to totals; bars use a safe
internal denominator of one without reporting that as capacity.

Ware fill aggregates deduplicated producer/consumer stock and allocation, excluding
reservations. Complete net labels show signed hourly balance and a percentage
relative to positive demand. Incomplete totals keep known subtotals, never infer
a partial net, and use signed directional values with `*`; direction colours do
not imply a known balance. Tooltips separate inventory, rate and coverage facts.

Text lookup failures produce `SCV#<id>` with arguments, deduplicating diagnostics
per page/ID per addon load. Each call retries the read; failed formatting returns
the raw template. Translation coverage checks all neutral page/ID pairs in every
locale, duplicates, empty values and parentheses, but cannot prove language quality.

### Scanning, refresh and record identity

Initial scanning reads at most four stations per call and populates the shared
cache. Periodic refresh uses a separate cursor: one station per tick,
five-second sweep-start cadence, publication only after every member has been
read. Dropping the scheduler cancels an incomplete sweep without publishing
partial records.

Publication changes values in existing graph tables. It preserves topology,
predecessors, node identity, ware-table identity and each displayed ware record.
The structural baseline includes hidden/budgeted wares and is replaced only by
an explicit rebuild. Planned modules affect classification, not operating
capacity. Known zero and unknown values remain different states.

Future-only consumers retain graph connections but report known zero current demand
when role/module inventories are complete, no built recipe consumes the ware, the
ware is not explicitly traded, and native consumption/workforce reads confirm zero.
Failed reads, excluded rates and current build-queue demand remain unknown. Planned
production completeness is unchanged.

The cache and published graph share the same logistics record. A dock response
before publication updates a pending record; a response after publication
updates the displayed record. Copying these records would break that contract.

The dock session accepts both blackboard key spellings, validates persistent
station codes and payload bounds, and rejects superseded/session-stale
responses. It retains previous successful counts while replacements are pending,
preserves the earliest replacement deadline, and clears retained counts on
timeout or stop. Registration and unregistration use the identical bound
handler.

### Screen behavior and lifecycle contracts

`showLogistics=false` suppresses strip measurement/rendering and node spacing;
it does not stop collection, dock requests, warning calculations or expanded
dock details. Settings redraws retain the graph, layout and refresh cursor.

Native overlay failure hides visuals/hover and latches until reopening the
screen. There is no table renderer. Individual native visuals remain the
fallback for unsupported text batching. Existing native backend reuse across UI
reload remains.

Naming dialogs retain per-entry identity, deferred focus and confirmation
guards. Scan/redraw completion must not replace an active edit box.
Expansion/collapse callbacks keep paired node/frame ownership, and cleanup
completes before opening vanilla menus which reuse the same layers.

### Export visibility and cycle cuts

Reader separates `metricOutput` / `metricInput` from visible `output` / `input`.
Completed recipe membership is collected before operational eligibility; real
recipe/build/future consumers remain exclusions. `inputProvenance` is
`workforce` only with complete, unambiguous consumer coverage; trade and
uncertain use are `other`. `export` records P, D, N, P-D, P/N and the decision
state.

For export eligibility, P is effective production, D is the maximum of total
actual workforce demand and total full-staffing reserve, and N counts completed
producing modules participating in P. With E=P-D, show output only when P and E
are positive and `(E > P/2 or E >= P/N)`. Smaller nonnegative surplus hides both
connections; negative surplus shows input; unknown estimates keep provisional
output. Sum each demand basis across races before taking the maximum. Future
workforce bonuses and planned production are not known export capacity.

Shared ware nodes use visible endpoints for edges, and `metricProducers` /
`metricConsumers` over `metricStations` for numbers and details. Their union
supplies deduplicated stock. This also preserves contributors removed by
budgeting. Failed reads retain demand obligations as unknown. Contributor
signatures govern popup rebuilding; numeric refreshes preserve ware table
identity and displayed roles.

Cycle handling uses iterative Kosaraju SCCs, removes one eligible input edge per
pass, then attempts reverse-order restoration. Candidates sort by workforce-only
priority, ware ID, destination code and ID. Restoration tests reachability from
destination to source. Every remaining cut is individually necessary; this is
not a globally minimum feedback-edge set. Output edges and nodes are untouched
by this step. Budgeting remains a separate pass; the cycle note counts only cuts
whose endpoints survive the budget.

### Layout-aware budget fallback

The chart requests `deferBudget` and calls `SCV_Graph.fitLayout` with the native
layout helper. Each trial rematerializes predecessors from logical edges,
because vanilla mutates those maps to insert routing junctions. Routed node/edge
counts and column count are measured, not estimated. Cuts prefer workforce-only
inputs, then more routed segments, with ware/code/ID tie breaks. Reverse-order
restoration tests the full native allocation again. A rejected trial restores
the last accepted predecessor maps and positions, including its junction
references.

`budgetDroppedEdges` is separate from cyclic `droppedEdges`. No metric
contributor lists change. Existing common-ware/station reductions are a last
resort after input cuts cannot fit; their lost endpoints are excluded from
restoration. Layout is cached for ordinary metric refreshes and status redraws.

### Shared footnotes

Presentation owns an ordered footnote registry: partial rates (`*`), cycle cuts
(`[1]`) and layout-budget cuts (`[2]`). The registry supplies caption markers,
tooltip text and footer lines. Translations contain the explanation without a
hardcoded marker. Chart decoration attributes cut footnotes to the destination
station only when both endpoints survive, preserving the underlying name. Footer
height reserves every wrapped line before setting the chart's visible height.

## Experiments and Findings

### Compact station spacing

Native flowchart node Y padding is symmetric and nodes remain centered in their
cells. Restore the original compact padding for interior rows; apply full strip
containment padding only to logistics nodes in the final layout row. This avoids
growing every inter-station gap to solve a lower-border clearance issue. Native
content-rectangle clipping remains unchanged at intermediate scroll positions;
partly visible strips remain hidden. No extra graph nodes, edges or rows are
added.

### Native layout regression coverage

Local regression tests extract only the relevant helper into memory from the
user's reference tree; no game source is copied into the mod or tests.

### Native pool and addon-access experiments (September 14, 2026)

On X4 build 23660954, matched control fixtures stopped at 100 nodes / 150 edges;
an isolated widget substitution drew 200 nodes and 300 edges in separate fixtures.
Recorded menu transitions restored pools without progressive loss, and the user
reported smooth interaction. The experiment was rolled back and rollback confirmed
in game. SCV retains stock limits; increasing its graph constants alone cannot
increase native allocation. Probe workspaces were later removed.

`getfenv` on exported widget functions exposed the native configuration, but
`debug.getupvalue` was unavailable. A timing probe established that ordinary menu
addon loading occurred inside `RegisterWidget`, after flowchart pool allocation.
Changing configuration at that point is too late. Manually rerunning initialization
appends objects/handlers and is not a safe resize API. Other injection/resize routes
remain unverified. Historical probe sources/results were archived under toolkit
`.codex/backups/known-good-scv-before-experiment-cleanup-20260918`.

### Native logistics renderer experiments (September 16–18, 2026)

Transparent table overlays captured mouse input across their entire rectangles,
including gaps over lower stations. Per-strip tables avoided those gaps but ran
into table-pool limits. The retained solution clones owned text scene visuals
through the native widget environment, with independent metric hit rectangles;
it allocates neither tables nor extra flowchart nodes. Geometry/hover updates
run per frame, while prepared text and unchanged attributes are reused.

The isolated 50-visible-station fixture at UI scale 1.481 used 350 individual
visuals versus 182 grouped visuals. Ten reconnects reused the pool, with zero
active visuals on closure. Same-session mean callback intervals were 26.73 ms
individual, 21.89 ms grouped and 17.115 ms off. Grouping roughly halved the observed
cadence overhead; direct CPU/GPU timing was unresolved. These are fixture results,
not universal performance figures. The user later confirmed real-chain rendering.

Inline ARGB cannot encode per-span glow. Grouped runs must split on glow changes;
the first grouping attempt failed because mock colours all had zero glow while
native normal/warning/error colours differed. Preserve individual-visual fallback
for incompatible typography. Reuse the native backend across UI reloads; hide
owned visuals/hover on close or failure. Legacy table fallback and probe counters
were subsequently removed.

### Refresh timing evidence (September 16, 2026)

A native trace reconciled all 24 stations over three sweeps: 72 reads, requests,
accepted replies, publications and prepared samples. One station received its
reply after publication in every sweep; the others received replies before it.
This explains isolated flicker without implying stale data elsewhere. Only 36
overlay callbacks were observed under the then-current table renderer; the trace
could not distinguish offscreen strips from table-budget exclusions and did not
prove rendered pixels or changing simulation values. The temporary trace was removed.

### Failed visual fixes and measured replacements

Explicit per-row backgrounds worked where row-group backgrounds remained invisible.
Background column spans removed vertical seams; removing row groups eliminated
their automatic spacing. Selectable name rows remain necessary for popup scrolling.

Reapplying expanded-header scale failed in game. Native probes showed stable
value/max and size despite visible flicker; asset inspection found coplanar fill
surfaces. That evidence motivated the vanilla layer 5-to-4 pairing, rather than
another data refresh. Do not restore the failed scale-redraw workaround.

On September 18, a one-row chart's strip bottom exceeded its viewport by four
pixels; all six metrics were rejected while anchors and dock data remained valid.
The user confirmed the single-row sizing fix. Later all-row padding increased
every gap and was superseded by final-row-only containment. The September 19
font-size-7 trial is not current: the reviewed source uses size 8.

A September 19 real-chain log recorded 48 nodes plus 20 junctions, 152 routed
segments and 18 columns: edge allocation alone exceeded the limit. The layout
regression reproduces this and fits 150 with one input cut while retaining all
24 stations and their accounting. Native save/UI acceptance of that remedy was
still pending in the original implementation report.

Vanilla DAG layout has no orientation property and native connectors remain on
the left/right sides. Arbitrary cell/edge positioning suggests a custom vertical
layout is possible, but merely swapping rows/columns does not produce top/bottom
connectors. This September 19 source audit was not a runtime experiment.

### Release and verification findings

Release archives use canonical committed bytes and fixed metadata for reproducible
checksums; older archives are verified through Git clean filters to tolerate CRLF
checkout conversion. Publication receipts bind exact archive bytes. Nexus v3 new
file IDs and version IDs differ, changelog writes append, and uncertain writes
must be reconciled before retrying. Receipts must not retain keys or signed URLs.

`docs/MANUAL.md` is converted to BBCode from the released commit. Unsupported
Markdown, including inline backticks, is rejected; conversion and expected manual
wording are separate checks. A handoff failure after publication must not trigger
another upload. Integration tests use temporary local repositories and mock Nexus.

In September 13 native testing, moving the development junction beside UIX in
game extensions resolved a missing-required-dependency warning without changing
IDs. This is an observed installation workaround, not a universal cross-scope rule.

Lua syntax checks cannot detect undefined calls. The globals linter must share
only exported names across files; local helpers from another file cannot satisfy
a call. Native ABI cases need LuaJIT tests, and mocks must model engine semantics.
`just xml` separately validates addon and MD schemas; default x4validate can omit
script-schema checks. Neither verifies MD expression grammar or native pixels.
SCV informational `DebugError` lines are not all failures; scope logs to the actual
save/UI load. An empty XML-operation crosscheck is not runtime validation.
