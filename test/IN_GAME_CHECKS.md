# Toolbar and management acceptance checks

Restart X4 for the new translated deletion confirmation. `/reloadui` alone reloads
Lua but does not refresh the text database. The profile extension is a junction to
the development mod; no separate copy is needed.

1. Open a wide chain. The graph spans the content area beneath one toolbar row.
   Verify long chain names are available on hover and all toolbar buttons fit at
   the normal UI scale and a larger supported scale.
2. Select first/last chains with arrows and dropdown. Arrows stop at boundaries;
   the dropdown follows saved order. Check one-chain and empty-chain states.
3. Pan the graph, then open/close Stations using its button, close button and Escape.
   The graph should not jump or resize. Escape first closes management, then the
   main screen. Open a node detail and then Stations; only management remains open.
4. In a large station list, scroll to the bottom. Check full names on hover,
   warning colors, centered square icons, map links and Logical Overview links.
5. Remove one member. Its station remains in the game, the graph updates and the
   station panel stays open. Remove the final member and check the empty state.
6. Open Actions, rename, and cancel. Try a blank name, then confirm a real name.
   A successful rename updates the dropdown without moving the graph. Save/load
   and verify the name and members persist.
7. Open Delete. Verify the confirmation names the chain and explains that stations
   are unaffected. Cancel first; then confirm using a disposable chain.
8. Add stations from the map. Feedback appears below the toolbar for six seconds.
   Warnings remain visible until resolved. Multiple messages wrap on separate rows,
   warnings first. The strip grows to 20% of the available canvas, then scrolls.
   With no messages it disappears. The graph moves vertically without rescanning.
   Open Rename while feedback expires; typing must remain intact. Verify long
   translated warnings fit, the strip never covers nodes, and no status button or
   duplicate messages remain in Stations.
9. Leave Stations open through a live metric refresh. Graph metrics and station
   warning colors should update. Switching chains closes management and starts
   metrics for the newly selected chain.

Automated tests cannot verify native focus, drawing or savegame serialization.
After this pass, inspect the active profile's debug.txt for real UI errors.
