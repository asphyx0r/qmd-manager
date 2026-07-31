#!/usr/bin/env bash
set -euo pipefail

mode="${1:-all}"

if [ "$mode" = "readonly" ]; then
  export GIT_OPTIONAL_LOCKS=0
fi

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

audit_temp=""
audit_temp_parent=""
audit_temp_parent_created="false"

cleanup() {
  if [ -n "$audit_temp" ] && [ -n "$audit_temp_parent" ]; then
    case "$audit_temp" in
      "$audit_temp_parent"/repository-audit.*)
        if [ -d "$audit_temp" ]; then
          rm -rf -- "$audit_temp"
        fi
        ;;
      *)
        echo "Refusing to remove unexpected audit path: $audit_temp" >&2
        return 1
        ;;
    esac
  fi

  if [ "$audit_temp_parent_created" = "true" ] &&
    [ -n "$audit_temp_parent" ] &&
    [ -d "$audit_temp_parent" ]; then
    rmdir "$audit_temp_parent" 2>/dev/null || true
  fi
}

usage() {
  cat <<'USAGE'
Usage: bash tools/repository-audit.sh [all|full|readonly|markdown|spelling|static]

Runs the same repository audit rules locally and in GitHub Actions.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

resolve_command() {
  local candidate
  for candidate in "$@"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  echo "Required command not found. Tried: $*" >&2
  exit 1
}

resolve_powershell_command() {
  if [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] &&
    command -v powershell.exe >/dev/null 2>&1; then
    command -v powershell.exe
    return 0
  fi

  case "$(uname -s 2>/dev/null || true)" in
    CYGWIN*|MINGW*|MSYS*)
      resolve_command pwsh.exe pwsh powershell.exe
      return
      ;;
  esac

  resolve_command pwsh pwsh.exe powershell.exe
}

ensure_audit_temp() {
  if [ -n "$audit_temp" ]; then
    return
  fi

  if [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] &&
    command -v powershell.exe >/dev/null 2>&1; then
    audit_temp_parent="$repository_root/.tmp"
    if [ ! -d "$audit_temp_parent" ]; then
      mkdir -p "$audit_temp_parent"
      audit_temp_parent_created="true"
    fi

    audit_temp="$(mktemp -d "$audit_temp_parent/repository-audit.XXXXXX")"
    trap cleanup EXIT
    return
  fi

  audit_temp_parent="${TMPDIR:-/tmp}"
  audit_temp_parent="${audit_temp_parent%/}"
  audit_temp="$(mktemp -d "$audit_temp_parent/repository-audit.XXXXXX")"
  trap cleanup EXIT
}

to_pwsh_path() {
  case "$(uname -s 2>/dev/null || true)" in
    CYGWIN*|MINGW*|MSYS*)
      cygpath -w "$1"
      ;;
    *)
      if [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] &&
        command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
        return
      fi

      printf '%s\n' "$1"
      ;;
  esac
}

check_git_whitespace() {
  local zero_sha="0000000000000000000000000000000000000000"

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    git diff --check "origin/$GITHUB_BASE_REF...HEAD"
  elif [ -n "${BEFORE_SHA:-}" ]; then
    if [ "$BEFORE_SHA" != "$zero_sha" ]; then
      git diff --check "$BEFORE_SHA..HEAD"
    else
      git diff-tree --check --root --no-commit-id -r HEAD
    fi
  else
    git diff --check
    git diff --cached --check
    git diff-tree --check --root --no-commit-id -r HEAD
  fi
}
check_semver_pattern_drift() {
  local node_cmd="$1"

  "$node_cmd" <<'JS'
const fs = require("fs");

function readFile(path) {
  return fs.readFileSync(path, "utf8").replace(/\r/g, "");
}

function extractSingle(path, pattern, label) {
  const match = readFile(path).match(pattern);
  if (!match) {
    throw new Error("Unable to extract " + label + ".");
  }

  return match[1];
}

function extractWorkflowPattern() {
  const parts = [];
  const expression = /^\s*semver_tag_pattern\+?='([^']+)'/gm;
  const content = readFile(".github/workflows/release-package.yml");
  let match = expression.exec(content);
  while (match) {
    parts.push(match[1]);
    match = expression.exec(content);
  }

  if (parts.length === 0) {
    throw new Error("Unable to extract release workflow SemVer pattern.");
  }

  return parts.join("");
}

