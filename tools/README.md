# Tools

<!-- markdownlint-disable MD024 -->

This directory contains repository management tools retained for QMD Manager.
Each tool is documented as an operational reference: what it does, how to run
it, which options it accepts, how it exits, and what practices keep usage safe.

## backup-target-directory.py

### Features

- Copies an entire source directory tree into a temporary staging directory.
- Includes Git metadata, hidden files, and tracked, untracked, or ignored files
  that are present during the copy.
- Creates a compressed ZIP archive in a separate existing target directory.
- Rejects symbolic links in the source tree.
- Names archives with the source directory, timestamp, Git `HEAD`, and an exact
  matching SemVer tag.
- Supports a side-effect-free dry run and an optional staging parent directory.

### Synopsis

```text
usage: python tools/backup-target-directory.py [options]

options:
  -h, --help                       show help and exit
  --version                        show version and exit
  --dry-run                        simulate execution without modifying data
  -v, --verbose                    enable DEBUG logs
  -d, --source-directory BASEDIR   existing source directory tree to back up
  -t, --target-directory TARGETDIR existing directory for the ZIP archive
  -b, --buffer-directory BUFFERDIR existing staging parent directory
```

### Description

`backup-target-directory.py` creates a staged ZIP backup of an existing
directory tree. The target and staging directories must remain outside the
source so the generated data cannot enter the backup. The script copies the
source to temporary staging before creating a same-directory temporary ZIP and
publishing the final archive.

When the source belongs to a readable Git repository, the archive name records
the 12-character abbreviated `HEAD`. It includes a SemVer tag only when that
tag points exactly to the captured commit. Every final archive uses this
format:

```text
<SOURCE>-<YYYYMMDD>-<HHMMSS>-<HEAD>-<SEMVER-TAG>.zip
```

For example:

```text
git-starter-kit-20260730-165813-0d3ae03a4a86-v2.0.3.zip
```

When no commit can be read, `<HEAD>` is `000000000000`. When no matching
SemVer tag can be read, `<SEMVER-TAG>` is `v0.0.0`. These placeholders keep
the filename structure stable.

After staging, the script resolves the source Git identity again. It stops
before ZIP creation if `HEAD` or the selected tag changed during the copy.

### Usage/Examples

Preview a backup of the current repository into an existing sibling
directory:

```bash
python tools/backup-target-directory.py \
  --dry-run \
  --source-directory . \
  --target-directory ../backups
```

Create the archive:

```bash
python tools/backup-target-directory.py \
  --source-directory . \
  --target-directory ../backups
```

Use an existing staging parent on another volume:

```bash
python tools/backup-target-directory.py \
  --source-directory . \
  --target-directory ../backups \
  --buffer-directory /path/to/staging
```

### Options

- `-h`, `--help`: prints the version and usage information, then exits.
- `--version`: prints script version `0.1.0`, then exits.
- `--dry-run`: validates the source, target, staging location, symbolic-link
  policy, Git identity, and final name without creating staging data or a ZIP.
- `-v`, `--verbose`: prints DEBUG logs in addition to normal status messages.
- `-d PATH`, `--source-directory PATH`: existing directory tree to back up.
  This option is required.
- `-t PATH`, `--target-directory PATH`: existing directory where the ZIP is
  created. This option is required and must not be inside the source.
- `-b PATH`, `--buffer-directory PATH`: optional existing staging parent. An
  unusable value produces a warning and falls back to the user temporary
  directory.

### Exit Status

- `0`: help or version was shown, the dry run completed, or the archive was
  created successfully.
- `1`: path or filesystem validation failed, a symbolic link was found, the
  Git identity changed during staging, or staging/archive creation failed.
- `2`: command-line argument parsing failed.

The script also refuses to run with effective user ID `0` on Linux.

### Appendix

This is a staged filesystem copy, not a transactional repository snapshot.
The post-copy check detects changes to `HEAD` or the selected tag, but not
concurrent edits to working-tree files, the index, other refs, or reflogs. Stop
repository writers while the backup runs when a restorable point-in-time copy
is required.

The archive includes `.git` when it is contained in the source. Linked
worktrees and submodules may instead use a `.git` file that refers to metadata
outside the source; such an archive is not self-contained.

ZIP preserves file bytes and modification times at ZIP precision, but this
tool does not preserve NTFS ACLs, alternate data streams, creation/access
times, or a cryptographic manifest. The `v0.0.0` placeholder is also
indistinguishable in the filename from a real tag with that exact name.

