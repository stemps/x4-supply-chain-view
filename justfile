# Requires just and uv on PATH. Commands run from this file's directory.
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

toolkit := env('X4_TOOLKIT', '../..')
reference := env('X4_REFERENCE', toolkit + '/reference')

# List available tasks.
default:
    @just --list

# Run every automated check (stops on the first failure).
check: test lint syntax xml validate

# Run all behavioral suites in separate Python processes.
test: test-graph test-metrics test-store test-hotkey

# Optional API lifecycle and menu activation guards.
test-hotkey:
    uv run --with lupa python test/test_hotkey.py

# Graph construction, layout, cycles, and budgets.
test-graph:
    uv run --with lupa python test/test_graph.py

# Reader, graph, and popup contracts with a fake engine.
test-metrics:
    uv run --with lupa python test/test_metrics.py

# Persistence and station relinking.
test-store:
    uv run --with lupa python test/test_store.py
    uv run --with lupa python test/test_name_entry.py
    uv run --with lupa python test/test_management.py

# Flag undefined Lua globals and function calls.
lint:
    uv run python test/lint_globals.py

# Compile every Lua source without executing it.
syntax:
    uv run --with lupa python test/check_sources.py syntax

# Parse all mod XML and validate ui.xml against the game's addon schema.
xml:
    uv run --with lxml python test/check_sources.py xml "{{reference}}"

# Check mod references and diff selectors against base game and DLC.
validate:
    uv run --project "{{toolkit}}/tools/x4validate" x4validate "{{justfile_directory()}}" --reference "{{reference}}"