function extractPythonPattern() {
  const content = readFile("tools/backup-target-directory.py");
  const block = content.match(
    /^SEMVER_TAG_PATTERN = re\.compile\(\n([\s\S]*?)^\)$/m
  );
  if (!block) {
    throw new Error("Unable to extract Python backup SemVer pattern.");
  }

  const parts = [];
  const expression = /^\s*r"([^"]*)"$/gm;
  let match = expression.exec(block[1]);
  while (match) {
    parts.push(match[1]);
    match = expression.exec(block[1]);
  }

  if (parts.length === 0) {
    throw new Error("Unable to extract Python backup SemVer fragments.");
  }

  return parts.join("");
}

const patterns = new Map([
  [
    "tools/git-init.sh",
    extractSingle(
      "tools/git-init.sh",
      /^semver_tag_pattern='([^']+)'$/m,
      "Bash init SemVer pattern"
    ),
  ],
  [
    "tools/git-init.ps1",
    extractSingle(
      "tools/git-init.ps1",
      /^\$SemVerTagPattern = "([^"]+)"$/m,
      "PowerShell init SemVer pattern"
    ),
  ],
  [
    "tools/build-release-package.ps1",
    extractSingle(
      "tools/build-release-package.ps1",
      /^\$SemVerTagPattern = "([^"]+)"$/m,
      "release package SemVer pattern"
    ),
  ],
  ["tools/backup-target-directory.py", extractPythonPattern()],
  [".github/workflows/release-package.yml", extractWorkflowPattern()],
]);

const expected = patterns.values().next().value;
for (const [source, pattern] of patterns) {
  if (pattern !== expected) {
    console.error("SemVer validation pattern drift in " + source + ".");
    process.exit(1);
  }
}
JS
}

check_release_package_portability() {
  # shellcheck disable=SC2016
  if grep -F \
    'toolkit_path="$RUNNER_TEMP/git-starter-kit-' \
    .github/workflows/release-package.yml >/dev/null; then
    echo "Release workflow hard-codes the starter-kit toolkit name." >&2
    exit 1
  fi

  # shellcheck disable=SC2016
  if ! grep -F \
    'repository_name="${GITHUB_REPOSITORY##*/}"' \
    .github/workflows/release-package.yml >/dev/null; then
    echo "Release workflow does not derive the packaged repository name." >&2
    exit 1
  fi
}

run_commitlint() {
  require_command npx

  local zero_sha="0000000000000000000000000000000000000000"
  local from_ref=""
  local commit_count

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    from_ref="origin/$GITHUB_BASE_REF"
  elif [ -n "${BEFORE_SHA:-}" ] && [ "$BEFORE_SHA" != "$zero_sha" ]; then
    from_ref="$BEFORE_SHA"
  elif git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    from_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  fi

  if [ -n "$from_ref" ]; then
    commit_count="$(git rev-list --count "$from_ref..HEAD")"
    if [ "$commit_count" -eq 0 ]; then
      return
    fi

    NPM_CONFIG_IGNORE_SCRIPTS=true npx --yes @commitlint/cli@21.0.2 \
      --config commitlint.config.cjs \
      --from "$from_ref" \
      --to HEAD
  else
    git log -1 --format=%B HEAD | NPM_CONFIG_IGNORE_SCRIPTS=true \
      npx --yes @commitlint/cli@21.0.2 --config commitlint.config.cjs
  fi
}

run_markdown() {
  require_command npx
  NPM_CONFIG_IGNORE_SCRIPTS=true npx --yes markdownlint-cli2@0.22.1 "**/*.md"
}

run_spelling() {
  local python_cmd
  ensure_audit_temp

  python_cmd="$(resolve_command python python3 python.exe)"

  local codespell_target="$audit_temp/codespell-target"

  "$python_cmd" -m pip install \
    --disable-pip-version-check \
    --no-input \
    --target "$codespell_target" \
    codespell==2.4.2

  local codespell_cmd="$codespell_target/bin/codespell"
  if [ ! -x "$codespell_cmd" ] && [ -x "$codespell_target/Scripts/codespell.exe" ]; then
    codespell_cmd="$codespell_target/Scripts/codespell.exe"
  fi

  PYTHONPATH="$codespell_target" "$codespell_cmd" .
}

