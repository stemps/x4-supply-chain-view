## Usage

This mod should be safe to add to and remove from games. Nevertheless, it's an
early version, tested mainly on a single playthrough, so use caution and back up
your save file.

### Set up a supply chain:

- Select one or more stations that feed wares into each other from the map
- Right-click and select "Supply Chain -> Create New Supply Chain"
- Give it a name
- Add more stations at any time

### Interacting with the supply chain view:

- Open the map or player information screen. The Supply Chain View is the
  rightmost tab. You can also set a direct keybind; see **Optional keyboard shortcut** below.
- Expand a station or ware to see a detailed view of input and output wares, their
  stocks, production rates, trade reservations, how long current supply buffers
  last, ...
- Select ware nodes to see how they connect your stations together and compare input/output stock levels to see if your traders are the bottleneck
- Orange or red labels indicate potential ware flow issues
- Navigate between your supply chains on the top of the screen
- The supply chain view shows real ware stock and real production rates to help
  you to troubleshoot and right-size your production chain. It does not (yet?)
  show real ware flow.

## Optional keyboard shortcut

Install [Native Hotkey API](https://www.nexusmods.com/x4foundations/mods/2181)
and the requirements listed on its page to enable keyboard access. It is optional:
the tab and existing context-menu access still work without it.

After loading a game, open **Options → Hotkey Management → Hotkey Bindings**,
find **Open Supply Chain View**, and assign a key. **Ctrl+S** is suggested
because it is unused in the game's default presets.

The shortcut opens the view from the map, while piloting, or while walking,
retaining the selected chain.

## Some things you can spot using this mod

- Expand a ware. If the producer side has plenty of stock, but the consumer side
  doesn't, your traders are the bottleneck. Add more traders to move goods faster.
- If a ware shows a red (negative) ratio of production to consumption, you need
  more factories for that ware.
- If an input stock bar shows as a small blue bar and a large green bar, most of
  the capacity of the stock is reservations (goods that are still en route).
  Add more storage of that type to allow for a larger buffer and more in-transit
  shipments.
- Check the "lasts X min" display next to your input stock. If that's low, you
  also want more storage to buffer against shipping fluctuations.

Let me know what kinds of issues you found in your supply chain ;-).

## Links

- [Source Code on GitHub](https://github.com/stemps/x4-supply-chain-view)

## Declaration of AI usage

Development of this mod makes heavy use of AI, based on the excellent
[X4 Claude Modding Tool](https://www.nexusmods.com/x4foundations/mods/2186) by
[ttyyygggg](https://www.nexusmods.com/profile/ttyyygggg). I simply wouldn't have had
the time to build this otherwise. You decide if you're OK with this.