## git-init.ps1

### Features

- Initializes an existing non-empty directory as a Git repository.
- Previews committable files before creating target Git metadata.
- Requires explicit confirmation before initialization and commit.
- Warns before committing risky credential, archive, cache, or runtime paths.
- Validates the exact initial message with Commitlint and the repository hook.
- Creates the first Conventional Commit on `main`.
- Creates an annotated SemVer tag and optionally pushes to `origin`.

### Synopsis

```text
usage: powershell -NoProfile -File tools\git-init.ps1 [options]

options:
  -h, --help       show version and help
      --version    show version only
  -v, --verbose    show additional execution traces
  -p, --path PATH  target repository root, required
  -r, --remote URL optional origin remote URL
  -t, --tag TAG    SemVer Git tag, default: v1.0.0
```

### Description

`git-init.ps1` is the PowerShell initializer for creating the first Git history
in a target project directory. It requires the target directory to already
exist and contain files. If `.git` metadata already exists, it must be readable
and the repository must not already have commits.

The script asks for confirmation, previews files Git can commit, asks for a
second confirmation, and warns on risky paths when needed. Before committing,
it writes the exact message to a temporary UTF-8 file without a byte-order
mark, validates that file with Commitlint, and forces the repository
`commit-msg` hook. It verifies the recorded message, removes the temporary
file, renames the branch to `main`, and creates an annotated tag. It pushes only
when `--remote` is provided.

### Usage/Examples

Initialize a local target directory:

```powershell
powershell -NoProfile -File tools\git-init.ps1 `
  --path ..\example-app `
  --tag v1.0.0
```

Initialize and push to a remote repository:

```powershell
powershell -NoProfile -File tools\git-init.ps1 `
  --path ..\example-app `
  --tag v1.0.0 `
  --remote https://github.com/example/example-app.git
```

Show version and help:

```powershell
powershell -NoProfile -File tools\git-init.ps1 --help
powershell -NoProfile -File tools\git-init.ps1 --version
```

### Options

- `-h`, `--help`: prints the version and usage information, then exits.
- `--version`: prints the script version, then exits.
- `-v`, `--verbose`: prints Git commands before running them.
- `-p PATH`, `--path PATH`: target repository root. This option is required.
  The path must be an existing non-empty directory.
- `-r URL`, `--remote URL`: optional remote URL. When provided, the script adds
  it as `origin` and runs `git push -u origin main --tags`.
- `-t TAG`, `--tag TAG`: annotated Git tag to create. Defaults to `v1.0.0`.
  The tag must be a SemVer tag prefixed with `v`.

### Exit Status

- `0`: help or version was shown, the user cancelled safely, or initialization
  completed successfully.
- Non-zero: an argument was invalid, the target directory was invalid, Git
  metadata was unreadable, the repository already had commits, the tag already
  existed, no committable files were found, Git failed, or another terminating
  PowerShell error occurred.

### Troubleshooting

When `git-init.ps1` comes from a downloaded GitHub release ZIP, PowerShell may
block it before the script starts. The error can be localized, but it usually
includes `PSSecurityException`, `UnauthorizedAccess`, and text similar to:

```text
.\git-init.ps1 : File C:\Path\To\Project\tools\git-init.ps1 cannot be loaded.
The file C:\Path\To\Project\tools\git-init.ps1 is not digitally signed. You
cannot run this script on the current system.
FullyQualifiedErrorId : UnauthorizedAccess
```

PowerShell is enforcing the current execution policy or the downloaded-file
mark on the extracted script. Inspect the active policies, then use a per-user
`RemoteSigned` policy and unblock the trusted script file:

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
Unblock-File -Path .\tools\git-init.ps1
powershell -NoProfile -File .\tools\git-init.ps1 `
  --path ..\example-app `
  --tag v1.0.0
```

Use the actual path where you extracted or copied `git-init.ps1`; for example,
replace `.\tools\git-init.ps1` with `.\scripts\git-init.ps1` if the script was
copied to `scripts`. Unblock only files from a trusted release package. If an
organization manages execution policy through `MachinePolicy` or `UserPolicy`,
follow that policy instead of bypassing it.

### Appendix

Review the file preview before confirming the commit. If risky paths are
reported, inspect them carefully and cancel unless they are intentional.