run_powershell_parse() {
  local pwsh_cmd
  pwsh_cmd="$(resolve_powershell_command)"
  ensure_audit_temp

  local parse_script="$audit_temp/powershell-parse.ps1"
  cat > "$parse_script" <<'PS'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

$ErrorActionPreference = "Stop"
$errors = @()
foreach ($path in $Paths) {
    $tokens = $null
    $parseErrors = $null
    $source = Get-Content -LiteralPath $path -Raw
    [System.Management.Automation.Language.Parser]::ParseInput(
        $source,
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $errors += $parseErrors
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}
PS

  local powershell_path
  local -a powershell_paths=()
  while IFS= read -r powershell_path; do
    powershell_paths+=(
      "$(to_pwsh_path "$repository_root/$powershell_path")"
    )
  done < <(git ls-files --cached --others --exclude-standard '*.ps1')

  "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File \
    "$(to_pwsh_path "$parse_script")" \
    "${powershell_paths[@]}"
}

run_powershell_parse_readonly() {
  run_powershell_parse
}

run_qmd_script_tests() {
  local pwsh_cmd
  local test_name
  local test_path
  pwsh_cmd="$(resolve_powershell_command)"

  for test_name in \
    Initialize-QmdCollection.Tests.ps1 \
    Invoke-QmdBackup.Tests.ps1; do
    test_path="$(to_pwsh_path "$repository_root/tests/$test_name")"
    "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$test_path"
  done
}

run_commitlint_readonly() {
  local commitlint_cmd="$1"

  local zero_sha="0000000000000000000000000000000000000000"
  local from_ref=""
  local commit_count

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] &&
    [ -n "${GITHUB_BASE_REF:-}" ]; then
    from_ref="origin/$GITHUB_BASE_REF"
  elif [ -n "${BEFORE_SHA:-}" ] && [ "$BEFORE_SHA" != "$zero_sha" ]; then
    from_ref="$BEFORE_SHA"
  elif git rev-parse --abbrev-ref --symbolic-full-name \
    '@{upstream}' >/dev/null 2>&1; then
    from_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  fi

  if [ -n "$from_ref" ]; then
    commit_count="$(git rev-list --count "$from_ref..HEAD")"
    if [ "$commit_count" -eq 0 ]; then
      return
    fi

    "$commitlint_cmd" \
      --config commitlint.config.cjs \
      --from "$from_ref" \
      --to HEAD
  else
    git log -1 --format=%B HEAD |
      "$commitlint_cmd" --config commitlint.config.cjs
  fi
}

