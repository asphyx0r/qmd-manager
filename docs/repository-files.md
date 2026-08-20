# Repository files

## Purpose

This document inventories the files and directories maintained for QMD Manager.

## Scope

This inventory covers project code, documentation, repository maintenance
assets, reusable templates, and paths that are deferred or explicitly excluded.

## Status definitions

- `required`: included in the maintained project core.
- `optional`: included in the repository, but safe to adapt or remove when its
  workflow is not used.
- `deferred`: not included and intentionally postponed until a concrete need is
  confirmed.
- `rejected`: not included because it does not fit the current project.
- `duplicate`: excluded because another path owns the same responsibility.

## File and directory records

### `.agents/`

- Type: `directory`
- Status: `optional`
- Goal: Stores repository-scoped Codex agent assets.
- Usage: Codex discovers checked-in skills from `.agents/skills` when working
  in this repository.
- Notes: Keep agent assets generic, explicit, and documented in this
  inventory.

### `.agents/skills/`

- Type: `directory`
- Status: `optional`
- Goal: Stores reusable Codex skills for repository workflows.
- Usage: Invoke skills explicitly when their workflow is requested.
- Notes: Keep each skill focused and avoid auxiliary documentation files.

### `.agents/skills/git-commit-push-tag/`

- Type: `directory`
- Status: `optional`
- Goal: Provides the canonical guarded SemVer analysis, remote audit preflight,
  and publication workflow.
- Usage: Use through `$git-commit-push-tag` only when explicitly requested.
- Notes: Repository mutation requires an explicit bump. GitHub Release
  publication requires a separate explicit parameter, a successful preflight
  of common release workflows and GitHub App configuration, and produces no
  assets.

### `.agents/skills/git-commit-push-tag/SKILL.md`

- Type: `file`
- Status: `optional`
- Goal: Loads the canonical guarded Git workflow instructions.
- Usage: Codex loads this file after explicit skill invocation.
- Notes: The canonical reference is the sole behavioral source of truth,
  including exact-file commit validation, remote audit checks, the common
  `Agent rules update` and `Repository audit` release runs, and the stable,
  asset-free GitHub Release contract.

### `.agents/skills/git-commit-push-tag/agents/`

- Type: `directory`
- Status: `optional`
- Goal: Stores Codex app metadata for the `git-commit-push-tag` skill.
- Usage: Keep machine-facing metadata separate from the skill instructions.
- Notes: Include only metadata needed for discovery, policy, or dependencies.

### `.agents/skills/git-commit-push-tag/agents/openai.yaml`

- Type: `file`
- Status: `optional`
- Goal: Configures display metadata and explicit-invocation policy for the
  `git-commit-push-tag` skill.
- Usage: Codex uses this metadata in skill UI and invocation policy handling.
- Notes: Advertises the guarded audit-preflight and asset-free release flow while
  `allow_implicit_invocation` remains `false`.

### `.agents/skills/git-commit-push-tag/references/`

- Type: `directory`
- Status: `optional`
- Goal: Stores the canonical workflow loaded by the skill.
- Usage: Keep behavioral reference files beside the skill that consumes them.
- Notes: Do not duplicate the canonical workflow in `SKILL.md`.

### `.agents/skills/git-commit-push-tag/references/git-commit-push-tag.txt`

- Type: `file`
- Status: `optional`
- Goal: Defines canonical bump analysis, exact commit validation, explicit
  release-artifact preparation, remote audit preflight, tag, atomic push,
  synchronization, and stable asset-free GitHub Release behavior.
- Usage: Read completely before the skill takes any action or runs Git.
- Notes: Preserve this file as the skill's sole behavioral source of truth. It
  requires the common `Agent rules update` and `Repository audit` release runs.

### `.betterleaks.toml`

- Type: `file`
- Status: `required`
- Goal: Defines strict Betterleaks secret scanning rules while retaining the
  rules built into the installed scanner.
- Usage: Betterleaks loads it automatically from the repository root.
- Notes: Keep it byte-for-byte identical to `.gitleaks.toml`.

### `.codespellrc`

- Type: `file`
- Status: `required`
- Goal: Configures Codespell for lightweight spelling checks.
- Usage: Run `codespell` from the repository root.
- Notes: Checks hidden files, file names, and tracked workspace configs while
  skipping generated, dependency, report, cache, runtime, temporary, archive,
  binary, and canonical French reference paths.

### `.editorconfig`