Use `--remote` only after checking that the target remote URL is correct. When
`--remote` is omitted, the initializer creates only local Git history.

Run from PowerShell when working primarily on Windows paths. Use
`git-init.sh` when a Bash environment is the better fit.

## git-init.sh

### Features

- Initializes an existing non-empty directory as a Git repository from Bash.
- Previews committable files before creating target Git metadata.
- Requires explicit confirmation before initialization and commit.
- Warns before committing risky credential, archive, cache, or runtime paths.
- Validates the exact initial message with Commitlint and the repository hook.
- Creates the first Conventional Commit on `main`.
- Creates an annotated SemVer tag and optionally pushes to `origin`.

### Synopsis

```text
usage: bash tools/git-init.sh [options]

options:
  -h, --help       show version and help
      --version    show version only
  -v, --verbose    show additional execution traces
  -p, --path PATH  target repository root, required
  -r, --remote URL optional origin remote URL
  -t, --tag TAG    SemVer Git tag, default: v1.0.0
```

### Description

`git-init.sh` is the Bash initializer for creating the first Git history in a
target project directory. It requires Bash 4 or newer, an existing non-empty
target directory, and readable `.git` metadata if `.git` already exists. The
target repository must not already have commits.

The script asks for confirmation, previews files Git can commit, asks for a
second confirmation, and warns on risky paths when needed. Before committing,
it writes the exact message to a temporary UTF-8 file, validates that file with
Commitlint, and forces the repository `commit-msg` hook. It verifies the
recorded message, removes the temporary file, renames the branch to `main`, and
creates an annotated tag. It pushes only when `--remote` is provided.

### Usage/Examples

Initialize a local target directory:

```bash
bash tools/git-init.sh --path ../example-app --tag v1.0.0
```

Initialize and push to a remote repository:

```bash
bash tools/git-init.sh \
  --path ../example-app \
  --tag v1.0.0 \
  --remote https://github.com/example/example-app.git
```

Show version and help:

```bash
bash tools/git-init.sh --help
bash tools/git-init.sh --version
```

### Options

- `-h`, `--help`: prints the version and usage information, then exits.
- `--version`: prints the script version, then exits.
- `-v`, `--verbose`: prints Git commands before running them.
- `-p PATH`, `--path PATH`: target repository root. This option is required.
  The path must be an existing non-empty directory.
- `-r URL`, `--remote URL`: optional remote URL. When provided, the script adds
  it as `origin` and runs `git push -u origin main --tags`.
- `-t TAG`, `--tag TAG`: annotated Git tag to create. Defaults to `v1.0.0`.
  The tag must be a SemVer tag prefixed with `v`.

### Exit Status

- `0`: help or version was shown, the user cancelled safely, or initialization
  completed successfully.
- `1`: an argument was invalid, the target directory was invalid, Git metadata
  was unreadable, the repository already had commits, the tag already existed,
  no committable files were found, Git failed, or another checked failure
  occurred.

### Appendix

Review the file preview before confirming the commit. If risky paths are
reported, inspect them carefully and cancel unless they are intentional.

Use `--remote` only after checking that the target remote URL is correct. When
`--remote` is omitted, the initializer creates only local Git history.

Run from Bash 4 or newer. On Windows, the PowerShell initializer may be easier
when the target path is a native Windows path.

## release-artifacts.py

### Features

- Generates root `VERSION`, `SHA256SUMS`, and `manifest.json` files for one
  exact SemVer release.
- Reads Git blobs from `HEAD`, the index, or a selected tree and excludes
  untracked, ignored, and absent files.
- Generates the manifest from `templates/release/manifest.template.json` and
  validates it against `templates/release/manifest.schema.json`.
- Requires release-specific business metadata from an external JSON file and
  never derives unknown values from repository content.

### Synopsis

```text
usage: python tools/release-artifacts.py [options] COMMAND
```

Install the pinned validator before using the tool:

```bash
python -m pip install \
  --requirement tools/release-artifacts-requirements.txt
```

The release workflow resolves provable values from explicit current input,
authoritative project sources, exact release facts, or a non-conflicting
previous manifest. It asks the user only for unresolved or contradictory values
and requires explicit validation.

### Usage/Examples

Preview artifact preparation with explicit metadata outside the repository:

```bash
python tools/release-artifacts.py --dry-run prepare \
  --release-ref v1.2.3 \
  --release-date 2026-08-18T12:00:00Z \
  --metadata-file /external/path/release-metadata.json
```

