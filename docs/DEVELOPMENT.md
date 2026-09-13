# Development of the Mod

## Dependencies

- [uv](https://docs.astral.sh/uv/) Python package manager
- [Just](https://github.com/casey/just) for running convenience tasks
- [X4 Claude Toolkit](https://github.com/WingedGuardian/x4-claude-toolkit)
  (optional but recommended)

## Local development setup

The repository assumes that it's located in a `dev` subfolder of a working
checkout of the X4 Claude Toolkit. Make sure to run through the full toolkit
setup first and then check out this repo into a `dev` subfolder.

Without the X4 Claude Toolkit some of the checks won't work due to missing game
files. Set `X4_TOOLKIT` and/or `X4_REFERENCE` to absolute paths for a different
layout.

## Running checks

Install `just` and `uv`, then run commands from the mod directory (or any subdirectory):

```text
just                 # list tasks
just check           # all automated checks; fail fast
just test            # all behavioral suites
just lint            # undefined Lua globals
just syntax          # compile all Lua files without executing them
just xml             # XML parsing and UI addon schema validation
just validate        # x4validate against base game + DLC
just test-release    # release workflow against temporary local Git remotes
```

Windows recipes use PowerShell; other platforms use just's default shell.

## Making a release

Run `just release` after committing and pushing all work to `origin/main`.
The task requires clean `main`, including no untracked files, and fetches the
remote to check that local and remote commits match before asking any questions.

Accept the suggested version or enter a stable `major.minor.patch` version.
Minor and patch values must be below 100. X4's manifest integer is encoded as
`major * 10000 + minor * 100 + patch` (so `0.1.0` is `100`).

The release script updates `VERSION`, `CHANGELOG.md`, and the manifest's version/date,
runs `just check`, and verifies the ZIP. It then commits the metadata, creates an
annotated `vX.Y.Z` tag and atomically pushes main and the tag to origin. Success
produces `dist/Supply-Chain-View-X.Y.Z.zip`, containing only the manifests, Lua
files and translations under `supply_chain_view/`. Upload that ZIP manually.