- Type: `file`
- Status: `required`
- Goal: Defines editor-level formatting defaults for the project.
- Usage: Editors and IDEs that support EditorConfig apply these settings.
- Notes: Keep rules language-family oriented rather than framework-specific,
  with a dedicated Git config rule for tab-indented config templates.

### `.gitattributes`

- Type: `file`
- Status: `required`
- Goal: Defines Git text normalization and common binary formats.
- Usage: Git normalizes text to LF and preserves CRLF for Windows scripts.
- Notes: Keep the binary list focused on common formats.

### `.gitleaks.toml`

- Type: `file`
- Status: `required`
- Goal: Defines strict Gitleaks rules for credential assignments,
  authorization headers, and credentials in service URIs.
- Usage: Gitleaks loads it automatically from the repository root.
- Notes: Keep it byte-for-byte identical to `.betterleaks.toml`; inherited
  default rules remain enabled.

### `.github/`

- Type: `directory`
- Status: `required`
- Goal: Stores GitHub-specific community and collaboration files.
- Usage: Keep GitHub files here when the platform expects this location.
- Notes: Avoid duplicating root-level files in this directory.

### `.github/ISSUE_TEMPLATE/`

- Type: `directory`
- Status: `optional`
- Goal: Stores GitHub issue templates for common repository feedback.
- Usage: GitHub uses these files to prefill new issue forms.
- Notes: Keep templates lightweight and avoid project-specific automation.

### `.github/ISSUE_TEMPLATE/bug_report.md`

- Type: `file`
- Status: `optional`
- Goal: Guides issue authors through a clear bug report.
- Usage: Use for reproducible problems with repository files or templates.
- Notes: Keep reproduction and verification prompts concise.

### `.github/ISSUE_TEMPLATE/documentation.md`

- Type: `file`
- Status: `optional`
- Goal: Guides issue authors through documentation feedback.
- Usage: Use for unclear, missing, outdated, or incorrect documentation.
- Notes: Prefer concrete locations and proposed wording.

### `.github/ISSUE_TEMPLATE/feature_request.md`

- Type: `file`
- Status: `optional`
- Goal: Guides issue authors through proposed repository improvements.
- Usage: Use for QMD Manager improvements or repository maintenance proposals.
- Notes: Keep proposals scoped and tied to a concrete need.

### `.github/PULL_REQUEST_TEMPLATE.md`

- Type: `file`
- Status: `required`
- Goal: Provides a lightweight GitHub pull request template.
- Usage: GitHub uses this file to prefill pull request descriptions.
- Notes: Guide review without introducing CI/CD requirements.

### `.github/workflows/`

- Type: `directory`
- Status: `optional`
- Goal: Stores GitHub Actions workflows for repository-level automation.
- Usage: Keep only lightweight, generic workflows in this directory.
- Notes: Avoid adding application build, test, deploy, or release pipelines
  unless a concrete project need is approved.

### `.github/workflows/repository-audit.yml`

- Type: `file`
- Status: `optional`
- Goal: Runs the shared repository audit and publishes one aggregate required
  check on GitHub Actions.
- Usage: Executes on pushes, pull requests, published releases, and manual
  dispatch.
- Notes: The workflow uses a pinned runner and a checkout action pinned by
  SHA for `actions/checkout@v7.0.0`. It delegates Markdown, spelling,
  static, smoke, and configuration rules to `tools/repository-audit.sh` so
  local and CI audits share the same source of truth. Push and release runs
  validate the complete applicable commit range, and one aggregation job must
  succeed after every required audit job. Tool downloads are version-pinned
  but not hash-verified;
  this is an accepted lightweight CI tradeoff for this repository with
  read-only repository audit permissions, disabled checkout credential
  persistence, and without forwarding the workflow token to checked-out audit
  code.

### `.github/workflows/agent-rules-update.yml`

- Type: `file`
- Status: `optional`
- Goal: Proposes canonical rule updates directly from `agent-coding-rules`.
- Usage: Runs daily, on every published release, or by manual dispatch and
  opens a repository-local pull request when safe updates exist.
- Notes: Preserves customized rules. Set `AGENT_RULES_SYNC_ENABLED=false` to
  suspend scheduled and manual runs; published releases always run the job.
  The guarded release flow requires the repository variable
  `AGENT_RULES_APP_CLIENT_ID` and secret `AGENT_RULES_APP_PRIVATE_KEY` before
  publication, then requires the exact automatic release run to succeed.

### `.github/workflows/release-artifacts.yml`

- Type: `file`
- Status: `required`
- Goal: Validates the three release-identification artifacts for every pushed
  SemVer tag.
