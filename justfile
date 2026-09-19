# Requires just and uv on PATH. Commands run from this file's directory.
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

toolkit := env('X4_TOOLKIT', '../..')
reference := env('X4_REFERENCE', toolkit + '/reference')

# List available tasks.
default:
    @just --list

# Follow the active profile's game log; press Ctrl+C to stop.
log:
    Get-Content "$env:USERPROFILE\Documents\Egosoft\X4\64920437\debug.txt" -Tail 30 -Wait

# Run every automated check (stops on the first failure).
check: translations test lint syntax xml validate

# Require every neutral entry in every supported language, across all pages.
translations:
    uv run python test/test_translations.py
    uv run python test/check_sources.py translations

# Run all behavioral suites in separate Python processes.
test: test-graph test-metrics test-store test-hotkey test-release

# Validate, record, push, package and publish a release from clean main.
release:
    uv run --with markdown-it-py==4.0.0 python scripts/release.py

# Package the current working tree, including uncommitted runtime files.
build-zip:
    uv run python scripts/release.py build-zip

# Publish or resume an existing tagged release on Nexus Mods.
publish-nexus tag *args:
    uv run --with markdown-it-py==4.0.0 python scripts/release.py publish-nexus "{{tag}}" {{args}}

# Regenerate and open a released manual without publishing anything.
nexus-description tag:
    uv run --with markdown-it-py==4.0.0 python scripts/manual_bbcode.py "{{tag}}"

# Exercise releases using temporary repositories and local remotes only.
test-release:
    uv run --with markdown-it-py==4.0.0 python test/test_release.py
    uv run --with markdown-it-py==4.0.0 python test/test_manual_bbcode.py
    uv run python test/test_nexus.py
    uv run --with markdown-it-py==4.0.0 python test/test_archive.py

# Optional API lifecycle and menu activation guards.
test-hotkey:
    uv run --with lupa python test/test_hotkey.py

# Graph construction, layout, cycles, and budgets.
test-graph:
    uv run --with lupa python test/test_layout_budget.py "{{reference}}"
    uv run --with lupa python test/test_exports.py
    uv run --with lupa python test/test_graph.py
    uv run --with lupa python test/test_metric_module.py

# Reader, graph, and popup contracts with a fake engine.
test-metrics:
    uv run --with lupa python test/test_data_modules.py
    uv run --with lupa python test/test_text.py
    uv run --with lupa python test/test_presentation.py
    uv run --with lupa python test/test_details_module.py
    uv run --with lupa python test/test_chart_components.py
    uv run --with lupa python test/test_metrics.py
    uv run --with lupa python test/test_logistics.py

# Persistence and station relinking.
test-store:
    uv run --with lupa python test/test_store.py
    uv run --with lupa python test/test_name_entry.py
    uv run --with lupa python test/test_management_component.py
    uv run --with lupa python test/test_management.py
    uv run --with lupa python test/test_interact.py

# Flag undefined Lua globals and function calls.
lint:
    uv run python test/test_module_loading.py
    uv run python test/lint_globals.py
    uv run --with lupa python test/test_addon_boot.py

# Compile every Lua source without executing it.
syntax:
    uv run --with lupa python test/check_sources.py syntax

# Parse all mod XML and validate ui.xml against the game's addon schema.
xml:
    uv run --with lxml python test/check_sources.py xml "{{reference}}"

# Check mod references and diff selectors against base game and DLC.
validate:
    uv run --project "{{toolkit}}/tools/x4validate" x4validate "{{justfile_directory()}}" --reference "{{reference}}"
