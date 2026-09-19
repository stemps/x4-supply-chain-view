# AGENTS.md

## Use X4 Claude Toolkit

This mod is developed using the x4-claude-toolkit. The toolkit can be found in $CLAUDE_PROJECT_DIR or in `../../`. Abide by the toolkit's AGENTS.md instructions.

## How to work with this repository

- Files in `docs/` are end-user focused (players and mod developers). Only put key user facing information there. Keep them very brief.
- Maintain up-to-date architecture documentation in `ui/ARCHITECTURE.md`
- Keep code modules to a focused single reponsibility. Recommend refactorings if you spot code that violates this.

## Validation

- Use `just` to run checks (execut without options to get a list of possible tasks). Run validations for areas affected by your changes after each turn.