After the preview succeeds, generate the files with the same inputs and
`--force`, then validate the staged content:

```bash
python tools/release-artifacts.py check \
  --expected-ref v1.2.3 \
  --index
```

Use `--treeish v1.2.3` instead of `--index` to validate an immutable tag.
The inventory includes supported Git blobs and `VERSION`, but excludes the
self-referential `SHA256SUMS` and `manifest.json` outputs.

### Exit Status

- `0`: preparation or validation succeeded.
- `1`: metadata, schema, Git content, checksum, confirmation, or write
  validation failed.
- `2`: command-line parsing failed.

## repository-audit.sh

### Features

- Runs the shared local and CI repository audit suite.
- Defaults to the full audit profile.
- Supports an optional read-only profile and focused CI audit modes.
- Checks Markdown, spelling, whitespace, shell scripts, PowerShell parsing,
  YAML, workflow contracts, release artifacts, scanner behavior, SemVer
  pattern drift, and commit messages over the complete introduced-commit
  range.
- Parses every tracked or untracked non-ignored PowerShell file and runs the
  dependency-free backup and `Initialize-QmdCollection` test suites.
- Exercises the canonical valid and invalid commit-message fixtures and checks
  the strict Betterleaks and Gitleaks configurations.
- Bootstraps pinned tools and exercises mutating smoke cases only in full
  profiles.
- Uses WSL-aware temporary paths when Windows PowerShell is invoked from WSL.

### Synopsis

```text
usage: bash tools/repository-audit.sh [mode]

modes:
  all       run markdown, spelling, static, and smoke checks, default
  full      alias for all
  readonly  run non-mutating checks with installed tools
  markdown  run Markdown lint only
  spelling  run Codespell only
  static    run static checks and script smoke tests only
  -h        show help
  --help    show help
  help      show help
```

### Description

`repository-audit.sh` is the source of truth for repository validation. Its
default `all` mode and the explicit `full` alias run Markdown lint, spelling
checks, and static checks. The `static` mode includes Git whitespace checks,
Bash syntax checks, ShellCheck, PowerShell parsing, SemVer pattern drift
checks, QMD Manager and release-artifact tests, script smoke tests, Node syntax
checks, and Commitlint validation for every introduced commit. It also
verifies the release-driven workflow contracts, repository-audit aggregation,
secret scanner behavior, and canonical commit-message fixtures.

The optional `readonly` mode uses only installed tools, disables optional Git
locks, and does not install packages, access the network, modify tracked files,
or run mutating smoke tests. It may create and remove isolated temporary files
for PowerShell parsing and QMD Manager tests. GitHub Actions calls explicit
focused modes.

### Usage/Examples

Run the default full audit:

```bash
bash tools/repository-audit.sh
```

Run the optional read-only audit:

```bash
bash tools/repository-audit.sh readonly
```

Run only Markdown checks:

```bash
bash tools/repository-audit.sh markdown
```

Run only spelling checks:

```bash
bash tools/repository-audit.sh spelling
```

Run static checks and smoke tests:

```bash
bash tools/repository-audit.sh static
```

### Options

- `all`: runs Markdown, spelling, static, and smoke checks. This is the default
  when no mode is provided.
- `full`: alias for `all`.
- `readonly`: runs non-mutating checks with installed tools.
- `markdown`: runs `markdownlint-cli2` against repository Markdown files.
- `spelling`: runs Codespell with the repository configuration.
- `static`: runs Git whitespace checks, Bash and ShellCheck checks,
  complete PowerShell parsing, QMD Manager and release-artifact tests, SemVer
  drift checks, script smoke tests, Node syntax checks, workflow-contract
  checks, secret-scanner behavior checks, and complete-range Commitlint
  checks.
- `-h`, `--help`, `help`: prints usage information, then exits.

### Exit Status

- `0`: the selected audit mode passed, or help was shown.
- `1`: an unknown mode was provided, a required command was missing, a
  validation check failed, a smoke test failed, or a bootstrapped tool failed.

### Appendix

Run the audit profile required for the operation before creating a release tag
or GitHub release. Treat any failure as a blocker until the underlying
validation issue is understood and fixed.

The full audit needs local tools such as `git`, `bash`, `shellcheck`, a
PowerShell command, `python`, `node`, and `npx`. It also needs network access
to npm for Markdown lint bootstrapping and PyPI for Codespell and JSON Schema
validator bootstrapping.