- Usage: Runs automatically on tag pushes matching `v*`.
- Notes: Installs the pinned JSON Schema validator, reads the exact tagged Git
  tree, and blocks the `Release artifacts` check when `VERSION`,
  `SHA256SUMS`, or `manifest.json` is missing, stale, or inconsistent.

### `.githooks/`

- Type: `directory`
- Status: `optional`
- Goal: Stores opt-in Git hooks for local repository validation.
- Usage: Enable with `git config core.hooksPath .githooks` when local hooks are
  desired.
- Notes: Hooks remain versioned but inactive until each clone opts in.

### `.githooks/commit-msg`

- Type: `file`
- Status: `optional`
- Goal: Blocks commits when commit messages fail scoped Conventional Commit
  validation.
- Usage: Runs through Git after `core.hooksPath` points to `.githooks`.
- Notes: Checks the commit message file with `commitlint.config.cjs`.

### `.githooks/pre-commit`

- Type: `file`
- Status: `optional`
- Goal: Blocks commits when staged documentation, configuration, or release
  artifacts fail their repository-owned validation.
- Usage: Runs through Git after `core.hooksPath` points to `.githooks`.
- Notes: Checks staged `*.md` files with `markdownlint-cli2`, staged `*.yml`
  or `*.yaml` files with `yamllint`, and requires `VERSION`,
  `SHA256SUMS`, and `manifest.json` to be staged and validated together.

### `.githooks/pre-push`

- Type: `file`
- Status: `required`
- Goal: Prevents a SemVer release tag from being pushed with missing or stale
  release-identification artifacts.
- Usage: Runs through Git after `core.hooksPath` points to `.githooks`.
- Notes: Validates each pushed `refs/tags/v*` tree with the tracked release
  artifact tool. Historical and non-release refs are not reclassified.

### `.gitignore`

- Type: `file`
- Status: `required`
- Goal: Prevents common local files and generated artifacts from commits.
- Usage: Git excludes matching paths from normal version control.
- Notes: Covers common credential stores, direnv files, runtime storage, and
  generated files while avoiding source files, tests, lock files, or project
  config.

### `.gitmessage`

- Type: `file`
- Status: `required`
- Goal: Provides a reusable commit message template.
- Usage: Use with `git commit --template=.gitmessage` or local Git config.
- Notes: Advisory only; it uses scoped Conventional Commit examples and does
  not enforce commit validation.

### `.markdownlint-cli2.yaml`

- Type: `file`
- Status: `required`
- Goal: Defines the portable Markdown lint baseline shared by generated
  repositories.
- Usage: Markdownlint CLI tools load it from the repository root.
- Notes: Keeps the default rules while allowing 120-character lines outside
  code blocks, headings, and tables, and limits duplicate-heading checks to
  sibling sections. Repository-specific proper-name and link-style policies
  remain local extensions.

### `.vscode/`

- Type: `directory`
- Status: `optional`
- Goal: Stores Visual Studio Code workspace recommendations.
- Usage: VS Code reads supported workspace files from this directory.
- Notes: Keep only recommendations that fit the maintained project files.

### `.vscode/extensions.json`

- Type: `file`
- Status: `optional`
- Goal: Recommends VS Code extensions useful for QMD Manager maintenance.
- Usage: VS Code suggests these extensions when the repository is opened.
- Notes: Keep recommendations generic and avoid personal preferences.

### `.vscode/settings.json`

- Type: `file`
- Status: `optional`
- Goal: Defines shared VS Code workspace defaults for QMD Manager.
- Usage: VS Code applies these settings when the repository is opened.
- Notes: Keep settings aligned with `.editorconfig` and generic editor
  recommendations. Format-on-save settings are human VS Code defaults only;
  they do not permit agents to run formatters or automatic fixers.

### `_agent-rules-source.json`

- Type: `file`
- Status: `required`
- Goal: Records repository, starter-kit, and canonical rule provenance.
- Usage: The autonomous synchronization workflow updates agent-rules data. A
  cumulative starter-kit upgrade updates only `repository` and `starterKit`.
  Provenance checks review the combined record.
- Notes: Schema 3 records source hashes and customized rules under
  `preservedFiles`.

### `.starter-kit-adoption.json`

- Type: `file`
- Status: `optional`
- Goal: Records the verified starter-kit package adopted by QMD Manager.
- Usage: Review with `_starter-kit-files.json` before aligning managed files.
- Notes: Stores the current archive hash and starter-kit ref, the audited
  repository baseline, accepted merge-file digests, and the immutable original
  starter-kit source.

