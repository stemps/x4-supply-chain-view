# User Manual

**Work in progress...**

## Usage

### Set up a supply chain:

- Select one or more stations that feed wares into each other from the map
- Right-click and select "Supply Chain -> Create New Supply Chain"
- Give it a name
- Add more stations at any time

### Interacting with the supply chain view:

- Open the map or player information screen. The Supply Chain View is the
  rightmost tab. If you use Simple Hotkeys you can set a direct keybind for it.
- Expand stations to open a detailed view of input and output wares, their
  stocks, production rates, trade reservations, how long current supply buffers
  last, ...
- Select ware nodes to see how they connect your stations together and compare input/output stock levels to see if your traders are the bottleneck
- Navigate between your supply chains on the top of the screen
- The supply chain view shows real ware stock , real production rates to help
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