run_script_smoke() {
  require_command bash
  require_command git
  local python_cmd
  local pwsh_cmd
  python_cmd="$(resolve_command python python3 python.exe)"
  pwsh_cmd="$(resolve_powershell_command)"

  ensure_audit_temp

  "$python_cmd" -B -m unittest discover \
    -s tests \
    -p "test_*.py"

  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Codex}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-codex@example.com}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Codex}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-codex@example.com}"

  local complex_semver_tag="v1.0.0-rc.1+build.1"
  local git_init_ps1
  local build_release_package_ps1
  git_init_ps1="$(to_pwsh_path "$repository_root/tools/git-init.ps1")"
  build_release_package_ps1="$(to_pwsh_path "$repository_root/tools/build-release-package.ps1")"

  bash tools/git-init.sh --help
  if bash tools/git-init.sh --path "$audit_temp" --tag invalid; then
    echo "Bash init accepted an invalid tag." >&2
    exit 1
  fi

  local bash_invalid_git_target="$audit_temp/git-init-bash-invalid-git"
  local bash_invalid_git_output="$audit_temp/git-init-bash-invalid-git.out"
  mkdir -p "$bash_invalid_git_target/.git"
  printf 'hello\n' > "$bash_invalid_git_target/README.md"
  if printf 'y\n' | bash tools/git-init.sh \
    --verbose \
    --path "$bash_invalid_git_target" \
    --tag v1.0.0 >"$bash_invalid_git_output" 2>&1; then
    echo "Bash init accepted invalid .git metadata." >&2
    exit 1
  fi
  if ! grep -F "Target contains .git metadata" "$bash_invalid_git_output" >/dev/null; then
    echo "Bash init did not explain invalid .git metadata." >&2
    exit 1
  fi
  if ! grep -F "git -C $bash_invalid_git_target rev-parse --show-toplevel" \
    "$bash_invalid_git_output" >/dev/null; then
    echo "Bash verbose init did not display the metadata validation command." >&2
    exit 1
  fi

  local bash_cancel_target="$audit_temp/git-init-bash-cancel"
  mkdir -p "$bash_cancel_target"
  printf 'hello\n' > "$bash_cancel_target/README.md"
  printf 'y\nn\n' | bash tools/git-init.sh \
    --path "$bash_cancel_target" \
    --tag v1.0.0
  if [ -e "$bash_cancel_target/.git" ]; then
    echo "Bash init created .git before commit confirmation." >&2
    exit 1
  fi

  local bash_verbose_preview_target="$audit_temp/git-init-bash-verbose-preview"
  local bash_verbose_preview_output="$audit_temp/git-init-bash-verbose-preview.out"
  local bash_verbose_risky_output
  local bash_verbose_risky_count
  mkdir -p "$bash_verbose_preview_target/templates"
  printf 'hello\n' >"$bash_verbose_preview_target/README.md"
  printf 'PLACEHOLDER=value\n' >"$bash_verbose_preview_target/templates/.env.template"
  printf 'y\ny\nn\n' | bash tools/git-init.sh \
    --verbose \
    --path "$bash_verbose_preview_target" \
    --tag v1.0.0 >"$bash_verbose_preview_output" 2>&1
  if [ -e "$bash_verbose_preview_target/.git" ]; then
    echo "Bash verbose init created .git before risky-path confirmation." >&2
    exit 1
  fi
  if ! grep -F "git init --bare " "$bash_verbose_preview_output" >/dev/null ||
    ! grep -F "git --git-dir=" "$bash_verbose_preview_output" >/dev/null; then
    echo "Bash verbose init did not display the preview Git traces." >&2
    exit 1
  fi
  if ! grep -F "  README.md" "$bash_verbose_preview_output" >/dev/null ||
    ! grep -F "  templates/.env.template" "$bash_verbose_preview_output" >/dev/null; then
    echo "Bash verbose init did not preview the expected files." >&2
    exit 1
  fi
  if grep -F -- "--untracked-files=all?? " "$bash_verbose_preview_output" >/dev/null; then
    echo "Bash verbose init mixed the Git trace with a status entry." >&2
    exit 1
  fi
  bash_verbose_risky_output="$(
    sed -n '/^Risky paths detected:/,/^Continue with risky paths?/p' \
      "$bash_verbose_preview_output"
  )"
  bash_verbose_risky_count="$(
    printf '%s\n' "$bash_verbose_risky_output" |
      awk '/^  / { count++ } END { print count + 0 }'
  )"
  if ((bash_verbose_risky_count != 1)) ||
    [[ "$bash_verbose_risky_output" != *"  templates/.env.template"* ]]; then
    echo "Bash verbose init reported unexpected risky paths." >&2
    exit 1
  fi
  if [[ "$bash_verbose_risky_output" == *"--git-dir="* ]]; then
    echo "Bash verbose init reported the Git trace as a risky path." >&2
    exit 1
  fi

  local bash_target="$audit_temp/git-init-bash-smoke"
  local bash_output="$audit_temp/git-init-bash-smoke.out"
  local expected_bash_trace
  mkdir -p "$bash_target"
  printf 'hello\n' >"$bash_target/README.md"
  printf 'hello spaces\n' >"$bash_target/notes with spaces.txt"
  printf 'y\ny\n' | bash tools/git-init.sh \
    --verbose \
    --path "$bash_target" \
    --tag v1.0.0 >"$bash_output" 2>&1
  if [ -n "$(git -C "$bash_target" status --short)" ]; then
    echo "Bash init smoke repository is not clean." >&2
    exit 1
  fi
  for expected_bash_trace in \
    "git init $bash_target" \
    "git -C $bash_target add --all" \
    "git -C $bash_target commit -m chore: initialize repository" \
    "git -C $bash_target branch -M main" \
    "git -C $bash_target tag -a v1.0.0 -m Initial version/First commit"; do
    if ! grep -F "$expected_bash_trace" "$bash_output" >/dev/null; then
      echo "Bash verbose init did not display every Git command." >&2
      exit 1
    fi
  done

  local bash_semver_target="$audit_temp/git-init-bash-semver-smoke"
  mkdir -p "$bash_semver_target"
  printf 'hello\n' > "$bash_semver_target/README.md"
  printf 'y\ny\n' | bash tools/git-init.sh \
    --path "$bash_semver_target" \
    --tag "$complex_semver_tag"
  if [ -n "$(git -C "$bash_semver_target" status --short)" ]; then
    echo "Bash init SemVer smoke repository is not clean." >&2
    exit 1
  fi

  "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" --help
  if "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --path "$(to_pwsh_path "$audit_temp")" \
    --tag invalid; then
    echo "PowerShell init accepted an invalid tag." >&2
    exit 1
  fi

  local pwsh_invalid_git_target="$audit_temp/git-init-pwsh-invalid-git"
  local pwsh_invalid_git_output="$audit_temp/git-init-pwsh-invalid-git.out"
  mkdir -p "$pwsh_invalid_git_target/.git"
  printf 'hello\n' > "$pwsh_invalid_git_target/README.md"
  if printf 'y\n' | "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --path "$(to_pwsh_path "$pwsh_invalid_git_target")" \
    --tag v1.0.0 >"$pwsh_invalid_git_output" 2>&1; then
    echo "PowerShell init accepted invalid .git metadata." >&2
    exit 1
  fi
  if ! grep -F "Target contains .git metadata" "$pwsh_invalid_git_output" >/dev/null; then
    echo "PowerShell init did not explain invalid .git metadata." >&2
    exit 1
  fi

  local pwsh_cancel_target="$audit_temp/git-init-pwsh-cancel"
  mkdir -p "$pwsh_cancel_target"
  printf 'hello\n' > "$pwsh_cancel_target/README.md"
  printf 'y\nn\n' | "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --path "$(to_pwsh_path "$pwsh_cancel_target")" \
    --tag v1.0.0
  if [ -e "$pwsh_cancel_target/.git" ]; then
    echo "PowerShell init created .git before commit confirmation." >&2
    exit 1
  fi

  local pwsh_verbose_target="$audit_temp/git-init-pwsh-verbose"
  local pwsh_verbose_output="$audit_temp/git-init-pwsh-verbose.out"
  local pwsh_verbose_risky_output
  local pwsh_verbose_risky_count
  mkdir -p "$pwsh_verbose_target/templates"
  printf 'hello\n' >"$pwsh_verbose_target/README.md"
  printf 'PLACEHOLDER=value\n' >"$pwsh_verbose_target/templates/.env.template"
  printf 'y\ny\nn\n' | "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --verbose \
    --path "$(to_pwsh_path "$pwsh_verbose_target")" \
    --tag v1.0.0 >"$pwsh_verbose_output" 2>&1
  if [ -e "$pwsh_verbose_target/.git" ]; then
    echo "PowerShell verbose init created .git before risky-path confirmation." >&2
    exit 1
  fi
  if ! grep -F "git --git-dir=" "$pwsh_verbose_output" >/dev/null; then
    echo "PowerShell verbose init did not display the Git status trace." >&2
    exit 1
  fi
  if ! grep -F "  README.md" "$pwsh_verbose_output" >/dev/null ||
    ! grep -F "  templates/.env.template" "$pwsh_verbose_output" >/dev/null; then
    echo "PowerShell verbose init did not preview the expected files." >&2
    exit 1
  fi
  if grep -F -- "--untracked-files=all?? " "$pwsh_verbose_output" >/dev/null; then
    echo "PowerShell verbose init mixed the Git trace with a status entry." >&2
    exit 1
  fi
  pwsh_verbose_risky_output="$(
    sed -n '/^Risky paths detected:/,/^Continue with risky paths?/p' \
      "$pwsh_verbose_output"
  )"
  pwsh_verbose_risky_count="$(
    printf '%s\n' "$pwsh_verbose_risky_output" |
      awk '/^  / { count++ } END { print count + 0 }'
  )"
  if ((pwsh_verbose_risky_count != 1)) ||
    [[ "$pwsh_verbose_risky_output" != *"  templates/.env.template"* ]]; then
    echo "PowerShell verbose init reported unexpected risky paths." >&2
    exit 1
  fi
  if [[ "$pwsh_verbose_risky_output" == *"--git-dir="* ]]; then
    echo "PowerShell verbose init reported the Git trace as a risky path." >&2
    exit 1
  fi

  local pwsh_target="$audit_temp/git-init-pwsh-smoke"
  mkdir -p "$pwsh_target"
  printf 'hello\n' > "$pwsh_target/README.md"
  printf 'hello spaces\n' > "$pwsh_target/notes with spaces.txt"
  printf 'y\ny\n' | "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --path "$(to_pwsh_path "$pwsh_target")" \
    --tag v1.0.0
  if [ -n "$(git -C "$pwsh_target" status --short)" ]; then
    echo "PowerShell init smoke repository is not clean." >&2
    exit 1
  fi

  local pwsh_semver_target="$audit_temp/git-init-pwsh-semver-smoke"
  mkdir -p "$pwsh_semver_target"
  printf 'hello\n' > "$pwsh_semver_target/README.md"
  printf 'y\ny\n' | "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$git_init_ps1" \
    --path "$(to_pwsh_path "$pwsh_semver_target")" \
    --tag "$complex_semver_tag"
  if [ -n "$(git -C "$pwsh_semver_target" status --short)" ]; then
    echo "PowerShell init SemVer smoke repository is not clean." >&2
    exit 1
  fi

  local release_output="$audit_temp/release-package-smoke"
  local latest_package="$release_output/latest-release-package.zip"
  "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$build_release_package_ps1" \
    -RepositoryRef local-test \
    -AgentRulesRef latest \
    -OutputDirectory "$(to_pwsh_path "$release_output")" \
    -PackageName latest-release-package.zip

  local manifest_ref
  manifest_ref="$(
    "$python_cmd" - "$latest_package" <<'PY'