### `_starter-kit-files.json`

- Type: `file`
- Status: `optional`
- Goal: Records the starter-kit-managed baseline used for audited alignment.
- Usage: Consult with `_agent-rules-source.json` before planning an alignment.
- Notes: Schema 3 stores SHA-256 digests, Git modes, and `agent-rules`,
  `replace`, `merge`, `initialize-only`, or `starter-kit-state` strategies.
  The manifest does not include its own digest.

### `starter-kit-manifest.json`

- Type: `file`
- Status: `required`
- Goal: Records the original and current published starter-kit core baselines.
- Usage: Inspect `source` for the initial package and `current` for the latest
  cumulative core upgrade.
- Notes: Preserves `source=v2.3.3` while recording `current=v2.5.0`, with the
  strategy, mode, and digest of every managed core file.

### `VERSION`

- Type: `file`
- Status: `optional`
- Goal: Stores the exact SemVer number of the release identified by the tag.
- Usage: Read the single UTF-8 line without the tag's leading `v`.
- Notes: Generated immediately before a future release tag. It is not created
  by this starter-kit alignment.

### `SHA256SUMS`

- Type: `file`
- Status: `optional`
- Goal: Records deterministic SHA-256 digests for the tagged release tree.
- Usage: Validate each listed Git blob by its repository-relative path.
- Notes: Includes `VERSION` and excludes gitlinks, untracked or ignored files,
  plus the self-referential `SHA256SUMS` and `manifest.json` outputs. It is
  not created by this starter-kit alignment.

### `manifest.json`

- Type: `file`
- Status: `optional`
- Goal: Describes the exact tagged release tree and its explicit release
  metadata.
- Usage: Validate it with `templates/release/manifest.schema.json` and compare
  its inventory with `SHA256SUMS`.
- Notes: Generated from `templates/release/manifest.template.json`. Unknown
  release metadata must be supplied by the user and is never inferred. It is
  not created by this starter-kit alignment.

### `AGENTS.md`

- Type: `file`
- Status: `required`
- Goal: Provides repository-level instructions for coding agents.
- Usage: Read before making changes in this repository.
- Notes: Avoid duplicating agent instructions in GitHub-specific files.

### `CODING_RULES.md`

- Type: `file`
- Status: `required`
- Goal: Defines language-agnostic code quality rules for coding agents.
- Usage: Read before creating, editing, reviewing, or refactoring project code.
- Notes: Apply with `AGENTS.md` and the relevant language-specific rules.

### `COMMIT_RULES.md`

- Type: `file`
- Status: `required`
- Goal: Defines repository commit preparation and message requirements.
- Usage: Read before creating a commit after Git metadata has been initialized.
- Notes: Commit authorization does not imply push, tag, or release authority.

### `DOCUMENTATION_RULES.md`

- Type: `file`
- Status: `required`
- Goal: Defines quality and verification rules for project documentation.
- Usage: Read before creating, editing, reviewing, or refactoring documentation.
- Notes: Apply the coding and language rules to executable documentation
  examples.

### `LANGUAGE_RULES.md`

- Type: `file`
- Status: `required`
- Goal: Defines language-, dialect-, and framework-specific coding rules.
- Usage: Apply only the sections that match the files in the current task.
- Notes: More specific repository or language rules take precedence over
  general code-quality guidance.

### `RELEASE_RULES.md`

- Type: `file`
- Status: `required`
- Goal: Defines Git tag and release preparation requirements.
- Usage: Read before creating a Git tag or publishing a release.
- Notes: Release work requires explicit authorization and verified repository
  state.

### `CHANGELOG.md`

- Type: `file`
- Status: `required`
- Goal: Tracks notable changes to QMD Manager.
- Usage: Add release entries only after corresponding Git tags exist.
- Notes: Contains one three-column commit table per existing release tag and no
  `Unreleased` section. Generic placeholders belong in
  `templates/CHANGELOG.md`.

### `CODE_OF_CONDUCT.md`

- Type: `file`
- Status: `optional`
- Goal: Defines expected behavior for participation in this repository.
- Usage: Read before contributing or participating in project discussions.
- Notes: Keep GitHub-specific duplicates out of `.github/` and document an
  enabled private path for sensitive conduct reports.

### `commitlint.config.cjs`

