# Supply Chain View

Open Supply Chain View through its top-level tab. With kuertee UI Extensions and
HUD installed, stations also offer Supply Chain actions in the map context menu.

## Optional keyboard shortcut

Install [Native Hotkey API](https://www.nexusmods.com/x4foundations/mods/2181)
and the requirements listed on its page to enable keyboard access. It is optional:
the tab and existing context-menu access still work without it.

After loading a game, open **Options → Hotkey Management → Hotkey Bindings**,
find **Open Supply Chain View**, and assign a key.
**Ctrl+S** is suggested because it is unused in the game's default presets;
check for conflicts with your own bindings. The action starts unassigned.
You can change or remove the assignment through the same screen.

The shortcut opens the view from the map, while piloting, or while walking,
retaining the selected chain. It does not replace another dialog or reopen SCV
when it is already visible. Map editing and popup interactions suppress opening.
Native Hotkey API manages bindings; SCV does not modify input settings or require
an external helper program.

Development checks are described in [test/README.md](test/README.md).