import json
import sys
import zipfile

archive = zipfile.ZipFile(sys.argv[1])
manifest = json.load(archive.open("_agent-rules-source.json"))
print(manifest["agentRules"]["ref"])
PY
  )"

  local manifest_requested_ref
  manifest_requested_ref="$(
    "$python_cmd" - "$latest_package" <<'PY'
import json
import sys
import zipfile

archive = zipfile.ZipFile(sys.argv[1])
manifest = json.load(archive.open("_agent-rules-source.json"))
print(manifest["agentRules"]["requestedRef"])
PY
  )"

  if [ "$manifest_requested_ref" != "latest" ]; then
    echo "Release package did not record requested latest ref." >&2
    exit 1
  fi

  local semver_ref_pattern='^v(0|[1-9][0-9]*)\.'
  semver_ref_pattern+='(0|[1-9][0-9]*)\.'
  semver_ref_pattern+='(0|[1-9][0-9]*)'
  if ! [[ "$manifest_ref" =~ $semver_ref_pattern ]]; then
    echo "Release package latest did not resolve to a SemVer tag." >&2
    exit 1
  fi

  "$python_cmd" - "$latest_package" <<'PY'
import hashlib
import json
import sys
import zipfile

def canonical_digest(content):
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return "binary", hashlib.sha256(content).hexdigest()
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    canonical = (normalized.rstrip("\n") + "\n").encode("utf-8") if normalized else b""
    return "text", hashlib.sha256(canonical).hexdigest()

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = {name for name in archive.namelist() if not name.endswith("/")}
    source = json.load(archive.open("_agent-rules-source.json"))
    files = json.load(archive.open("_starter-kit-files.json"))
    if source["schemaVersion"] != 2:
        raise SystemExit("Unexpected release provenance schema.")
    if source["repository"]["name"] != "qmd-manager":
        raise SystemExit("Unexpected packaged repository name.")
    if files["schemaVersion"] != 2:
        raise SystemExit("Unexpected managed-file schema.")
    listed = set()
    strategies = {}
    for entry in files["files"]:
        path = entry["path"]
        listed.add(path)
        strategies[path] = entry["strategy"]
        if path not in names:
            raise SystemExit(f"Managed file missing from ZIP: {path}")
        digest = hashlib.sha256(archive.read(path)).hexdigest()
        if digest != entry["sha256"]:
            raise SystemExit(f"Managed file digest mismatch: {path}")
        kind, canonical = canonical_digest(archive.read(path))
        if kind != entry["contentKind"] or canonical != entry["canonicalSha256"]:
            raise SystemExit(f"Managed file canonical digest mismatch: {path}")
        if entry["strategy"] not in {
            "agent-rules", "initialize-only", "merge", "replace"
        }:
            raise SystemExit(f"Unexpected upgrade strategy: {path}")
    names.remove("_starter-kit-files.json")
    if names != listed:
        missing = ", ".join(sorted(names - listed))
        unexpected = ", ".join(sorted(listed - names))
        raise SystemExit(
            "Managed-file coverage mismatch. "
            f"Missing: {missing or '(none)'}. "
            f"Unexpected: {unexpected or '(none)'}."
        )
    expected_strategies = {
        ".github/workflows/agent-rules-update.yml": "replace",
        "AGENTS.md": "agent-rules",
        "_agent-rules-source.json": "agent-rules",
        "docs/SKILLS.md": "initialize-only",
        "docs/release-package.md": "initialize-only",
        "docs/repository-files.md": "initialize-only",
        "docs/repository-migration.md": "initialize-only",
        "tools/README.md": "initialize-only",
        "tools/repository-audit.sh": "initialize-only",
    }
    for path, strategy in expected_strategies.items():
        if strategies.get(path) != strategy:
            raise SystemExit(f"Unexpected upgrade strategy for {path}.")
