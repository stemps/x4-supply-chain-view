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

## Making a release

Run `just release` after committing and pushing all work to `origin/main`.
The task requires clean `main`, including no untracked files, and fetches the
remote to check that local and remote commits match before asking any questions.
It requires Git, just, uv, and the same toolkit/reference setup as `just check`.
If just is not installed separately, use `uv run --with rust-just just release`.

Accept the suggested version or enter a stable `major.minor.patch` version.
The first default is `0.1.0`; later defaults increment the minor version.
Minor and patch values must be below 100. X4's manifest integer is encoded as
`major * 10000 + minor * 100 + patch` (so `0.1.0` is `100`).

Git's configured editor opens release notes populated with commit subjects since
the previous version tag (all commits for the first release). Edit, save and close
the file to continue; empty notes cancel the release. Configure an editor that
waits until editing finishes, for example `git config core.editor "code --wait"`.

The script updates `VERSION`, `CHANGELOG.md`, and the manifest's version/date,
runs `just check`, and verifies the ZIP. It then commits the metadata, creates an
annotated `vX.Y.Z` tag and atomically pushes main and the tag to origin. Success
produces `dist/Supply-Chain-View-X.Y.Z.zip`, containing only the manifests, Lua
files and translations under `supply_chain_view/`. Upload that ZIP manually.
Release notes and development files are not included. Existing ZIPs are never
overwritten. VERSION and CHANGELOG.md are created by the first release.

Failures before the release commit restore only the script's own metadata edits.
Failures after committing retain the commit and any tag for inspection and
recovery; they do not reset history. If a push fails, fix its cause and use the
printed atomic-push command after inspecting the local tag. A failed push does
not publish a ZIP. Do not rerun release to retry the same version: recover the
existing release and rebuild its archive from that tag, using the same runtime
file allowlist. The script does not create a Nexus upload or GitHub Release.
