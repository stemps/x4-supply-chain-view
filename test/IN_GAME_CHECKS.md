# Maximum rates and shared popup acceptance checks

Quit and relaunch X4 for the updated text resources, then load an existing save and chain.
The mod remains installed through its Junction; no file copy or save migration is needed.

Graph loading: open a chain with more than four stations. The graph pane should show
the vanilla "Loading..." message, then reveal the complete graph once, with no initial
four-station subset. Switch chains while loading and remove a member, then repeat with
a chain of four or fewer stations (it should display immediately). Check debug.txt after
reloading the UI; automated lifecycle tests cannot verify native widget presentation.

1. Fully supplied solar factory: compare its maximum output against vanilla's effective
   aggregate rate (not the single-module base rate). Check stations in different sunlight
   sectors and stations with different workforce. Repeat for an ordinary factory.
2. Starve a consumer or fill a supplier's output storage: its maximum rate must remain
   unchanged when only the input/output availability changes. Current crew/sunlight changes
   can legitimately alter that maximum. Test scrap processing and multi-product recyclers.
3. Compare station A's ware output entry with A under the ware's **Supplied by** section.
   Repeat with station B's input and **Taken by** entry. Stock, reservations, coverage,
   signed maximum rate and colour must match for the same scan snapshot. Positive rates
   are green, negative rates pale red without glow, and zero/unknown rates grey; neither
   percentages nor a max prefix appear. Amount includes current / maximum storage.
4. Confirm food and medicine consumption includes current workforce once. Mining/trading
   throughput and shipyard build consumption should be `?`, not zero. A partially unknown
   chain has no definitive supply/demand ratio; known subtotals may still be shown.
5. Check both incoming and outgoing reservations. The bar shows the net change; the tooltip
   lists both. 120k of 200k with 10k net reserved outgoing draws 60% -> 55%, without numeric
   percentage labels. The stock quantity and allocation remain accurate on overflow.
   Coverage shows current stock / full stock divided by the displayed maximum rate; output
   coverage is production-equivalent stock, explained by its tooltip. The line reads
   `lasts current / when full maximum`. Each block has a native padded row-group background,
   covering all four lines uniformly, and a 6px external gap. There must be no blue
   selection box on the first name; scroll and hover tooltips must still work.
   Hover every orange/red label: the tooltip must explain the reason and threshold. Output
   red can mean less than one hour until full without collections, even at low current fill.
6. Expand a shipyard with many wares and a ware with many stations. Scroll to the end, switch
   nodes and collapse. All content must remain inside the viewport and disappear on collapse.
7. Run `/reloadui` and reload the save: existing chain membership should be unchanged.

Automated tests exercise the reader with a fake engine, graph semantics and both actual
popup entry points with recorded widget calls. They do not establish runtime engine numbers
or pixel layout. Native `ignorestate=true` is corroborated by Station Production Overview's
estimated mode; the runtime comparisons above remain required.

Conservative limitation: if a non-operational module may contaminate an aggregate maximum,
its affected wares are unknown rather than reported as verified capacity. Other wares remain
available. Missing scans, API failures and missing recipes also remain explicitly unknown.

## Live refresh acceptance checks

After relaunching with these changes, leave the selected chain open while the simulation
runs. Initial loading still reads up to four stations per call. Subsequent sweeps start
at least five seconds apart and read one station per 0.2-second callback. They publish
only when complete: a 50-station chain updates about every ten seconds, with readings
collected across that interval. The readings are not simultaneous engine measurements.

1. Observe deliveries, pickups and reservation changes without reopening the view.
   Node fill, stock totals, reservation bars, rates, coverage, warnings and tooltips
   should update together at each publication. Warnings must clear when buffers recover.
2. Keep a ware panel open and scrolled down through several sweeps; repeat with a station
   panel. Neither panel should collapse, jump, duplicate rows or lose scroll position.
   Test unknown-to-known values and increasing digit counts for wrapping/clipping.
3. Finish another module producing an existing ware. Its maximum production should
   update. Finish a module adding a new ware or changing its role: keep the original
   graph and show the reopen-to-rebuild notice. Reopen to see the new relationships.
4. Destroy or otherwise invalidate a member: retain its node, mark its contributions
   unknown and show the structural notice. Scan-locked station data must not become
   a false zero. Temporary read failures should recover on a subsequent sweep.
5. Switch chains during a sweep, close the view, and reopen it. No old-chain result
   should appear in the new view. Repeat on a chain with budget-hidden stations.
6. Compare frame times with a normal chain, a 25+ station chain and the largest complex
   available. Test with panels both closed and open. In `ui/scv_data.lua`, the diagnostic
   `REFRESH_ENABLED` switch allows an enabled/disabled comparison after reloading the UI.
   `PROFILE_REFRESH = true` logs total/max station-read time and publication time once
   per completed sweep using the native real-time clock. Interpret measurements within
   that clock's resolution; correlate them with observed frame times. Restore
   `REFRESH_ENABLED = true` and `PROFILE_REFRESH = false` after testing.

Acceptance: no repeatable refresh-related hitch or sustained frame-time regression,
no graph movement/flicker, and no stale open-panel values after a completed sweep.
Automated tests do not establish in-game performance or visual fit. If a single complex
causes a hitch, spreading whole-station reads is insufficient; profile its reader before
claiming this feature meets the performance requirement. Check debug.txt for UI errors.
