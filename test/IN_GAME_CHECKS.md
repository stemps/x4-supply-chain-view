# In-game checks

Automated checks use a fake engine; these checks require a running game.

## Output fill-time row

1. Open a station popup and its output ware popup. Confirm both show the same
   `fills in … / from empty …` values, with readable wrapping and no clipped rows.
2. Hover over the row. Confirm the tooltip explains maximum production with
   sufficient inputs, excludes collections and reservations, and explains the
   shared-storage upper bound when capacity is estimated.
3. Allow production or a collection to change stock while the popup remains open.
   Confirm the fill time updates; from-empty time stays constant unless capacity
   or maximum production changes. Check both popup types.
4. Confirm a full output allocation shows `0m`. Unknown or zero production shows
   `?`, and estimated capacity prefixes both available times with `~`.
5. Confirm input rows still show `lasts … / when full …`. For a known output
   allocation, compare the row's fill time with its output-warning tooltip.

Record the game version and results after performing these checks. They have not
been performed by the automated test runner.