PY

  if "$pwsh_cmd" -NoProfile -ExecutionPolicy Bypass -File "$build_release_package_ps1" \
    -RepositoryRef local-test \
    -AgentRulesRef invalid \
    -OutputDirectory "$(to_pwsh_path "$release_output")"; then
    echo "Release package accepted an invalid agent rules ref." >&2
    exit 1
  fi
}

run_static() {
  require_command git
  require_command shellcheck
  require_command shfmt
  local node_cmd
  node_cmd="$(resolve_command node node.exe)"

  check_git_whitespace
  bash -n .githooks/pre-commit
  bash -n .githooks/commit-msg
  bash -n tools/git-init.sh
  shellcheck --version
  shellcheck .githooks/pre-commit
  shellcheck .githooks/commit-msg
  shellcheck tools/git-init.sh
  shfmt -d -i 2 tools/git-init.sh
  check_semver_pattern_drift "$node_cmd"
  check_release_package_portability
  run_powershell_parse
  run_qmd_script_tests
  run_script_smoke
  "$node_cmd" --check commitlint.config.cjs
  run_commitlint
}

run_readonly() {
  require_command git
  require_command bash

  local actionlint_cmd
  local codespell_cmd
  local commitlint_cmd
  local gitleaks_cmd
  local markdownlint_cmd
  local node_cmd
  local shellcheck_cmd
  local shfmt_cmd
  local yamllint_cmd
  actionlint_cmd="$(resolve_command actionlint actionlint.exe)"
  codespell_cmd="$(resolve_command codespell codespell.cmd codespell.exe)"
  commitlint_cmd="$(resolve_command commitlint commitlint.cmd)"
  gitleaks_cmd="$(resolve_command gitleaks gitleaks.exe)"
  markdownlint_cmd="$(
    resolve_command markdownlint-cli2 markdownlint-cli2.cmd
  )"
  node_cmd="$(resolve_command node node.exe)"
  shellcheck_cmd="$(resolve_command shellcheck shellcheck.exe)"
  shfmt_cmd="$(resolve_command shfmt shfmt.exe)"
  yamllint_cmd="$(resolve_command yamllint yamllint.exe)"

  "$markdownlint_cmd" "**/*.md"
  "$codespell_cmd" .
  "$yamllint_cmd" .
  "$actionlint_cmd"
  check_git_whitespace
  bash -n .githooks/pre-commit
  bash -n .githooks/commit-msg
  bash -n tools/git-init.sh
  "$shellcheck_cmd" --version
  "$shellcheck_cmd" .githooks/pre-commit
  "$shellcheck_cmd" .githooks/commit-msg
  "$shellcheck_cmd" tools/git-init.sh
  "$shfmt_cmd" -d -i 2 tools/git-init.sh
  check_semver_pattern_drift "$node_cmd"
  check_release_package_portability
  run_powershell_parse_readonly
  run_qmd_script_tests
  "$node_cmd" --check commitlint.config.cjs
  run_commitlint_readonly "$commitlint_cmd"
  "$gitleaks_cmd" git --redact --no-banner --no-color .
}

case "$mode" in
  readonly)
    run_readonly
    ;;
  full|all)
    run_markdown
    run_spelling
    run_static
    ;;
  markdown)
    run_markdown
    ;;
  spelling)
    run_spelling
    ;;
  static)
    run_static
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