- Type: `file`
- Status: `required`
- Goal: Defines the default commitlint rules for Conventional Commits.
- Usage: Run `commitlint` from the repository root or from a commit-msg hook.
- Notes: Keeps parser options and strict commit rules explicit to reject
  loosely formatted or unscoped commit messages.

### `CONTRIBUTING.md`

- Type: `file`
- Status: `required`
- Goal: Explains how contributors should propose and verify changes.
- Usage: Read before contributing to QMD Manager.
- Notes: Documents optional Git hook activation and scoped commit message
  validation. Future-project placeholders belong in `templates/CONTRIBUTING.md`.

### `LICENSE`

- Type: `file`
- Status: `required`
- Goal: Defines the legal terms for using and redistributing this repository.
- Usage: Reference this file from README files.
- Notes: This repository uses the MIT License with `asphyx` as holder.

### `README.md`

- Type: `file`
- Status: `required`
- Goal: Introduces QMD Manager behavior, requirements, usage, and maintenance.
- Usage: Read first before initializing a QMD collection.
- Notes: Documents the PowerShell workflow, dry-run behavior, partial-failure
  handling, repository audits, provenance, contribution guidance, and license.

### `SECURITY.md`

- Type: `file`
- Status: `required`
- Goal: Explains how to report security issues for this repository.
- Usage: Use for suspected vulnerabilities in QMD Manager or its repository
  automation.
- Notes: Requires GitHub private vulnerability reporting to remain enabled
  instead of inventing maintainer email addresses or response timelines.

### `SUPPORT.md`

- Type: `file`
- Status: `optional`
- Goal: Explains where users can get help for this repository.
- Usage: Read before opening support questions or asking for help.
- Notes: Keep support scope distinct from security reporting.

### `scripts/`

- Type: `directory`
- Status: `required`
- Goal: Stores project-specific runtime and automation scripts.
- Usage: Keep QMD Manager behavior separate from repository-maintenance tools.
- Notes: Scripts in this directory must follow the project coding, language,
  and EditorConfig rules.

### `scripts/Initialize-QmdCollection.ps1`

- Type: `file`
- Status: `required`
- Goal: Prepares QMD prerequisites and initializes a Markdown collection.
- Usage: Run with a collection path, name, and context; use `-DryRun`,
  `--dry-run`, or `-WhatIf` to evaluate the workflow without mutations.
- Notes: Requires Windows 11, PowerShell 7.x, Node.js 22.22.2 or later, npm
  from 11.16.0 through the 12.x line, and npm-global QMD 2.5.3. It validates
  the QMD name grammar and recursive Markdown presence before platform or
  network operations, uses deterministic package targets and strict lifecycle
  script approval, shares management policy between previews and real runs,
  supports native and legacy parameters, and may retain partial QMD state when
  a later workflow step fails.

### `scripts/Invoke-QmdBackup.ps1`

- Type: `file`
- Status: `required`
- Goal: Creates validated QMD backup archives and transactionally restores
  them after preparing a rollback archive.
- Usage: Use `--backup` with an output directory or `--restore` with a source
  archive; run `--dry-run` before either operation.
- Notes: Supports index-only, full-data, and offline-model backup modes. It
  requires PowerShell 7.4, validates the QMD environment and archive manifests,
  and reserves `--force` for explicit non-interactive replacement approval.

### `tests/`

- Type: `directory`
- Status: `required`
- Goal: Stores dependency-free automated tests for project-specific behavior.
- Usage: Run the maintained test entry points before submitting script changes.
- Notes: Tests may create isolated temporary files but must not modify tracked
  repository content or external QMD state.

### `tests/Initialize-QmdCollection.Tests.ps1`

- Type: `file`
- Status: `required`
- Goal: Verifies QMD Manager parsing, validation, dependency policy, previews,
  help, version output, and mutation guards.
- Usage: Run with PowerShell 7 from any working directory.
- Notes: Uses built-in assertions and controlled function replacement instead
  of Pester or real prerequisite and QMD mutations.

### `tests/Invoke-QmdBackup.Tests.ps1`

- Type: `file`
- Status: `required`
- Goal: Verifies QMD backup and restore parsing, validation, planning,
  manifests, stable copies, rollback, and mutation guards.
- Usage: Run with PowerShell 7.4 or newer from any working directory.
- Notes: Uses built-in assertions and isolated temporary content instead of
  Pester or the operator's real QMD environment.

### `tests/test_backup_target_directory.py`

- Type: `file`
- Status: `optional`
- Goal: Verifies the generic backup tool's CLI, Git provenance, safety checks,
  staging cleanup, archive contents, and readable ZIP output.
