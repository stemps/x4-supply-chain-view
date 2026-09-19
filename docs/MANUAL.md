# Usage

This mod should be safe to add to and remove from games. Nevertheless, it's an
early version, tested mainly on a single playthrough, so use caution and back up
your save file.

## Set up a supply chain

- Select one or more stations that feed wares into each other from the map
- Right-click and select "Supply Chain -> Create New Supply Chain"
- Give it a name
- Add more stations at any time

## Interacting with the supply chain view

- Open the map or player information screen. The Supply Chain View is the
  rightmost tab. You can also set a direct keybind; see **Optional keyboard
  shortcut** below.
- Expand a station or ware to see a detailed view of input and output wares,
  their stocks, production rates, trade reservations, how long current supply
  buffers last, ...
- Select ware nodes to compare supplier and consumer stocks. Links show matching
  sell/buy offers within this chain, not actual shipments.
- Orange or red labels indicate potential ware flow issues.
- Hover over figures and warnings for explanations. **?** means unknown data,
  not zero.
- Navigate between your supply chains on the top of the screen.
- The supply chain view shows real ware stock and maximum production rates under
  current station conditions to help you troubleshoot and right-size your chain.
- "Lasts" shows how long current stock would satisfy station demand. It assumes
  maximum consumption without deliveries; "Full in" shows the time until storage
  runs full. It assumes maximum production without collections. These are
  planning estimates.

## Some things you can spot using this mod

- Expand a ware. If the producer side has plenty of stock, but the consumer side
  doesn't, check trade restrictions, prices or add more traders.
- A negative production balance means this chain cannot meet maximum demand
  internally. Either external supply is needed or more factories are reuquired.
- If an input stock bar shows as a small blue bar and a large green bar filling
  up to 100%, most of the expected stock is reserved incoming goods, still en
  route and further trades are blocked by the stock limit. Make sure your
  available storage is large enough to accomodate for expected en route volume
  and production buffer.
- A low "Lasts" time means a small current buffer. Check supply and deliveries;
  add storage if existing capacity prevents keeping a large enough buffer.

Let me know what kinds of issues you found in your supply chain ;-).

## Optional keyboard shortcut

Install [Native Hotkey API](https://www.nexusmods.com/x4foundations/mods/2181)
and the requirements listed on its page to enable keyboard access. It is
optional: the tab and existing context-menu access still work without it.

After loading a game, open **Options → Hotkey Management → Hotkey Bindings**,
find **Open Supply Chain View**, and assign a key. **Ctrl+S** is suggested
because it is unused in the game's default presets.

The shortcut opens the view from the map, while piloting, or while walking,
retaining the selected chain.

## Troubleshooting

**Q: Why are some stations or ware connections not displayed?** A: The game
engine's graph component has a hard limit at 100 nodes and 150 connections. If
your supply chain needs more, the mod has to drop some of the connections.

**Q: Why does the mod say it had to drop connections to avoid cycles?** A: The
supply chain view cannot display a chain with loops. Particularly workforce
demands (food, meds) are likely to cause cycles (e.g. Food -> Meds Factory ->
Meds -> Food Factory -> Food). To keep things manageable, the mod will not draw
incoming workforce demands if they would cause such cycles. It informs you about
this with a footnote. The ware production/consumptions are still counted though
and you can still see all input connection if you expand the station.

## Links

- [Source Code on GitHub](https://github.com/stemps/x4-supply-chain-view)

## Declaration of AI usage

Development of this mod makes use of AI, based on the excellent
[X4 Claude Modding Tool](https://www.nexusmods.com/x4foundations/mods/2186) by
[ttyyygggg](https://www.nexusmods.com/profile/ttyyygggg). I simply wouldn't have
had the time to build this otherwise. Not everybody likes AI usage. That's
totally fine. If that is that case, you probably want to give this a pass.
