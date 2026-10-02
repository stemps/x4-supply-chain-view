# Requires just and uv on PATH. Commands run from this file's directory.
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

toolkit := env('X4_TOOLKIT', '../..')
reference := env('X4_REFERENCE', toolkit + '/reference')

# List available tasks.
default:
    @just --list

# ---------------------------------------------------------------------------
# Mod checks
# ---------------------------------------------------------------------------

# Run every mod check (stops on the first failure).
check: translations test lint syntax xml validate

# Require every neutral entry in every supported language, across all pages.
translations:
    uv run python tests/translations/test_translations.py
    uv run python tools/check_sources.py translations

# Check mod references and diff selectors in src/ against base game and DLC.
validate:
    uv run --project "{{toolkit}}/tools/x4validate" x4validate "{{justfile_directory()}}/src" --reference "{{reference}}"

# Run all behavioral suites in separate Python processes.
test: test-graph test-metrics test-store test-hotkey

# Optional API lifecycle and menu activation guards.
test-hotkey:
    uv run --with lupa python tests/lua/test_hotkey.py

# Graph construction, layout, cycles, and budgets.
test-graph:
    uv run --with lupa python tests/lua/test_layout_budget.py "{{reference}}"
    uv run --with lupa python tests/lua/test_exports.py
    uv run --with lupa python tests/lua/test_graph.py
    uv run --with lupa python tests/lua/test_metric_module.py

# Reader, graph, and popup contracts with a fake engine.
test-metrics:
    uv run --with lupa python tests/lua/test_data_modules.py
    uv run --with lupa python tests/lua/test_text.py
    uv run --with lupa python tests/lua/test_presentation.py
    uv run --with lupa python tests/lua/test_details_module.py
    uv run --with lupa python tests/lua/test_chart_components.py
    uv run --with lupa python tests/lua/test_metrics.py
    uv run --with lupa python tests/lua/test_logistics.py

# Persistence and station relinking.
test-store:
    uv run --with lupa python tests/lua/test_store.py
    uv run --with lupa python tests/lua/test_name_entry.py
    uv run --with lupa python tests/lua/test_management_component.py
    uv run --with lupa python tests/lua/test_management.py
    uv run --with lupa python tests/lua/test_interact.py

# Flag undefined Lua globals and function calls.
lint:
    uv run python tests/lua/test_module_loading.py
    uv run python tools/lint_globals.py
    uv run --with lupa python tests/lua/test_addon_boot.py

# Compile every Lua source without executing it.
syntax:
    uv run --with lupa python tools/check_sources.py syntax

# Parse all mod XML and validate ui.xml against the game's addon schema.
xml:
    uv run --with lxml python tools/check_sources.py xml "{{reference}}"

# ---------------------------------------------------------------------------
# Shared tasks: keep this block identical in every mod repository.
# ---------------------------------------------------------------------------

# Release gate: the mod checks plus the release tooling tests.
check-release: check test-release

# Exercise releases using temporary repositories and local remotes only.
test-release:
    uv run --with markdown-it-py==4.0.0 python tests/release/test_release.py
    uv run --with markdown-it-py==4.0.0 python tests/release/test_manual_bbcode.py
    uv run python tests/release/test_nexus.py
    uv run --with markdown-it-py==4.0.0 python tests/release/test_archive.py
    uv run --with markdown-it-py==4.0.0 python tests/release/test_release_support.py
    uv run python tests/release/test_workshop.py

# Validate, record, push, package and publish a release from clean main.
release:
    uv run --with markdown-it-py==4.0.0 python scripts/release.py

# Package src/ from the working tree, including uncommitted files.
build-zip:
    uv run python scripts/release.py build-zip

# Stage src/ as a Workshop folder (ws_ manifest, packed catalog) in dist/workshop/local.
build-workshop:
    uv run python scripts/release.py build-workshop

# Minimal folder for the one-time WorkshopTool publish that creates the Workshop item.
workshop-placeholder:
    uv run python scripts/release.py workshop-placeholder

# Publish or resume an existing tagged release on Nexus Mods.
publish-nexus tag *args:
    uv run --with markdown-it-py==4.0.0 python scripts/release.py publish-nexus "{{tag}}" {{args}}

# Publish or resume a tagged release on the Steam Workshop (WorkshopTool; Steam must be running).
publish-steam tag *args:
    uv run python scripts/release.py publish-steam "{{tag}}" {{args}}

# Render and open the manual at a release tag, branch or commit without publishing anything.
nexus-description ref:
    uv run --with markdown-it-py==4.0.0 python scripts/manual_bbcode.py "{{ref}}"

# Junction src/ into the game's extensions folder for in-game testing.
link:
    & ./scripts/game_link.ps1 link

# Remove the extensions junction; never deletes a regular folder or the dev files.
unlink:
    & ./scripts/game_link.ps1 unlink

# Show whether the extensions folder holds a junction, a copied folder or nothing.
link-status:
    & ./scripts/game_link.ps1 status

# Follow the game's debug log; press Ctrl+C to stop.
log:
    & ./scripts/game_log.ps1