- Usage: Run
  `python -B -m unittest discover -s tests -p "test_backup_target_directory.py"`.
- Notes: Uses only `unittest` and the Python standard library. Git-dependent
  and symbolic-link cases skip only when the required platform capability is
  unavailable.

### `tests/test_release_artifacts.py`

- Type: `file`
- Status: `required`
- Goal: Verifies deterministic artifact generation, explicit metadata gates,
  SemVer handling, schema validation, index checks, and tag checks.
- Usage: Install `tools/release-artifacts-requirements.txt`, then run
  `python -B -m unittest tests.test_release_artifacts`.
- Notes: Uses temporary Git repositories and leaves the source repository
  unchanged.

### `tests/test_commit_message_validation.sh`

- Type: `file`
- Status: `optional`
- Goal: Verifies exact commit-message validation, forced hooks, and audit
  ranges for branches and tags.
- Usage: Run with Git Bash after the required Git, Node.js, npm, and Commitlint
  dependencies are available.
- Notes: Creates only disposable Git repositories outside the maintained
  working tree.

### `tests/test_verify_repository_audit_runs.py`

- Type: `file`
- Status: `optional`
- Goal: Verifies exact GitHub Actions run selection for every required ref.
- Usage: Run
  `python -B -m unittest discover -s tests -p "test_verify_repository_audit_runs.py"`.
- Notes: Uses in-memory fixtures, validates help, version, and dry-run
  behavior, and performs no GitHub query.

### `tools/`

- Type: `directory`
- Status: `optional`
- Goal: Stores small repository management and maintenance tools.
- Usage: Keep tools generic and tied to documented repository workflows.
- Notes: Avoid project-specific build, test, or deploy automation here.

### `tools/backup-target-directory.py`

- Type: `file`
- Status: `optional`
- Goal: Creates a staged ZIP backup of a directory tree with Git provenance in
  the archive name.
- Usage: Run with an existing source and external target directory; use
  `--dry-run` before creating the archive.
- Notes: Uses only the Python standard library, includes `.git` and all files
  present during staging, rejects symbolic links, and accepts an optional
  staging parent. The archive name contains the captured 12-character `HEAD`
  and only a SemVer tag that points to that commit. The copy is not
  transactional and does not preserve every NTFS metadata class or add a
  cryptographic manifest.

### `tools/README.md`

- Type: `file`
- Status: `optional`
- Goal: Documents the repository tools with man-page-style operational
  reference sections.
- Usage: Read before running scripts in `tools/` to understand their purpose,
  command-line interfaces, examples, exit status, and best practices.
- Notes: Keep entries aligned with current tool behavior whenever scripts are
  changed. Documents execution-policy troubleshooting for downloaded
  `git-init.ps1` copies, the backup tool's provenance and restoration limits,
  exact commit validation, and repository-audit run verification.

### `tools/repository-audit.sh`

- Type: `file`
- Status: `optional`
- Goal: Runs the shared local and CI repository audit rules.
- Usage: Run `bash tools/repository-audit.sh` locally before creating a
  release tag or GitHub release. GitHub Actions invokes the same script with
  mode-specific `markdown`, `spelling`, and `static` arguments.
- Notes: Defaults to the full profile, with `full` as an explicit alias. Full
  profiles own Markdown lint, spelling, Git whitespace, Bash syntax, ShellCheck
  for shell scripts and Git hooks, complete PowerShell parsing, QMD Manager,
  Python, and release-artifact tests, cross-language SemVer pattern drift
  checks, workflow and secret scanner contracts, smoke behavior, Commitlint
  configuration, exact message fixtures, and commit checks for the complete
  applicable range. The
  optional `readonly` profile uses installed tools, disables optional Git
  locks, avoids network access, package installation, tracked-file changes,
  and mutating smoke tests, and also checks YAML, workflows, and secrets. It
  may use isolated temporary files for parsing and tests. Full profiles
  bootstrap pinned Codespell and JSON Schema dependencies in temporary Python
  targets, handle WSL-aware
  PowerShell command, path, and temporary directory compatibility through the
  ignored `.tmp/` path when needed, use
  version-pinned package downloads without hash verification, document the
  npm and PyPI network requirements, and fail when required local
  tools are unavailable instead of silently skipping CI rules.

### `tools/release-artifacts.py`

- Type: `file`
- Status: `required`
- Goal: Prepares and validates `VERSION`, `SHA256SUMS`, and `manifest.json`
  against an exact Git tree.