Use focused modes while diagnosing failures. For example, `markdown` and
`spelling` isolate documentation issues, while `static` isolates script,
configuration, and smoke-test behavior.

On Windows, Codex may repeatedly create Git processes while a repository is
open, as tracked in
[openai/codex#26812](https://github.com/openai/codex/issues/26812). Treat this
as an external, mitigated defect: before write-sensitive Git operations,
inspect Git processes and lock files from a terminal outside Codex. If the
behavior recurs, close Codex normally. Never terminate a process or remove a
lock automatically; first confirm that it is orphaned and no active process
owns it.

## verify-repository-audit-runs.py

### Features

- Waits for the exact `push`-event Repository audit runs required for a release
  commit.
- Matches a numeric workflow ID, an exact 40-character SHA, one or more branch
  or tag refs, and an inclusive creation-time lower bound.
- Rejects failed, ambiguous, missing, or timed-out applicable runs.
- Ignores manual runs and unrelated workflows, refs, commits, or older runs.
- Supports a side-effect-free dry run and timestamped verbose polling.

### Synopsis

```text
usage: python tools/verify-repository-audit-runs.py [options]

options:
  -h, --help                  show help and exit
      --version               show version and exit
      --dry-run               show the verification plan without GitHub access
  -v, --verbose               show timestamped polling details
      --repository OWNER/REPO target GitHub repository, required
      --workflow-id ID        numeric Repository audit workflow ID, required
      --sha SHA               exact target commit SHA, required
      --ref REF               expected branch or tag, required and repeatable
      --created-after UTC     inclusive UTC lower bound, required
      --timeout-seconds N     maximum wait time, default: 600
      --poll-seconds N        polling interval, default: 5
```

### Description

`verify-repository-audit-runs.py` queries GitHub Actions through `gh api` for
`push` runs at one exact commit. It selects only runs from the specified
Repository audit workflow that match each required ref and were created at or
after the supplied UTC boundary. Every required ref must resolve to exactly one
completed successful run; a failed run or multiple matching runs stops the
verification immediately, while missing or pending runs are polled until the
timeout.

### Usage/Examples

Preview the verification without querying GitHub:

```bash
python tools/verify-repository-audit-runs.py \
  --dry-run \
  --repository example/example-app \
  --workflow-id 123456789 \
  --sha 0123456789abcdef0123456789abcdef01234567 \
  --ref main \
  --ref v1.2.3 \
  --created-after 2026-08-04T15:00:00Z
```

Wait for the required branch and tag runs:

```bash
python tools/verify-repository-audit-runs.py \
  --repository example/example-app \
  --workflow-id 123456789 \
  --sha 0123456789abcdef0123456789abcdef01234567 \
  --ref main \
  --ref v1.2.3 \
  --created-after 2026-08-04T15:00:00Z \
  --timeout-seconds 600 \
  --poll-seconds 5
```

### Options

- `-h`, `--help`: prints usage information, then exits.
- `--version`: prints script version `v1.0.0`, then exits.
- `--dry-run`: validates arguments and prints the read-only plan without
  querying GitHub.
- `-v`, `--verbose`: writes timestamped polling details to standard error.
- `--repository OWNER/REPO`: repository whose runs are inspected.
- `--workflow-id ID`: positive numeric Repository audit workflow identifier.
- `--sha SHA`: exact 40-character hexadecimal target commit SHA.
- `--ref REF`: expected branch or tag name. Repeat once for every required
  unique ref.
- `--created-after UTC`: inclusive lower bound in
  `YYYY-MM-DDTHH:MM:SSZ` format.
- `--timeout-seconds N`: non-negative maximum wait time. Defaults to `600`.
- `--poll-seconds N`: non-negative polling interval. Defaults to `5` and must
  be positive when the timeout is positive.

### Exit Status

- `0`: help or version was shown, the dry run completed, or every required run
  completed successfully.
- `1`: arguments were invalid, `gh` was unavailable, GitHub returned invalid
  data, an applicable run failed or was ambiguous, or the timeout expired.

### Appendix

Authenticate `gh` for the target repository before live verification. Use the
workflow's resolved numeric ID rather than its filename, and choose the
creation-time boundary from the publication process so an older run cannot
satisfy the check. A manual or scheduled success never substitutes for the
required `push` run.
