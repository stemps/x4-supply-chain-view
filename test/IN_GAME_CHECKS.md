# Maximum rates and shared popup acceptance checks

Quit and relaunch X4 for the updated text resources, then load an existing save and chain.
The mod remains installed through its Junction; no file copy or save migration is needed.

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