- Usage: Run `prepare` with a SemVer tag, one UTC release timestamp, and an
  explicit metadata JSON file outside the repository; run `check` against the
  index or a tagged tree.
- Notes: Inventories Git blobs, ignores untracked and ignored content,
  validates Draft 2020-12 JSON Schema formats, and never derives unknown
  business metadata.

### `tools/release-artifacts-requirements.txt`

- Type: `file`
- Status: `required`
- Goal: Pins the runtime validator used for generated release manifests.
- Usage: Install it before running the release artifact tool or its tests.
- Notes: Uses the `jsonschema[format]` extra so URI and date-time formats are
  enforced during manifest validation.

### `tools/verify-repository-audit-runs.py`

- Type: `file`
- Status: `optional`
- Goal: Waits for the exact successful GitHub Actions push runs required for
  guarded repository publication.
- Usage: Supply the repository, workflow ID, exact SHA, UTC lower bound, and
  one `--ref` per expected branch or tag; use `--dry-run` first.
- Notes: Uses authenticated read-only `gh api` queries and rejects missing,
  ambiguous, unrelated, or unsuccessful runs.

### `tools/git-init.ps1`

- Type: `file`
- Status: `optional`
- Goal: Initializes a target Git repository from PowerShell after explicit
  user confirmation.
- Usage: Run with `--path <directory>` and optional `--tag <tag>`,
  `--remote <url>`, and `--verbose`. Run without arguments to show help.
- Notes: Requires Bash 4 or newer, validates SemVer tags covered by CI smoke
  cases, requires
  existing non-empty target directories,
  previews committable files from Git porcelain status without creating target
  Git metadata, explains invalid preexisting `.git` metadata, warns on risky
  credential, direnv, and artifact paths, refuses
  existing target commits, writes prompts without polluting confirmation
  return values, reads confirmation answers from standard input for
  deterministic CI smoke tests, warns on runtime storage paths, validates one
  UTF-8 message file with Commitlint and forced repository hooks, preserves the
  exact committed message, tags it, and only pushes when `--remote` is
  provided.

### `tools/git-init.sh`

- Type: `file`
- Status: `optional`
- Goal: Initializes a target Git repository from Bash after explicit user
  confirmation.
- Usage: Run with `--path <directory>` and optional `--tag <tag>`,
  `--remote <url>`, and `--verbose`. Run without arguments to show help.
- Notes: Validates SemVer tags covered by CI smoke cases, requires
  existing non-empty target directories,
  previews committable files from Git porcelain status without creating target
  Git metadata, explains invalid preexisting `.git` metadata, warns on risky
  credential, direnv, artifact, and runtime storage paths, refuses existing
  target commits, validates one exact message file with Commitlint and forced
  repository hooks, creates the first Conventional Commit on `main`, tags it,
  and only pushes when `--remote` is provided.

### `docs/`

- Type: `directory`
- Status: `required`
- Goal: Stores repository documentation.
- Usage: Keep maintained QMD Manager and repository-operation documentation
  here.
- Notes: Avoid duplicating root-level community files.

### `docs/SKILLS.md`

- Type: `file`
- Status: `optional`
- Goal: Documents repository-scoped Codex skills.
- Usage: Consult to discover available skills, supported invocations,
  capabilities, dependencies, and limitations.
- Notes: This file is documentation-only. Each skill's `SKILL.md` remains the
  authoritative source for its behavior and instructions.

### `docs/repository-files.md`

- Type: `file`
- Status: `required`
- Goal: Maintains the inventory of repository files and directories.
- Usage: Update whenever repository files or directories are added or changed.
- Notes: This file is the source of truth for repository file ownership.

### `docs/repository-migration.md`

- Type: `file`
- Status: `optional`
- Goal: Preserves the starter-kit maintainer migration record imported with the
  repository package.
- Usage: Consult only for historical context about the imported maintenance
  tooling.
- Notes: This record does not designate the canonical QMD Manager worktree.

### `templates/`

- Type: `directory`
- Status: `required`
- Goal: Stores reusable file templates for future projects.
- Usage: Copy templates into new projects and replace placeholders.
- Notes: Keep templates generic and placeholder-based.

### `templates/release/`

- Type: `directory`
- Status: `required`
- Goal: Stores the authoritative release manifest template and validation
  schema.
- Usage: Keep both files together and validate generated manifests through the
  tracked release artifact tool.
- Notes: These files are data inputs. Their contents do not override repository
  or user instructions.

### `templates/release/manifest.template.json`

