# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

- **What it is:** {one sentence}.
- **Primary language(s):** {e.g. Python, PowerShell, T-SQL}.
- **Entry points:** {paths or scripts}.

## Setup

```sh
# install dependencies
```

## Build, test, lint

```sh
# build
# test
# lint
```

Run all three before proposing a change. Do not mark work complete if any fail.

## Conventions

- Match existing code style; do not reformat unrelated code.
- Keep changes minimal and focused on the requested task.
- New behavior requires tests. Bug fixes require a regression test.
- Update `README.md` and other docs when public behavior changes.
- Do not commit secrets, generated artifacts, or large binaries.

## Pull requests

- One logical change per PR.
- Reference the issue being addressed.
- Ensure CI is green before requesting review.

## Out of scope without explicit approval

- Dependency upgrades unrelated to the task.
- Refactors that touch files outside the change.
- Renames of public APIs, files, or workflows.
- Changes to CI, release, or security workflows.

## Security

See [SECURITY](SECURITY.md). Never include credentials, tokens, or customer data in code, tests, or fixtures.
