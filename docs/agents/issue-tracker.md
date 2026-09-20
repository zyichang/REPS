# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

> Note: the git remote points at GitHub (`zyichang/REPS`), but issues are
> deliberately **not** tracked there. Don't reach for `gh issue create` — it
> isn't installed, and this repo's convention is files. Same for the GitHub MCP
> server: use it for code and repo metadata, not for issues.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is a `Status:` line near the top of each issue file
  (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/`, creating the directory if needed.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the
issue number directly.
