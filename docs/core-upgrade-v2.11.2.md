# Core upgrade to v2.11.2

## Scope

This migration updates `qmd-manager` from the published `git-starter-kit` v2.7.0
package to v2.11.2, commit `943ef42b8fd85a3a67a6b14eaba1de30b0707e12`.
The verified target archive SHA-256 is
`bb5563465f94b45d46790767fb7d57aa2a0bc9fd3614967991416c9602f28b83`.

The original starter source and agent rules v1.42.0 remain unchanged. Application
version, release tags, historical commits, existing branches, initialization-only
documents and legacy tests are preserved. The migration does not publish a
product release or authorize a PR merge.

## Preserved behavior

- Keep existing Conventional Commit scopes and the deployment release format.
- Keep agent-rule sync, guarded merge and release preflight enabled, matching
  legacy defaults; their existing external prerequisites still apply.
- Run the complete Python suite, commit-message tests, project Markdown,
  spelling, PowerShell parsing and shell-test lint on both supported platforms.
- Install each CI job's own locked dependencies; jobs do not share installations.
- Prefer modern PowerShell on Windows and run both QMD initialization and
  backup suites on Linux and Windows. Backup tests require PowerShell 7.4+.
  The backup fixture selects the first Node executable when several are on PATH.

Core checks and application checks have separate responsibilities. `full`, `fast`
and `powershell-static` validate distributed core ownership. The project runner
executes the checks in `.starter-kit-project.json`; an application failure fails
the aggregate `Repository audit` check.

## Reviewed deviations

The official upgrade plan reported local conflicts. The migration used the
official inventory and reviewed resolutions; it did not force the toolkit to
overwrite conflicting files.

The [machine-readable record](core-upgrade-v2.11.2.json) stores official and local
canonical hashes for each adaptation. `acceptedFiles` in the adoption record
contains only merge-strategy files. Modified replace-strategy files remain visible
as toolkit drift. This repository must not be described as an exact copy of the
upstream package or as fully toolkit-compliant.

| Path | Reason |
| --- | --- |
| `.betterleaks.toml` | Preserve the project's existing scanner rules. |
| `.codespellrc` | Preserve project spelling vocabulary and exclusions. |
| `.github/workflows/repository-audit.yml` | Install each project job's locked dependencies and shell linters, including the Windows core job's required shell tools. |
| `.gitignore` | Keep verified Python caches and project-generated exports ignored. |
| `.gitleaks.toml` | Preserve the project's existing scanner rules. |
| `commitlint.config.cjs` | Preserve the existing accepted commit scopes. |
| `tools/project_validation.py` | Honor PATH when selecting a bare executable; Windows otherwise chooses system WSL and bypasses selected Python environments. |
| `tools/quality/package-lock.json` | Lock the same minimal smol-toml security correction with its registry integrity digest. |
| `tools/quality/package.json` | Override vulnerable smol-toml 1.7.0 with patched 1.7.1 without changing direct quality-tool versions. |
| `tools/repository-audit/common.sh` | Resolve the audit root without inherited Git-directory overrides and preserve the project's PowerShell precedence. |

The TOML override addresses
[GHSA-7w5x-hrqm-74c2](https://github.com/advisories/GHSA-7w5x-hrqm-74c2).
The regression test requires malformed TOML to fail within a deadline rather than
hang. Direct quality-tool versions remain those of v2.11.2.

Bare project-check executables now resolve through `PATH` before process creation.
This prevents Windows from choosing its system WSL launcher over Git Bash or the
parent Python installation over the selected environment. Explicit relative
executable paths retain their original meaning.

Commit test fixtures now copy the modular audit dispatcher and use locked
Commitlint. Tests of the removed `npx` resolver were retired; message and range
assertions remain.

The root resolver ignores inherited Git directory overrides only while locating
the repository from the audit script. This preserves commit-message validation
when Git invokes the hook from a linked worktree. The regression test requires
a valid message to pass and an invalid message to be rejected by Commitlint.

## Verification

The maintenance toolchain uses Python 3.11 on Linux and Python 3.14 on Windows,
Node compatible with `tools/quality/package.json`, and the locked dependencies
and verified external tools declared under `tools/quality/`.

After installing that toolchain, run from the repository root:

```bash
bash tools/repository-audit.sh full
bash tools/repository-audit.sh fast
bash tools/repository-audit.sh powershell-static
python -B tools/project_validation.py --repository-root . --timeout 900
```

On Windows, use Git Bash and put the selected Python environment on `PATH`.
The pre-push hook validates the pushed commit in an isolated snapshot and exposes
the caller's locked Node tools to that snapshot. Project checks must work without
a second `node_modules` installation in the snapshot.

Before integration, require successful Linux and Windows CI at the exact PR head,
review the full diff and verify preservation evidence. Local `full` alone does
not prove that application checks ran, because it prints their read-only plan.

## Preservation and rollback

Before migration, complete backups and all-ref bundles were restored and compared,
including ignored files, empty directories and Git references. Work was isolated
from the original checkouts. Existing ignored paths remain ignored.

No obsolete package path was deleted. In particular, the old repository migration
document, templates and inherited tests remain available for project review.
Future upgrades must re-evaluate the local adaptations above.

Before integration, keep the original checkout and backups intact while reviewing
the PR. After integration, prepare and review an inverse commit if rollback is
needed; resolve later changes explicitly. Do not use reset, clean, force push or
branch deletion as a rollback shortcut.
