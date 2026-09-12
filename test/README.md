# Development checks

Install `just` and `uv`, then run commands from the mod directory (or any subdirectory):

```text
just                 # list tasks
just check           # all automated checks; fail fast
just test            # all three behavioral suites
just lint            # undefined Lua globals
just syntax          # compile all Lua files without executing them
just xml             # XML parsing and UI addon schema validation
just validate        # x4validate against base game + DLC
```

Individual suites are available as `test-graph`, `test-metrics`, and `test-store`.
`test-metrics` also runs `test_refresh.lua`: bounded sweeps through 50 stations,
atomic publication, in-place native node/popup updates, missing-data recovery,
structural-change detection and cancellation when switching or closing the view.
`uv` supplies Python dependencies on demand; the first
run may need network access. Windows recipes use PowerShell; other platforms
use just's default shell.

If `just` is not on PATH, use `uv run --with rust-just just check` (or replace
`check` with another recipe).

The default layout is `dev/supply_chain_view` inside the X4 toolkit. Set
`X4_TOOLKIT` and/or `X4_REFERENCE` to absolute paths for a different layout.
XML schema validation requires your unpacked game reference, and `validate`
requires the toolkit's `tools/x4validate` project. Missing dependencies or
reference files fail the check rather than silently skipping it.

The tests use Lupa with a fake engine. A passing `just check` does not verify
live engine APIs, save serialization, or UI appearance; follow
[IN_GAME_CHECKS.md](IN_GAME_CHECKS.md) for those checks.
