# Contributing

Thank you for helping improve QMD Manager.

## Contribution principles

- Keep changes small, explicit, and tied to QMD Manager behavior or
  repository maintenance.
- Preserve compatibility between the PowerShell-native, short, and GNU-style
  command-line interfaces unless a breaking change is explicitly approved.
- Keep dependency policies, previews, tests, and user documentation aligned.
- Avoid adding third-party test dependencies unless they are explicitly
  approved.
- Do not commit secrets, tokens, passwords, or real environment values.
- Update `docs/repository-files.md` when repository files are added or changed.

## Before changing files

Review the existing repository context first:

- `README.md` for the repository purpose.
- `AGENTS.md` for coding-agent instructions.
- `CODING_RULES.md` and the applicable `LANGUAGE_RULES.md` sections for code.
- `DOCUMENTATION_RULES.md` for project documentation.
- `docs/repository-files.md` for the file inventory.

## Commit messages

Use `.gitmessage` as a commit message template when helpful:

```bash
git commit --template=.gitmessage
```

Commit messages must use scoped Conventional Commit headers that follow the
rules in `commitlint.config.cjs`, for example `docs(readme): update usage`.
Run `commitlint` manually or enable the repository hooks when strict local
validation is needed.

## Optional Git hooks

Enable the repository hook path when local pre-commit and commit-message
validation should run:

```bash
git config core.hooksPath .githooks
```

The pre-commit hook requires `markdownlint-cli2` for staged `*.md` files and
`yamllint` for staged `*.yml` or `*.yaml` files. The commit-msg hook requires
`commitlint` and rejects messages that do not match the repository-specific
scoped Conventional Commit rules.

## Release tags

Follow `RELEASE_RULES.md` before creating a release tag. New SemVer tags are
annotated unless an explicit repository-specific rule states otherwise. Do not
create, rewrite, or publish tags as part of an unrelated contribution.

## Pull requests

A good pull request should explain:

- What changed.
- Why the change is useful.
- How the change was verified.
- Whether any files were intentionally deferred, rejected, or removed.

## Verification

Before submitting changes, check that:

- Only expected files changed.
- `pwsh -NoLogo -NoProfile -File
  .\tests\Initialize-QmdCollection.Tests.ps1` passes for QMD script changes.
- PowerShell parsing and PSScriptAnalyzer pass for maintained PowerShell files.
- Bash syntax and ShellCheck pass for shell changes.
- Markdown, spelling, configuration, and secret scans pass when applicable.
- The repository inventory matches the files present in the repository.

When Git metadata and the required tools are available, run:

```bash
bash tools/repository-audit.sh readonly
```
