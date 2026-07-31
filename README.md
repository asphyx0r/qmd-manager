# QMD Manager

QMD Manager provides a Windows-focused PowerShell workflow for preparing QMD
and creating a Markdown knowledge collection with scoped vector embeddings.

## Features

- Validates the supported Windows and PowerShell environment.
- Detects local Node.js, npm, and QMD installations.
- Installs or updates Node.js through WinGet when online management is
  available.
- Keeps npm within a tested version range and installs a fixed bootstrap
  version only when required.
- Requires and installs exactly `@tobilu/qmd` 2.5.3 with strict lifecycle
  script approval.
- Creates a QMD collection for the `**/*.md` files under a selected directory.
- Adds a root context to the collection.
- Generates embeddings only for the new collection.
- Provides PowerShell-native and GNU-compatible parameters, previews, and
  verbose diagnostics.

## Requirements

- Windows 11 client edition.
- PowerShell 7.x Core.
- An existing readable directory containing at least one `*.md` file.
- Node.js 22.22.2 or later.
- npm 11.16.0 or later and earlier than 13.0.0.
- `@tobilu/qmd` 2.5.3.
- WinGet when the online Node.js installation or update policy is applied.

Network access is checked separately for WinGet and Node.js downloads, the npm
registry, and Hugging Face model access. When installation endpoints are
unavailable, the workflow can continue only with npm in the supported range
and an exact, functional npm-global QMD 2.5.3 installation. Embedding is still
attempted when Hugging Face is unavailable because the required model may
already be cached.

## Usage

Run the script from the repository root:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\Initialize-QmdCollection.ps1 `
  --path 'C:\Knowledge\Runbooks' `
  --name 'runbooks' `
  --context 'Operational runbooks and troubleshooting procedures.'
```

The collection path must already exist, be readable, and contain a Markdown
file at its root or below it. The collection name must match
`^[A-Za-z0-9_-]+$`, and the context must be non-empty. Input validation
finishes before platform, network, installation, or QMD operations begin.

Available options:

- `-Path`, `-p`, `--path <COLLECTION-PATH>`: directory containing Markdown
  files.
- `-Name`, `-n`, `--name <COLLECTION-NAME>`: valid QMD collection name.
- `-Context`, `-c`, `--context <COLLECTION-DESCRIPTION>`: root context.
- `-DryRun`, `--dry-run`, `-WhatIf`: evaluate the workflow without
  installations, updates, or QMD mutations.
- `-Verbose`, `-v`, `--verbose`: enable debug logs.
- `-Confirm`: request one confirmation before any mutation.
- `-Help`, `-h`, `--help`: display command usage.
- `-Version`, `--version`: display the script version.

Display help or the current version:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\Initialize-QmdCollection.ps1 --help
pwsh -NoLogo -NoProfile -File .\scripts\Initialize-QmdCollection.ps1 --version
Get-Help .\scripts\Initialize-QmdCollection.ps1 -Full
```

Preview a run without changing the system or QMD data:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\Initialize-QmdCollection.ps1 `
  --dry-run `
  --path 'C:\Knowledge\Runbooks' `
  --name 'runbooks' `
  --context 'Operational runbooks and troubleshooting procedures.'
```

The equivalent PowerShell-native preview uses `-WhatIf`:

```powershell
.\scripts\Initialize-QmdCollection.ps1 -WhatIf `
  -Path 'C:\Knowledge\Runbooks' `
  -Name 'runbooks' `
  -Context 'Operational runbooks and troubleshooting procedures.'
```

## Workflow

For a real run, the script:

1. Validates required arguments, the collection name, and Markdown content.
2. Validates Windows 11 and PowerShell 7.
3. Detects local WinGet, Node.js, npm, and QMD state.
4. Checks the network services used for installation and embeddings.
5. Builds one management plan shared by preview and real execution.
6. Applies the Node.js policy and then re-detects npm before evaluating it.
7. Keeps supported npm or installs exactly npm 11.17.0.
8. Keeps or installs exactly QMD 2.5.3 with strict script approval.
9. Creates the collection and context, then generates scoped embeddings.

The script returns exit code `0` for successful execution, help, or version
output. It returns exit code `1` for invalid arguments, unsupported
environments, unavailable prerequisites, or failed QMD operations.

## Failure handling

The workflow does not replace an existing collection and does not roll back
completed QMD operations. If context creation or embedding fails, the
collection or its text index may remain in place. Review the reported partial
state before retrying.

Dry-run and `-WhatIf` modes perform input, platform, local prerequisite, and
network checks, then render the same management policy used by a real run.
They do not install or update software and do not modify QMD data. When
Node.js would change, the preview reports that npm and QMD will be re-detected
instead of predicting their actions from stale state.

## Repository maintenance

This project retains the repository audit, Git initialization helpers, hooks,
templates, coding-agent rules, and release packaging support from the Git
starter kit.

After Git metadata has been created, run the read-only audit with installed
tools:

```bash
bash tools/repository-audit.sh readonly
```

The full audit may install temporary validation dependencies, access external
services, and create disposable smoke-test repositories:

```bash
bash tools/repository-audit.sh full
```

Run the dependency-free QMD Manager tests directly with:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\Initialize-QmdCollection.Tests.ps1
```

See [Tools](tools/README.md) for repository-management commands,
[Repository files](docs/repository-files.md) for the maintained inventory, and
[Repository skills](docs/SKILLS.md) for the checked-in Codex workflow.
The source versions of the imported starter kit and coding-agent rules are
recorded in `_agent-rules-source.json`.

The repository-owned `Agent rules update` workflow proposes updates directly
from `agent-coding-rules` while preserving customized rule files. Set the
Actions variable `AGENT_RULES_SYNC_ENABLED=false` to suspend synchronization.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing changes. Keep the
documentation, tests, and repository file inventory aligned with behavior.

## License

[MIT](LICENSE)
