# AGENTS.md

## Use X4 Claude Toolkit

This mod is developed using the x4-claude-toolkit. The toolkit can be found in
$CLAUDE_PROJECT_DIR or in `../../`. Abide by the toolkit's AGENTS.md
instructions.

## How to work with this repository

- Maintain a repo-local KNOWLEDGEBASE.md, in addition to the one in the toolkit
  file, with condensed details relevant for future development of this mod. Keep
  only lasting findings. Capture:
  - findings about the game engine
  - vanilla game mechanisms this mod interacts with
  - core mechanisms of this mod
  - experiments performed and their relevant findings
- Maintain a repo-root ARCHITECTURE.md with info about code organisation and
  module responsibilities.
- README.md and all files in `docs/` are end-user focused (players and mod
  developers) and maintained by the repo owner. Leave them alone.
- Maintain up-to-date architecture documentation in `ui/ARCHITECTURE.md`
- Keep code modules to a focused single reponsibility. Recommend refactorings if
  you spot code that violates this.
- Make sure to keep all language translation files in sync with the English
  version, in which the mod is developed. Auto-translate all new and changed
  keys into all languages.
- after each turn, inform the user whether a full restart is required, or if a
  `/reload` command suffices.

## Validation

- Use `just` to run checks (execut without options to get a list of possible
  tasks). Run validations for areas affected by your changes after each turn.