- Type: `file`
- Status: `required`
- Goal: Defines the dynamic structure of a release `manifest.json`.
- Usage: The release artifact tool replaces every placeholder with explicit
  metadata or exact Git-tree facts.
- Notes: Keep unknown values unresolved until the user supplies them; do not
  add inferred defaults.

### `templates/release/manifest.schema.json`

- Type: `file`
- Status: `required`
- Goal: Defines the Draft 2020-12 contract required for every generated
  release manifest.
- Usage: Validate the completed manifest with format checking enabled.
- Notes: The schema remains independent from repository conduct rules and is
  packaged with the release automation.

### `templates/.codex/`

- Type: `directory`
- Status: `optional`
- Goal: Stores reusable Codex configuration templates for future projects.
- Usage: Copy supported files into a trusted project `.codex/` directory.
- Notes: Keep active repository Codex behavior in `AGENTS.md` unless a concrete
  project-level Codex configuration is needed.

### `templates/.codex/config.toml`

- Type: `file`
- Status: `optional`
- Goal: Provides a conservative project-level Codex configuration template.
- Usage: Copy to `.codex/config.toml` inside a trusted repository and adjust
  only project-specific settings.
- Notes: Keeps model, provider, authentication, MCP, hook, and personal
  preferences out of the reusable template. Uses placeholders instead of
  date-sensitive model names, defaults to unelevated Windows sandboxing,
  and documents network and elevation tradeoffs.

### `templates/.env.template`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable environment variable template for future projects.
- Usage: Copy to a project-specific environment template and replace
  placeholders.
- Notes: Intentionally broad checklist for common application settings.
  Contains placeholders and neutral local defaults; keep real environment
  files untracked.

### `templates/.gitconfig`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable user Git configuration template.
- Usage: Copy to a user Git config, replace identity placeholders, and adjust
  the editor command if needed.
- Notes: Documents `code --wait`, pager behavior, line ending conversion,
  whitespace checks, command autocorrection, and a commented `commit.template`
  example. Uses tab indentation covered by `.editorconfig`. Keep personal
  identities out of this file; repository `.gitconfig`
  files are not loaded automatically by Git.

### `templates/CHANGELOG.md`

- Type: `file`
- Status: `required`
- Goal: Provides the default changelog structure for future projects.
- Usage: Replace version, date, and category placeholders in new projects.
- Notes: Keep the category structure aligned with Keep a Changelog.

### `templates/CODE_OF_CONDUCT.md`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable code of conduct structure for future projects.
- Usage: Replace placeholders with project-specific behavior and policy details.
- Notes: Keep the root file concrete and this file generic.

### `templates/CONTRIBUTING.md`

- Type: `file`
- Status: `required`
- Goal: Provides a reusable contribution guide structure.
- Usage: Replace placeholders with project-specific contribution policies.
- Notes: Keep the root file concrete and this file generic.

### `templates/GITHUB_RELEASE_NOTES.md`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable GitHub release notes structure.
- Usage: Copy into a GitHub release draft and replace placeholders.
- Notes: Keep release notes concise and aligned with the project changelog.

### `templates/README.md`

- Type: `file`
- Status: `required`
- Goal: Provides the default README structure for future projects.
- Usage: Replace placeholders with project-specific content.
- Notes: Keep the root README concrete and this file generic.

### `templates/README_TOOLS.md`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable README structure for directories that contain
  scripts, command-line tools, or maintenance utilities.
- Usage: Copy to a tool directory as `README.md`, then replace placeholders
  with exact commands, options, inputs, outputs, side effects, and exit codes.
- Notes: Use for collections such as `tools/`; keep per-tool entries aligned
  with the current implementation and avoid inventing undocumented behavior.

### `templates/SECURITY.md`

- Type: `file`
- Status: `required`
- Goal: Provides a reusable security policy structure.
- Usage: Replace placeholders with project-specific security policy details.
- Notes: Keep the root file concrete and this file generic.

### `templates/SKILLS.md`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable documentation-only inventory structure for Codex
  skills.
- Usage: Copy to a repository documentation directory as `SKILLS.md`, then
  replace placeholders from existing skill source files.
- Notes: Keep the generated inventory in English, source-based, and limited to
  capabilities and paths that actually exist. Each `SKILL.md` file remains
  authoritative.

### `templates/SUPPORT.md`

- Type: `file`
- Status: `optional`
- Goal: Provides a reusable support policy structure for future projects.
- Usage: Replace placeholders with project-specific support channels.
- Notes: Keep the root file concrete and this file generic.
