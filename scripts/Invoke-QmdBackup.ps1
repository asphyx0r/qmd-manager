<#
.SYNOPSIS
Backs up and transactionally restores a QMD environment.

.DESCRIPTION
Creates validated ZIP archives containing QMD configurations, coherent SQLite
snapshots, indexed files, and optional local models. Restores those archives to
their original Windows paths only after validating a rollback archive.

.NOTES
This script intentionally parses GNU-style arguments itself. Native PowerShell
parameter binding would also accept implicit abbreviations that are outside the
documented command-line contract.
#>

Set-StrictMode -Version Latest

$script:ScriptName = 'Invoke-QmdBackup.ps1'
$script:ScriptVersion = 'v0.1.3'
$script:ArchiveFormatVersion = 1
$script:RollbackFormatVersion = 1
$script:RequiredQmdVersion = '2.5.3'
$script:MinimumPowerShellVersion = [version]'7.4'
$script:DefaultSqliteBusyTimeoutMilliseconds = 5000
$script:StableCopyAttempts = 3
$script:LogPath = $null
$script:VerboseEnabled = $false
$script:CurrentMode = 'UNKNOWN'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:PathComparer = if ($IsWindows) {
  [System.StringComparer]::OrdinalIgnoreCase
}
else {
  [System.StringComparer]::Ordinal
}
$script:QmdEnvironmentVariableNames = @(
  'QMD_CONFIG_DIR'
  'XDG_CONFIG_HOME'
  'XDG_CACHE_HOME'
  'INDEX_PATH'
  'QMD_EMBED_MODEL'
  'QMD_GENERATE_MODEL'
  'QMD_RERANK_MODEL'
  'QMD_SQLITE_BUSY_TIMEOUT'
)
$script:DefaultModelReferences = [ordered]@{
  embed = 'hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf'
  generate = 'hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf'
  rerank = 'hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf'
}

$script:HelpLines = @(
  "$($script:ScriptName) $($script:ScriptVersion)"
  ''
  'Back up and transactionally restore QMD indexes, indexed files, and local models.'
  ''
  'usage: Invoke-QmdBackup.ps1 [-h|--help] [--version]'
  '       Invoke-QmdBackup.ps1 (-b|--backup) -o|--output-directory PATH'
  '                            [--scan-root PATH ...]'
  '                            [-i|--include-datas] [-m|--include-model]'
  '                            [--dry-run] [-v|--verbose] [--force]'
  '       Invoke-QmdBackup.ps1 (-r|--restore) -s|--source-file FILE'
  '                            [-o|--output-directory PATH]'
  '                            [--dry-run] [-v|--verbose] [--force]'
  ''
  'options:'
  '  -h, --help              show this help message and exit'
  '  --version               show version and exit'
  '  --dry-run               show the execution plan without side effects'
  '  -v, --verbose           enable DEBUG console and file logging'
  '  -b, --backup            create a QMD backup archive'
  '  -r, --restore           transactionally restore a QMD backup archive'
  '  -i, --include-datas     use FULL mode and include indexed files'
  '  -m, --include-model     use FULL-OFFLINE mode; implies indexed files'
  '  -o, --output-directory  set backup output or restore work directory'
  '  -s, --source-file       set the QMD backup archive to restore'
  '  --scan-root             recursively scan a root for local .qmd indexes; repeatable'
  '  --force                 automatically confirm replacements (DANGEROUS)'
  ''
  'backup modes:'
  '  INDEX         configurations and SQLite index snapshots'
  '  FULL          INDEX plus files present in the QMD indexes'
  '  FULL-OFFLINE  FULL plus local QMD models'
  ''
  'WARNING: --force is dangerous. After the complete plan is displayed, it'
  'authorizes replacement of existing files without further interaction.'
)

function Write-QmdMessage {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
    [string]$Level,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if ($Level -eq 'DEBUG' -and -not $script:VerboseEnabled) {
    return
  }

  $label = switch ($Level) {
    'DEBUG' { '[DEBUG]' }
    'INFO' { '[INFO ]' }
    'WARN' { '[WARN ]' }
    'ERROR' { '[ERROR]' }
    'FATAL' { '[FATAL]' }
  }
  $timestamp = [DateTimeOffset]::Now.ToString(
    'yyyy-MM-dd HH:mm:ss',
    [System.Globalization.CultureInfo]::InvariantCulture
  )
  $line = '{0} {1} {2}' -f $timestamp, $label, $Message

  if ($Level -in @('ERROR', 'FATAL')) {
    [Console]::Error.WriteLine($line)
  }
  else {
    [Console]::Out.WriteLine($line)
  }

  if ($null -ne $script:LogPath) {
    [System.IO.File]::AppendAllText(
      $script:LogPath,
      "$line$([Environment]::NewLine)",
      $script:Utf8NoBom
    )
  }
}

function Write-QmdItem {
  param(
    [Parameter(Mandatory)]
    [string]$Label,

    [Parameter(Mandatory)]
    [string]$Path,

    [ValidateSet('DEBUG', 'INFO', 'WARN')]
    [string]$Level = 'INFO'
  )

  Write-QmdMessage -Level $Level -Message ('{0} | {1}' -f $Label.PadRight(26), $Path)
}

function Write-QmdFinalStatus {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('COMPLETED', 'COMPLETED-WITH-ERRORS', 'FAILED')]
    [string]$Status,

    [Parameter(Mandatory)]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateRange(0, 4)]
    [int]$ReturnCode,

    [string]$SourceMode
  )

  $line = "STATUS=$Status MODE=$Mode"
  if (-not [string]::IsNullOrWhiteSpace($SourceMode)) {
    $line += " SOURCE-MODE=$SourceMode"
  }
  $line += " RC=$ReturnCode"

  [Console]::Out.WriteLine($line)
  if ($null -ne $script:LogPath) {
    [System.IO.File]::AppendAllText(
      $script:LogPath,
      "$line$([Environment]::NewLine)",
      $script:Utf8NoBom
    )
  }
}

function New-QmdException {
  param(
    [Parameter(Mandatory)]
    [string]$Message,

    [ValidateRange(2, 4)]
    [int]$ReturnCode = 2
  )

  $exception = [System.InvalidOperationException]::new($Message)
  $exception.Data['QmdReturnCode'] = $ReturnCode
  $exception
}

function Get-QmdExceptionReturnCode {
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord,

    [ValidateRange(2, 4)]
    [int]$DefaultReturnCode = 2
  )

  if ($ErrorRecord.Exception.Data.Contains('QmdReturnCode')) {
    return [int]$ErrorRecord.Exception.Data['QmdReturnCode']
  }

  $DefaultReturnCode
}

function Get-ParsedArguments {
  param(
    [AllowEmptyCollection()]
    [object[]]$Tokens = @()
  )

  $parsed = [ordered]@{
    Help = $false
    Version = $false
    DryRun = $false
    Verbose = $false
    Backup = $false
    Restore = $false
    IncludeDatas = $false
    IncludeModel = $false
    OutputDirectory = $null
    SourceFile = $null
    ScanRoots = [System.Collections.Generic.List[string]]::new()
    Force = $false
  }
  $seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
  )

  for ($index = 0; $index -lt $Tokens.Count; $index++) {
    $token = [string]$Tokens[$index]
    $logicalName = switch ($token) {
      '-h' { 'Help' }
      '--help' { 'Help' }
      '--version' { 'Version' }
      '--dry-run' { 'DryRun' }
      '-v' { 'Verbose' }
      '--verbose' { 'Verbose' }
      '-b' { 'Backup' }
      '--backup' { 'Backup' }
      '-r' { 'Restore' }
      '--restore' { 'Restore' }
      '-i' { 'IncludeDatas' }
      '--include-datas' { 'IncludeDatas' }
      '-m' { 'IncludeModel' }
      '--include-model' { 'IncludeModel' }
      '-o' { 'OutputDirectory' }
      '--output-directory' { 'OutputDirectory' }
      '-s' { 'SourceFile' }
      '--source-file' { 'SourceFile' }
      '--scan-root' { 'ScanRoots' }
      '--force' { 'Force' }
      default {
        throw (New-QmdException -Message "Unknown argument: '$token'.")
      }
    }

    if ($logicalName -eq 'ScanRoots') {
      if ($index + 1 -ge $Tokens.Count) {
        throw (New-QmdException -Message "Option '$token' requires a path.")
      }
      $index++
      $value = [string]$Tokens[$index]
      if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('-')) {
        throw (New-QmdException -Message "Option '$token' requires a path.")
      }
      $parsed.ScanRoots.Add($value)
      continue
    }

    if ($logicalName -in @('OutputDirectory', 'SourceFile')) {
      if (-not $seen.Add($logicalName)) {
        throw (New-QmdException -Message "Option '$token' was specified more than once.")
      }
      if ($index + 1 -ge $Tokens.Count) {
        throw (New-QmdException -Message "Option '$token' requires a path.")
      }
      $index++
      $value = [string]$Tokens[$index]
      if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('-')) {
        throw (New-QmdException -Message "Option '$token' requires a path.")
      }
      $parsed[$logicalName] = $value
      continue
    }

    if (-not $seen.Add($logicalName)) {
      throw (New-QmdException -Message "Option '$token' was specified more than once.")
    }
    $parsed[$logicalName] = $true
  }

  [pscustomobject]$parsed
}

function Assert-ValidArgumentCombination {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Arguments
  )

  if ($Arguments.Help -and $Arguments.Version) {
    throw (New-QmdException -Message '--help and --version cannot be combined.')
  }

  if ($Arguments.Help -or $Arguments.Version) {
    return
  }

  if ([bool]$Arguments.Backup -eq [bool]$Arguments.Restore) {
    throw (New-QmdException -Message 'Exactly one of --backup or --restore is required.')
  }

  if ($Arguments.Backup) {
    if ([string]::IsNullOrWhiteSpace($Arguments.OutputDirectory)) {
      throw (New-QmdException -Message '--output-directory is required with --backup.')
    }
    if (-not [string]::IsNullOrWhiteSpace($Arguments.SourceFile)) {
      throw (New-QmdException -Message '--source-file is not allowed with --backup.')
    }
    return
  }

  if ([string]::IsNullOrWhiteSpace($Arguments.SourceFile)) {
    throw (New-QmdException -Message '--source-file is required with --restore.')
  }
  if ($Arguments.IncludeDatas -or $Arguments.IncludeModel) {
    throw (New-QmdException -Message '--include-datas and --include-model are not allowed with --restore.')
  }
  if ($Arguments.ScanRoots.Count -gt 0) {
    throw (New-QmdException -Message '--scan-root is not allowed with --restore.')
  }
}

function Get-BackupMode {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Arguments
  )

  if ($Arguments.IncludeModel) {
    return [pscustomobject]@{
      Name = 'FULL-OFFLINE'
      Suffix = 'MODELS'
      IncludeData = $true
      IncludeModels = $true
    }
  }

  if ($Arguments.IncludeDatas) {
    return [pscustomobject]@{
      Name = 'FULL'
      Suffix = 'DATAS'
      IncludeData = $true
      IncludeModels = $false
    }
  }

  [pscustomobject]@{
    Name = 'INDEX'
    Suffix = 'INDEX'
    IncludeData = $false
    IncludeModels = $false
  }
}

function Test-PathEqual {
  param(
    [Parameter(Mandatory)]
    [string]$Left,

    [Parameter(Mandatory)]
    [string]$Right
  )

  $script:PathComparer.Equals($Left, $Right)
}

function Get-CanonicalExistingPath {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath,

    [ValidateSet('Any', 'File', 'Directory')]
    [string]$PathType = 'Any'
  )

  try {
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  }
  catch {
    throw (New-QmdException -Message "Path does not exist or is inaccessible: '$LiteralPath'.")
  }

  if ($PathType -eq 'File' -and $item.PSIsContainer) {
    throw (New-QmdException -Message "Expected a file but found a directory: '$LiteralPath'.")
  }
  if ($PathType -eq 'Directory' -and -not $item.PSIsContainer) {
    throw (New-QmdException -Message "Expected a directory but found a file: '$LiteralPath'.")
  }

  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    try {
      $target = $item.ResolveLinkTarget($true)
      if ($null -eq $target) {
        throw [System.IO.IOException]::new('The reparse target could not be resolved.')
      }
      $item = $target
    }
    catch {
      throw (New-QmdException -Message "Reparse target cannot be resolved safely: '$LiteralPath'.")
    }
  }

  [System.IO.Path]::GetFullPath($item.FullName)
}

function Get-CanonicalTargetPath {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  try {
    [System.IO.Path]::GetFullPath($LiteralPath)
  }
  catch {
    throw (New-QmdException -Message "Invalid Windows path: '$LiteralPath'.")
  }
}

function Test-NormalFile {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  if ($item.PSIsContainer) {
    throw (New-QmdException -Message "Expected a regular file: '$LiteralPath'.")
  }
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw (New-QmdException -Message "Reparse-point files are not supported: '$LiteralPath'.")
  }
  $item
}

function Test-DirectoryWriteAccess {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  $directory = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  if (($directory.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
    return $false
  }

  try {
    $acl = Get-Acl -LiteralPath $directory.FullName -ErrorAction Stop
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase
    )
    $null = $sids.Add($identity.User.Value)
    foreach ($group in $identity.Groups) {
      $null = $sids.Add($group.Value)
    }

    $required = [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
      [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
      [System.Security.AccessControl.FileSystemRights]::WriteData
    $allowed = [System.Security.AccessControl.FileSystemRights]0

    foreach ($rule in $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
      )) {
      if (-not $sids.Contains($rule.IdentityReference.Value)) {
        continue
      }
      $relevant = $rule.FileSystemRights -band $required
      if ($relevant -eq 0) {
        continue
      }
      if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
        return $false
      }
      $allowed = $allowed -bor $relevant
    }

    return (($allowed -band $required) -eq $required)
  }
  catch {
    Write-QmdMessage -Level 'WARN' -Message (
      "The non-mutating ACL write check was inconclusive for '$LiteralPath': " +
      $_.Exception.Message
    )
    return $true
  }
}

function Assert-OperationalDirectory {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath,

    [Parameter(Mandatory)]
    [string]$Purpose
  )

  $canonicalPath = Get-CanonicalExistingPath -LiteralPath $LiteralPath -PathType Directory
  $directory = Get-Item -LiteralPath $canonicalPath -Force -ErrorAction Stop
  if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw (New-QmdException -Message "$Purpose must be a normal directory: '$canonicalPath'.")
  }
  if (-not (Test-DirectoryWriteAccess -LiteralPath $canonicalPath)) {
    throw (New-QmdException -Message "$Purpose is not writable: '$canonicalPath'.")
  }
  $canonicalPath
}

function Get-Sha256Hex {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  $stream = [System.IO.File]::Open(
    $LiteralPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = $algorithm.ComputeHash($stream)
    }
    finally {
      $algorithm.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }

  ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-StringSha256Hex {
  param(
    [Parameter(Mandatory)]
    [string]$Value
  )

  $bytes = $script:Utf8NoBom.GetBytes($Value)
  $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
  ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Copy-StableFile {
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw (New-QmdException -Message (
      "Source file does not exist immediately before copy: '$SourcePath'."
    ) -ReturnCode 3)
  }
  $null = Test-NormalFile -LiteralPath $SourcePath
  $destinationDirectory = Split-Path -Parent $DestinationPath
  $null = [System.IO.Directory]::CreateDirectory($destinationDirectory)

  for ($attempt = 1; $attempt -le $script:StableCopyAttempts; $attempt++) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
      throw (New-QmdException -Message (
        "Source file disappeared before copy attempt $attempt`: '$SourcePath'."
      ) -ReturnCode 3)
    }
    $before = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    [System.IO.File]::Copy($SourcePath, $DestinationPath, $true)
    $copiedHash = Get-Sha256Hex -LiteralPath $DestinationPath
    $sourceHash = Get-Sha256Hex -LiteralPath $SourcePath
    $after = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop

    $stable = (
      $before.Length -eq $after.Length -and
      $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc -and
      $sourceHash -eq $copiedHash
    )
    if ($stable) {
      return [pscustomobject]@{
        Size = [int64](Get-Item -LiteralPath $DestinationPath).Length
        LastWriteTimeUtc = $before.LastWriteTimeUtc.ToString('o')
        Sha256 = $copiedHash
      }
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
      Remove-Item -LiteralPath $DestinationPath -Force
    }
    if ($attempt -lt $script:StableCopyAttempts) {
      Start-Sleep -Milliseconds 100
    }
  }

  throw (New-QmdException -Message "Source file changed while being copied: '$SourcePath'." -ReturnCode 3)
}

function Get-FileMetadata {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath,

    [switch]$IncludeHash
  )

  $item = Test-NormalFile -LiteralPath $LiteralPath
  [pscustomobject]@{
    Exists = $true
    Size = [int64]$item.Length
    LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    Sha256 = if ($IncludeHash) { Get-Sha256Hex -LiteralPath $LiteralPath } else { $null }
  }
}

function Initialize-QmdLog {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  $stream = [System.IO.File]::Open(
    $LiteralPath,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::Read
  )
  $stream.Dispose()
  $script:LogPath = $LiteralPath
}

function Confirm-QmdAction {
  param(
    [Parameter(Mandatory)]
    [string]$Message,

    [switch]$Force
  )

  Write-QmdMessage -Level 'WARN' -Message $Message
  if ($Force) {
    Write-QmdMessage -Level 'INFO' -Message 'Confirmation automatically accepted because --force is active.'
    return
  }

  $answer = Read-Host 'Enter Y to continue'
  if ($answer -cne 'Y') {
    throw (New-QmdException -Message 'Operation refused by the user.')
  }
}

function Invoke-QmdExternalCommand {
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [AllowEmptyCollection()]
    [string[]]$ArgumentList = @(),

    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 30
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $extension = [System.IO.Path]::GetExtension($FilePath)
  if ($extension -ieq '.cmd' -or $extension -ieq '.bat') {
    $startInfo.FileName = $env:ComSpec
    foreach ($argument in @('/d', '/s', '/c', $FilePath) + $ArgumentList) {
      $startInfo.ArgumentList.Add($argument)
    }
  }
  elseif ($extension -ieq '.ps1') {
    $powerShellPath = (Get-Command 'pwsh.exe' -CommandType Application `
        -ErrorAction Stop).Source
    $startInfo.FileName = $powerShellPath
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $FilePath) + $ArgumentList) {
      $startInfo.ArgumentList.Add($argument)
    }
  }
  else {
    $startInfo.FileName = $FilePath
    foreach ($argument in $ArgumentList) {
      $startInfo.ArgumentList.Add($argument)
    }
  }
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = $script:Utf8NoBom
  $startInfo.StandardErrorEncoding = $script:Utf8NoBom

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      throw [System.InvalidOperationException]::new("Failed to start '$FilePath'.")
    }
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try {
        $process.Kill($true)
      }
      catch {
        Write-QmdMessage -Level 'DEBUG' -Message (
          "Timed-out process tree could not be terminated cleanly: $($_.Exception.Message)"
        )
      }
      return [pscustomobject]@{
        ExitCode = 124
        Output = @()
        Text = "Command timed out after $TimeoutSeconds seconds: '$FilePath'."
      }
    }
    $exitCode = $process.ExitCode
    $captureCompleted = [System.Threading.Tasks.Task]::WaitAll(
      [System.Threading.Tasks.Task[]]@($standardOutputTask, $standardErrorTask),
      2000
    )
    if ($captureCompleted) {
      $output = @(
        @($standardOutputTask.Result -split '\r?\n')
        @($standardErrorTask.Result -split '\r?\n')
      ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    }
    else {
      $output = @()
      Write-QmdMessage -Level 'DEBUG' -Message (
        "Output capture did not close promptly for '$FilePath'; exit code was still collected."
      )
    }
  }
  finally {
    $process.Dispose()
  }

  [pscustomobject]@{
    ExitCode = [int]$exitCode
    Output = $output
    Text = ($output -join [Environment]::NewLine).Trim()
  }
}

function Get-QmdCommandPath {
  $candidates = @(
    @(
      Get-Command 'qmd.cmd' -CommandType Application -ErrorAction SilentlyContinue
      Get-Command 'qmd.exe' -CommandType Application -ErrorAction SilentlyContinue
      Get-Command 'qmd' -ErrorAction SilentlyContinue
    ) | Where-Object { $null -ne $_ }
  )

  if ($candidates.Count -eq 0) {
    throw (New-QmdException -Message 'qmd is absent from PATH or cannot be resolved.')
  }

  [string]$candidates[0].Source
}

function Get-QmdPackageContext {
  param(
    [Parameter(Mandatory)]
    [string]$QmdCommandPath
  )

  $commandDirectory = Split-Path -Parent $QmdCommandPath
  $packageRootCandidates = @(
    (Join-Path $commandDirectory 'node_modules\@tobilu\qmd')
    (Split-Path -Parent $commandDirectory)
  )

  $packageRoot = $null
  foreach ($candidate in $packageRootCandidates) {
    $packageJson = Join-Path $candidate 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
      continue
    }
    try {
      $package = Get-Content -LiteralPath $packageJson -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
      if ($package.name -eq '@tobilu/qmd') {
        $packageRoot = Get-CanonicalExistingPath -LiteralPath $candidate -PathType Directory
        break
      }
    }
    catch {
      continue
    }
  }

  if ($null -eq $packageRoot) {
    throw (New-QmdException -Message (
      'The QMD package layout is not the verified npm layout for QMD 2.5.3.'
    ))
  }

  $yamlPackagePath = Join-Path $packageRoot 'node_modules\yaml'
  if (-not (Test-Path -LiteralPath $yamlPackagePath -PathType Container)) {
    throw (New-QmdException -Message 'The YAML parser bundled with QMD cannot be located.')
  }

  $vecCandidates = @(
    (Join-Path $packageRoot 'node_modules\sqlite-vec-windows-x64\vec0.dll')
    (Join-Path $packageRoot 'node_modules\sqlite-vec\vec0.dll')
  )
  $vecPath = $vecCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1

  [pscustomobject]@{
    PackageRoot = $packageRoot
    YamlPackagePath = Get-CanonicalExistingPath -LiteralPath $yamlPackagePath -PathType Directory
    SqliteVecPath = if ($null -eq $vecPath) {
      $null
    }
    else {
      Get-CanonicalExistingPath -LiteralPath $vecPath -PathType File
    }
  }
}

function Get-QmdDependencyContext {
  if (-not $IsWindows) {
    throw (New-QmdException -Message 'Operational modes require Windows 11.')
  }
  if ($PSVersionTable.PSVersion -lt $script:MinimumPowerShellVersion) {
    throw (New-QmdException -Message (
      "PowerShell $($script:MinimumPowerShellVersion) or later is required."
    ))
  }
  if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw (New-QmdException -Message 'Operational modes require Windows 11 build 22000 or later.')
  }

  $qmdPath = Get-QmdCommandPath
  $qmdVersionResult = Invoke-QmdExternalCommand -FilePath $qmdPath -ArgumentList @('--version')
  if ($qmdVersionResult.ExitCode -ne 0 -or $qmdVersionResult.Text -notmatch '^qmd\s+(\d+\.\d+\.\d+)$') {
    throw (New-QmdException -Message 'qmd is present but unusable or returned an unrecognized version.')
  }
  $qmdVersion = $Matches[1]
  if ($qmdVersion -ne $script:RequiredQmdVersion) {
    throw (New-QmdException -Message (
      "QMD $qmdVersion is not supported by this script. Verified version: " +
      "$($script:RequiredQmdVersion)."
    ))
  }

  $sqliteCommand = Get-Command 'sqlite3.exe' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $sqliteCommand) {
    throw (New-QmdException -Message 'sqlite3.exe is absent from PATH or cannot be resolved.')
  }
  $sqlitePath = [string]$sqliteCommand.Source
  $sqliteVersionResult = Invoke-QmdExternalCommand -FilePath $sqlitePath -ArgumentList @('--version')
  if ($sqliteVersionResult.ExitCode -ne 0 -or $sqliteVersionResult.Text -notmatch '^(\d+\.\d+\.\d+)') {
    throw (New-QmdException -Message 'sqlite3.exe is present but unusable.')
  }
  $sqliteVersion = $Matches[1]

  $nodeCommand = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $nodeCommand) {
    throw (New-QmdException -Message 'The Node.js runtime used by qmd cannot be resolved.')
  }

  $package = Get-QmdPackageContext -QmdCommandPath $qmdPath
  Write-QmdMessage -Level 'INFO' -Message "PowerShell version | $($PSVersionTable.PSVersion)"
  Write-QmdMessage -Level 'INFO' -Message "QMD version        | $qmdVersion"
  Write-QmdMessage -Level 'INFO' -Message "SQLite version     | $sqliteVersion"

  [pscustomobject]@{
    QmdPath = $qmdPath
    QmdVersion = $qmdVersion
    SqlitePath = $sqlitePath
    SqliteVersion = $sqliteVersion
    NodePath = [string]$nodeCommand.Source
    QmdPackageRoot = $package.PackageRoot
    YamlPackagePath = $package.YamlPackagePath
    SqliteVecPath = $package.SqliteVecPath
  }
}

function Get-SqliteBusyTimeout {
  $configured = [Environment]::GetEnvironmentVariable(
    'QMD_SQLITE_BUSY_TIMEOUT',
    [EnvironmentVariableTarget]::Process
  )
  if ([string]::IsNullOrWhiteSpace($configured)) {
    return $script:DefaultSqliteBusyTimeoutMilliseconds
  }

  $parsed = 0
  if (-not [int]::TryParse($configured, [ref]$parsed) -or $parsed -lt 1) {
    throw (New-QmdException -Message 'QMD_SQLITE_BUSY_TIMEOUT must be a positive integer.')
  }
  $parsed
}

function Invoke-QmdSqlite {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$DatabasePath,

    [Parameter(Mandatory)]
    [string]$Command,

    [switch]$ReadOnly,

    [switch]$Json
  )

  $arguments = [System.Collections.Generic.List[string]]::new()
  $arguments.Add('-batch')
  if ($ReadOnly) {
    $arguments.Add('-readonly')
  }
  if ($Json) {
    $arguments.Add('-json')
  }
  if ($null -ne $Dependencies.SqliteVecPath) {
    $vecPath = $Dependencies.SqliteVecPath.Replace('\', '/')
    $arguments.Add('-cmd')
    $arguments.Add(".load `"$vecPath`"")
  }
  $arguments.Add($DatabasePath)
  $arguments.Add($Command)

  Invoke-QmdExternalCommand -FilePath $Dependencies.SqlitePath -ArgumentList $arguments.ToArray()
}

function Assert-QmdSqliteIntegrity {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  $result = Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
    -Command 'PRAGMA integrity_check;' -ReadOnly
  if ($result.ExitCode -ne 0 -or $result.Text -cne 'ok') {
    throw (New-QmdException -Message (
      "SQLite integrity check failed for '$DatabasePath': $($result.Text)"
    ) -ReturnCode 3)
  }
}

function New-QmdSqliteSnapshot {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$DestinationPath
  )

  $timeout = Get-SqliteBusyTimeout
  $destinationDirectory = Split-Path -Parent $DestinationPath
  $null = [System.IO.Directory]::CreateDirectory($destinationDirectory)
  $sqliteDestination = $DestinationPath.Replace('\', '/')
  $backupCommand = ".backup `"$sqliteDestination`""

  $arguments = [System.Collections.Generic.List[string]]::new()
  $arguments.Add('-batch')
  $arguments.Add('-readonly')
  $arguments.Add($SourcePath)
  $arguments.Add(".timeout $timeout")
  $arguments.Add($backupCommand)
  $result = Invoke-QmdExternalCommand -FilePath $Dependencies.SqlitePath `
    -ArgumentList $arguments.ToArray()
  if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
    throw (New-QmdException -Message (
      "SQLite snapshot failed for '$SourcePath': $($result.Text)"
    ) -ReturnCode 3)
  }

  try {
    Assert-QmdSqliteIntegrity -Dependencies $Dependencies -DatabasePath $DestinationPath
  }
  finally {
    foreach ($suffix in @('-wal', '-shm')) {
      $sidecarPath = "$DestinationPath$suffix"
      if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
        Remove-Item -LiteralPath $sidecarPath -Force
      }
    }
  }
  Get-FileMetadata -LiteralPath $DestinationPath -IncludeHash
}

function Remove-QmdOwnedSqliteSidecars {
  param(
    [Parameter(Mandatory)]
    [string]$DatabasePath,

    [Parameter(Mandatory)]
    [string]$ExpectedStagingRoot
  )

  $databaseFullPath = [System.IO.Path]::GetFullPath($DatabasePath)
  $stagingPrefix = [System.IO.Path]::GetFullPath($ExpectedStagingRoot).TrimEnd('\') + '\'
  if (-not $databaseFullPath.StartsWith(
      $stagingPrefix,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw (New-QmdException -Message (
      "Refusing to remove SQLite sidecars outside owned staging: '$DatabasePath'."
    ) -ReturnCode 3)
  }

  foreach ($suffix in @('-wal', '-shm')) {
    $sidecarPath = "$databaseFullPath$suffix"
    if (Test-Path -LiteralPath $sidecarPath -PathType Leaf) {
      Remove-Item -LiteralPath $sidecarPath -Force
      Write-QmdMessage -Level 'DEBUG' -Message (
        "Removed transient snapshot sidecar | $sidecarPath"
      )
    }
  }
}

function ConvertFrom-QmdSqliteJson {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Result,

    [Parameter(Mandatory)]
    [string]$Context
  )

  if ($Result.ExitCode -ne 0) {
    throw (New-QmdException -Message "SQLite query failed for $Context`: $($Result.Text)")
  }
  if ([string]::IsNullOrWhiteSpace($Result.Text)) {
    return @()
  }
  try {
    @($Result.Text | ConvertFrom-Json -ErrorAction Stop)
  }
  catch {
    throw (New-QmdException -Message "SQLite returned invalid JSON for $Context.")
  }
}

function Read-QmdConfiguration {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$ConfigurationPath
  )

  $program = @'
const fs = require("fs");
const YAML = require(process.argv[1]);
const config = YAML.parse(fs.readFileSync(process.argv[2], "utf8")) || {};
const collections = config.collections || {};
if (typeof collections !== "object" || Array.isArray(collections)) {
  throw new Error("collections must be a mapping");
}
const result = {
  collections: Object.keys(collections).sort().map((name) => {
    const value = collections[name] || {};
    if (typeof value.path !== "string" || value.path.trim() === "") {
      throw new Error(`collection ${name} has no valid path`);
    }
    return {
      name,
      path: value.path,
      pattern: typeof value.pattern === "string" && value.pattern !== ""
        ? value.pattern
        : "**/*.md"
    };
  }),
  models: {
    embed: config.models && typeof config.models.embed === "string" ? config.models.embed : null,
    generate: config.models && typeof config.models.generate === "string" ? config.models.generate : null,
    rerank: config.models && typeof config.models.rerank === "string" ? config.models.rerank : null
  }
};
process.stdout.write(JSON.stringify(result));
'@

  $result = Invoke-QmdExternalCommand -FilePath $Dependencies.NodePath -ArgumentList @(
    '-e'
    $program
    $Dependencies.YamlPackagePath
    $ConfigurationPath
  )
  if ($result.ExitCode -ne 0) {
    throw (New-QmdException -Message (
      "QMD configuration cannot be parsed: '$ConfigurationPath'. $($result.Text)"
    ))
  }
  try {
    $result.Text | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw (New-QmdException -Message "QMD configuration produced invalid JSON: '$ConfigurationPath'.")
  }
}

function Assert-QmdSchemaCompatible {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  $documentsQuery = @'
SELECT name, upper(type) AS type
FROM pragma_table_info('documents')
ORDER BY cid;
'@
  $collectionsQuery = @'
SELECT name, upper(type) AS type
FROM pragma_table_info('store_collections')
ORDER BY cid;
'@

  $documents = ConvertFrom-QmdSqliteJson -Context "'$DatabasePath' documents schema" -Result (
    Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
      -Command $documentsQuery -ReadOnly -Json
  )
  $collections = ConvertFrom-QmdSqliteJson -Context "'$DatabasePath' collections schema" -Result (
    Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
      -Command $collectionsQuery -ReadOnly -Json
  )

  $requiredDocumentColumns = [ordered]@{
    id = 'INTEGER'
    collection = 'TEXT'
    path = 'TEXT'
    title = 'TEXT'
    hash = 'TEXT'
    created_at = 'TEXT'
    modified_at = 'TEXT'
    active = 'INTEGER'
  }
  $requiredCollectionColumns = [ordered]@{
    name = 'TEXT'
    path = 'TEXT'
    pattern = 'TEXT'
    ignore_patterns = 'TEXT'
  }

  foreach ($required in $requiredDocumentColumns.GetEnumerator()) {
    $match = @($documents | Where-Object { $_.name -ceq $required.Key })
    if ($match.Count -ne 1 -or $match[0].type -cne $required.Value) {
      throw (New-QmdException -Message (
        "Unrecognized QMD documents schema in '$DatabasePath' at column '$($required.Key)'."
      ))
    }
  }
  foreach ($required in $requiredCollectionColumns.GetEnumerator()) {
    $match = @($collections | Where-Object { $_.name -ceq $required.Key })
    if ($match.Count -ne 1 -or $match[0].type -cne $required.Value) {
      throw (New-QmdException -Message (
        "Unrecognized QMD store_collections schema in '$DatabasePath' at column '$($required.Key)'."
      ))
    }
  }
}

function Get-QmdDatabaseCollections {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  $query = @'
SELECT name, path, pattern
FROM store_collections
ORDER BY name COLLATE BINARY;
'@
  ConvertFrom-QmdSqliteJson -Context "'$DatabasePath' collections" -Result (
    Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
      -Command $query -ReadOnly -Json
  )
}

function Get-QmdIndexedDocuments {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  $orphanQuery = @'
SELECT COUNT(*) AS orphanCount
FROM documents AS d
LEFT JOIN store_collections AS c ON c.name = d.collection
WHERE d.active = 1 AND c.name IS NULL;
'@
  $orphanRows = ConvertFrom-QmdSqliteJson -Context "'$DatabasePath' orphan documents" -Result (
    Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
      -Command $orphanQuery -ReadOnly -Json
  )
  if ($orphanRows.Count -ne 1 -or [int64]$orphanRows[0].orphanCount -ne 0) {
    throw (New-QmdException -Message (
      "Active documents without a collection were found in '$DatabasePath'."
    ))
  }

  $query = @'
SELECT
  d.collection AS collectionName,
  c.path AS collectionRoot,
  c.pattern AS collectionPattern,
  c.ignore_patterns AS collectionIgnorePatterns,
  d.path AS relativePath
FROM documents AS d
JOIN store_collections AS c ON c.name = d.collection
WHERE d.active = 1
ORDER BY d.collection COLLATE BINARY, d.path COLLATE BINARY;
'@
  ConvertFrom-QmdSqliteJson -Context "'$DatabasePath' active documents" -Result (
    Invoke-QmdSqlite -Dependencies $Dependencies -DatabasePath $DatabasePath `
      -Command $query -ReadOnly -Json
  )
}

function Assert-QmdIndexCoherent {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [pscustomobject]$Index,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  Assert-QmdSchemaCompatible -Dependencies $Dependencies -DatabasePath $DatabasePath
  $databaseCollections = @(Get-QmdDatabaseCollections -Dependencies $Dependencies `
      -DatabasePath $DatabasePath)
  $configurationCollections = @($Index.Configuration.collections)

  if ($databaseCollections.Count -ne $configurationCollections.Count) {
    throw (New-QmdException -Message (
      "Configuration/database collection mismatch for index '$($Index.Name)'."
    ))
  }

  for ($position = 0; $position -lt $configurationCollections.Count; $position++) {
    $configured = $configurationCollections[$position]
    $stored = $databaseCollections[$position]
    if (
      $configured.name -cne $stored.name -or
      -not (Test-PathEqual -Left ([string]$configured.path) -Right ([string]$stored.path)) -or
      $configured.pattern -cne $stored.pattern
    ) {
      throw (New-QmdException -Message (
        "Configuration/database association is stale or ambiguous for index '$($Index.Name)'."
      ))
    }
  }
}

function Get-QmdEnvironmentState {
  $state = [System.Collections.Generic.List[object]]::new()
  foreach ($name in $script:QmdEnvironmentVariableNames) {
    $value = [Environment]::GetEnvironmentVariable(
      $name,
      [EnvironmentVariableTarget]::Process
    )
    $state.Add([ordered]@{
        name = $name
        isDefined = $null -ne $value
        value = $value
      })
  }
  $state.ToArray()
}

function Get-QmdResolvedPaths {
  $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  $qmdConfigDirectory = [Environment]::GetEnvironmentVariable('QMD_CONFIG_DIR', 'Process')
  if ([string]::IsNullOrWhiteSpace($qmdConfigDirectory)) {
    $xdgConfig = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'Process')
    $qmdConfigDirectory = if ([string]::IsNullOrWhiteSpace($xdgConfig)) {
      Join-Path $homePath '.config\qmd'
    }
    else {
      Join-Path $xdgConfig 'qmd'
    }
  }

  $xdgCache = [Environment]::GetEnvironmentVariable('XDG_CACHE_HOME', 'Process')
  $qmdCacheDirectory = if ([string]::IsNullOrWhiteSpace($xdgCache)) {
    Join-Path $homePath '.cache\qmd'
  }
  else {
    Join-Path $xdgCache 'qmd'
  }

  [pscustomobject]@{
    ConfigDirectory = Get-CanonicalTargetPath -LiteralPath $qmdConfigDirectory
    CacheDirectory = Get-CanonicalTargetPath -LiteralPath $qmdCacheDirectory
    ModelDirectory = Get-CanonicalTargetPath -LiteralPath (
      Join-Path $qmdCacheDirectory 'models'
    )
    IndexPathOverride = [Environment]::GetEnvironmentVariable('INDEX_PATH', 'Process')
  }
}

function Get-DeterministicIdentifier {
  param(
    [Parameter(Mandatory)]
    [string]$Prefix,

    [Parameter(Mandatory)]
    [string]$Value
  )

  $safePrefix = ($Prefix -replace '[^A-Za-z0-9_-]', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safePrefix)) {
    $safePrefix = 'item'
  }
  $hash = Get-StringSha256Hex -Value $Value.ToUpperInvariant()
  "$safePrefix-$($hash.Substring(0, 16))"
}

function New-QmdIndexRecord {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [ValidateSet('global', 'local')]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$ConfigurationPath,

    [Parameter(Mandatory)]
    [string]$DatabasePath
  )

  $configCanonical = Get-CanonicalExistingPath -LiteralPath $ConfigurationPath -PathType File
  $databaseCanonical = Get-CanonicalExistingPath -LiteralPath $DatabasePath -PathType File
  $null = Test-NormalFile -LiteralPath $configCanonical
  $null = Test-NormalFile -LiteralPath $databaseCanonical
  $configuration = Read-QmdConfiguration -Dependencies $Dependencies `
    -ConfigurationPath $configCanonical
  $identifier = Get-DeterministicIdentifier -Prefix "$Kind-$Name" `
    -Value "$configCanonical|$databaseCanonical"

  $record = [pscustomobject]@{
    Kind = $Kind
    Name = $Name
    Id = $identifier
    ConfigurationPath = $configCanonical
    DatabasePath = $databaseCanonical
    Configuration = $configuration
  }
  Assert-QmdIndexCoherent -Dependencies $Dependencies -Index $record `
    -DatabasePath $databaseCanonical
  $record
}

function Get-QmdGlobalIndexes {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [pscustomobject]$ResolvedPaths
  )

  if (-not (Test-Path -LiteralPath $ResolvedPaths.ConfigDirectory -PathType Container)) {
    throw (New-QmdException -Message (
      "QMD configuration directory does not exist: '$($ResolvedPaths.ConfigDirectory)'."
    ))
  }
  if (-not (Test-Path -LiteralPath $ResolvedPaths.CacheDirectory -PathType Container)) {
    throw (New-QmdException -Message (
      "QMD cache directory does not exist: '$($ResolvedPaths.CacheDirectory)'."
    ))
  }

  $configurations = @(
    Get-ChildItem -LiteralPath $ResolvedPaths.ConfigDirectory -File -Filter '*.yml' `
      -ErrorAction Stop |
      Sort-Object -Property Name
  )
  $databases = @(
    Get-ChildItem -LiteralPath $ResolvedPaths.CacheDirectory -File -Filter '*.sqlite' `
      -ErrorAction Stop |
      Sort-Object -Property Name
  )

  if ($configurations.Count -eq 0) {
    throw (New-QmdException -Message 'No global QMD configuration was found.')
  }
  if (
    -not [string]::IsNullOrWhiteSpace($ResolvedPaths.IndexPathOverride) -and
    $configurations.Count -gt 1
  ) {
    throw (New-QmdException -Message (
      'INDEX_PATH is active while multiple global configurations exist; ' +
      'QMD 2.5.3 does not provide an unambiguous database association.'
    ))
  }

  $indexes = [System.Collections.Generic.List[object]]::new()
  $pairedDatabases = [System.Collections.Generic.HashSet[string]]::new(
    $script:PathComparer
  )
  foreach ($configuration in $configurations) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($configuration.Name)
    $databasePath = if (-not [string]::IsNullOrWhiteSpace($ResolvedPaths.IndexPathOverride)) {
      $ResolvedPaths.IndexPathOverride
    }
    else {
      Join-Path $ResolvedPaths.CacheDirectory "$name.sqlite"
    }
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
      throw (New-QmdException -Message (
        "Global QMD configuration has no matching database: '$($configuration.FullName)'."
      ))
    }

    $record = New-QmdIndexRecord -Dependencies $Dependencies -Kind global -Name $name `
      -ConfigurationPath $configuration.FullName -DatabasePath $databasePath
    if (-not $pairedDatabases.Add($record.DatabasePath)) {
      throw (New-QmdException -Message (
        "Multiple global configurations resolve to '$($record.DatabasePath)'."
      ))
    }
    $indexes.Add($record)
  }

  foreach ($database in $databases) {
    $canonical = Get-CanonicalExistingPath -LiteralPath $database.FullName -PathType File
    if (-not $pairedDatabases.Contains($canonical)) {
      throw (New-QmdException -Message "Orphan global QMD database: '$canonical'.")
    }
  }

  $indexes.ToArray()
}

function Get-QmdLocalIndexes {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [AllowEmptyCollection()]
    [string[]]$ScanRoots = @()
  )

  $canonicalRoots = [System.Collections.Generic.List[string]]::new()
  $seenRoots = [System.Collections.Generic.HashSet[string]]::new($script:PathComparer)
  foreach ($root in $ScanRoots) {
    $canonical = Get-CanonicalExistingPath -LiteralPath $root -PathType Directory
    if ($seenRoots.Add($canonical)) {
      $canonicalRoots.Add($canonical)
    }
  }

  if ($canonicalRoots.Count -eq 0) {
    Write-QmdMessage -Level 'WARN' -Message (
      'No --scan-root was provided; only global QMD indexes will be searched.'
    )
    return [pscustomobject]@{
      Roots = @()
      Indexes = @()
    }
  }

  $indexes = [System.Collections.Generic.List[object]]::new()
  $seenDatabases = [System.Collections.Generic.HashSet[string]]::new($script:PathComparer)
  foreach ($root in $canonicalRoots) {
    Write-QmdItem -Label 'Local scan root' -Path $root
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($root)

    while ($pending.Count -gt 0) {
      $directoryPath = $pending.Pop()
      try {
        $children = @(Get-ChildItem -LiteralPath $directoryPath -Directory -Force `
            -ErrorAction Stop)
      }
      catch {
        throw (New-QmdException -Message (
          "Local-index scan cannot read '$directoryPath': $($_.Exception.Message)"
        ))
      }

      foreach ($child in $children) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          Write-QmdMessage -Level 'WARN' -Message (
            "Skipping reparse point during local-index scan: '$($child.FullName)'."
          )
          continue
        }

        if ($child.Name -cne '.qmd') {
          $pending.Push($child.FullName)
          continue
        }

        $ymlPath = Join-Path $child.FullName 'index.yml'
        $yamlPath = Join-Path $child.FullName 'index.yaml'
        $databasePath = Join-Path $child.FullName 'index.sqlite'
        $configs = @(
          foreach ($candidate in @($ymlPath, $yamlPath)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
              $candidate
            }
          }
        )
        $databaseExists = Test-Path -LiteralPath $databasePath -PathType Leaf

        if ($configs.Count -eq 0 -and -not $databaseExists) {
          continue
        }
        if ($configs.Count -ne 1 -or -not $databaseExists) {
          throw (New-QmdException -Message (
            "Incomplete or ambiguous local QMD index: '$($child.FullName)'."
          ))
        }

        $record = New-QmdIndexRecord -Dependencies $Dependencies -Kind local -Name index `
          -ConfigurationPath $configs[0] -DatabasePath $databasePath
        if ($seenDatabases.Add($record.DatabasePath)) {
          $indexes.Add($record)
        }
      }
    }
  }

  [pscustomobject]@{
    Roots = $canonicalRoots.ToArray()
    Indexes = $indexes.ToArray()
  }
}

function Get-AllQmdIndexes {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [pscustomobject]$ResolvedPaths,

    [AllowEmptyCollection()]
    [string[]]$ScanRoots = @()
  )

  $global = @(Get-QmdGlobalIndexes -Dependencies $Dependencies -ResolvedPaths $ResolvedPaths)
  $localResult = Get-QmdLocalIndexes -Dependencies $Dependencies -ScanRoots $ScanRoots
  $all = [System.Collections.Generic.List[object]]::new()
  $seenDatabasePaths = [System.Collections.Generic.HashSet[string]]::new($script:PathComparer)

  foreach ($index in @($global) + @($localResult.Indexes)) {
    if (-not $seenDatabasePaths.Add($index.DatabasePath)) {
      throw (New-QmdException -Message (
        "The same SQLite database is associated with multiple QMD indexes: " +
        "'$($index.DatabasePath)'."
      ))
    }
    $all.Add($index)
    Write-QmdItem -Label 'Collection configuration' -Path $index.ConfigurationPath
    Write-QmdItem -Label 'Index database' -Path $index.DatabasePath
  }

  if ($all.Count -eq 0) {
    throw (New-QmdException -Message 'No complete QMD index was detected.')
  }

  [pscustomobject]@{
    ScanRoots = @($localResult.Roots)
    Indexes = @($all.ToArray() | Sort-Object -Property Kind, Name, ConfigurationPath)
  }
}

function Get-QmdManagedMcpState {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$ResolvedPaths
  )

  $pidPath = Join-Path $ResolvedPaths.CacheDirectory 'mcp.pid'
  if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
    return [pscustomobject]@{
      WasRunning = $false
      IsStale = $false
      ProcessId = $null
      Port = $null
      IndexName = $null
      PidPath = $pidPath
      Restorable = $true
    }
  }

  $pidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction Stop).Trim()
  $processId = 0
  if (-not [int]::TryParse($pidText, [ref]$processId) -or $processId -lt 1) {
    return [pscustomobject]@{
      WasRunning = $false
      IsStale = $true
      ProcessId = $null
      Port = $null
      IndexName = $null
      PidPath = $pidPath
      Restorable = $true
    }
  }

  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return [pscustomobject]@{
      WasRunning = $false
      IsStale = $true
      ProcessId = $processId
      Port = $null
      IndexName = $null
      PidPath = $pidPath
      Restorable = $true
    }
  }

  $commandLine = $null
  try {
    $processRecord = Get-CimInstance -ClassName Win32_Process `
      -Filter "ProcessId = $processId" -ErrorAction Stop
    $commandLine = [string]$processRecord.CommandLine
  }
  catch {
    $commandLine = $null
  }

  $port = 8181
  $indexName = $null
  $restorable = -not [string]::IsNullOrWhiteSpace($commandLine)
  if ($restorable -and $commandLine -match '(?i)--port(?:=|\s+)(\d+)') {
    $port = [int]$Matches[1]
  }
  if ($restorable -and $commandLine -match '(?i)--index(?:=|\s+)(?:"([^"]+)"|(\S+))') {
    $indexName = if (-not [string]::IsNullOrWhiteSpace($Matches[1])) {
      $Matches[1]
    }
    else {
      $Matches[2]
    }
  }
  if ($restorable -and $commandLine -notmatch '(?i)\bmcp\b.*--http') {
    $restorable = $false
  }

  [pscustomobject]@{
    WasRunning = $true
    IsStale = $false
    ProcessId = $processId
    Port = $port
    IndexName = $indexName
    PidPath = $pidPath
    Restorable = $restorable
  }
}

function Get-QmdIncompatibleProcesses {
  param(
    [Nullable[int]]$ManagedProcessId
  )

  $processes = [System.Collections.Generic.List[object]]::new()
  try {
    $records = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  }
  catch {
    throw (New-QmdException -Message (
      "QMD process detection failed: $($_.Exception.Message)"
    ))
  }

  foreach ($record in $records) {
    if ($null -ne $ManagedProcessId -and [int]$record.ProcessId -eq [int]$ManagedProcessId) {
      continue
    }
    $commandLine = [string]$record.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
      continue
    }
    $isQmd = (
      $commandLine -match '(?i)@tobilu[\\/]+qmd[\\/]+(?:bin[\\/]+qmd|dist[\\/]+cli[\\/]+qmd\.js)' -or
      $commandLine -match (
        '(?i)(?:^|[\s"])(?:[A-Z]:\\[^"\r\n]*\\)?' +
        'qmd\.(?:cmd|ps1|exe)(?=$|[\s"])'
      )
    )
    if (-not $isQmd) {
      continue
    }

    $operation = if (
      $commandLine -match '(?i)\b(update|embed|query|search|vsearch|cleanup|mcp)\b'
    ) {
      $Matches[1].ToLowerInvariant()
    }
    else {
      'unknown'
    }
    $processes.Add([pscustomobject]@{
        ProcessId = [int]$record.ProcessId
        Name = [string]$record.Name
        Operation = $operation
      })
  }

  $processes.ToArray()
}

function Stop-QmdManagedMcp {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [pscustomobject]$McpState
  )

  if (-not $McpState.WasRunning) {
    return
  }
  if (-not $McpState.Restorable) {
    throw (New-QmdException -Message (
      "Managed QMD MCP process $($McpState.ProcessId) cannot be restarted exactly."
    ))
  }

  Write-QmdMessage -Level 'INFO' -Message (
    "Stopping managed QMD MCP server | PID $($McpState.ProcessId)"
  )
  $result = Invoke-QmdExternalCommand -FilePath $Dependencies.QmdPath `
    -ArgumentList @('mcp', 'stop')
  if ($result.ExitCode -ne 0) {
    throw (New-QmdException -Message (
      "QMD MCP stop failed: $($result.Text)"
    ) -ReturnCode 3)
  }

  $remaining = Get-Process -Id $McpState.ProcessId -ErrorAction SilentlyContinue
  if ($null -ne $remaining) {
    throw (New-QmdException -Message (
      "QMD MCP process $($McpState.ProcessId) is still running after a graceful stop."
    ) -ReturnCode 3)
  }
}

function Start-QmdManagedMcp {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [pscustomobject]$McpState
  )

  if (-not $McpState.WasRunning) {
    return $true
  }

  if (Test-Path -LiteralPath $McpState.PidPath -PathType Leaf) {
    $currentPidText = (Get-Content -LiteralPath $McpState.PidPath -Raw `
        -ErrorAction SilentlyContinue).Trim()
    $currentPid = 0
    if (
      [int]::TryParse($currentPidText, [ref]$currentPid) -and
      $null -ne (Get-Process -Id $currentPid -ErrorAction SilentlyContinue)
    ) {
      try {
        $currentProcess = Get-CimInstance -ClassName Win32_Process `
          -Filter "ProcessId = $currentPid" -ErrorAction Stop
        $currentCommandLine = [string]$currentProcess.CommandLine
        $portMatches = $currentCommandLine -match (
          "(?i)--port(?:=|\s+)$([regex]::Escape([string]$McpState.Port))(?:\s|$)"
        )
        $indexMatches = if ([string]::IsNullOrWhiteSpace($McpState.IndexName)) {
          $currentCommandLine -notmatch '(?i)--index(?:=|\s+)'
        }
        else {
          $currentCommandLine -match (
            "(?i)--index(?:=|\s+)(?:`"$([regex]::Escape($McpState.IndexName))`"|" +
            "$([regex]::Escape($McpState.IndexName)))(?:\s|$)"
          )
        }
        if (
          $currentCommandLine -match '(?i)\bmcp\b.*--http' -and
          $portMatches -and
          $indexMatches
        ) {
          Write-QmdMessage -Level 'INFO' -Message (
            "Managed QMD MCP server remained active | PID $currentPid"
          )
          return $true
        }
      }
      catch {
        Write-QmdMessage -Level 'ERROR' -Message (
          "Existing QMD MCP state cannot be verified: $($_.Exception.Message)"
        )
        return $false
      }

      Write-QmdMessage -Level 'ERROR' -Message (
        "A different process is using the QMD MCP PID file | PID $currentPid"
      )
      return $false
    }
  }

  $arguments = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($McpState.IndexName)) {
    $arguments.Add('--index')
    $arguments.Add($McpState.IndexName)
  }
  $arguments.Add('mcp')
  $arguments.Add('--http')
  $arguments.Add('--daemon')
  $arguments.Add('--port')
  $arguments.Add([string]$McpState.Port)

  Write-QmdMessage -Level 'INFO' -Message (
    "Restarting managed QMD MCP server | port $($McpState.Port)"
  )
  $result = Invoke-QmdExternalCommand -FilePath $Dependencies.QmdPath `
    -ArgumentList $arguments.ToArray()
  if ($result.ExitCode -ne 0) {
    Write-QmdMessage -Level 'ERROR' -Message "QMD MCP restart failed: $($result.Text)"
    return $false
  }

  $pidPath = $McpState.PidPath
  if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
    Write-QmdMessage -Level 'ERROR' -Message 'QMD MCP restart did not create its PID file.'
    return $false
  }
  $newPidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
  $newPid = 0
  if (
    -not [int]::TryParse($newPidText, [ref]$newPid) -or
    $null -eq (Get-Process -Id $newPid -ErrorAction SilentlyContinue)
  ) {
    Write-QmdMessage -Level 'ERROR' -Message 'QMD MCP restart could not be verified.'
    return $false
  }

  Write-QmdMessage -Level 'INFO' -Message "Managed QMD MCP server restarted | PID $newPid"
  $true
}

function Assert-NoQmdIncompatibleProcess {
  param(
    [Nullable[int]]$ManagedProcessId
  )

  $processes = @(Get-QmdIncompatibleProcesses -ManagedProcessId $ManagedProcessId)
  if ($processes.Count -eq 0) {
    return
  }

  foreach ($process in $processes) {
    Write-QmdMessage -Level 'ERROR' -Message (
      "Incompatible QMD process | PID=$($process.ProcessId) " +
      "NAME=$($process.Name) OPERATION=$($process.Operation)"
    )
  }
  throw (New-QmdException -Message (
    'One or more unmanaged QMD processes may use or modify an index.'
  ) -ReturnCode 3)
}

function Test-ReservedWindowsName {
  param(
    [Parameter(Mandatory)]
    [string]$Component
  )

  $baseName = ($Component.TrimEnd('.', ' ') -split '\.')[0]
  $baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
}

function Assert-SafeArchivePath {
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [switch]$AllowDirectory
  )

  if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    throw (New-QmdException -Message 'A ZIP entry has an empty path.')
  }
  if ($ArchivePath.Contains('\') -or $ArchivePath.Contains(':')) {
    throw (New-QmdException -Message "Unsafe ZIP entry path: '$ArchivePath'.")
  }
  if ($ArchivePath.StartsWith('/') -or $ArchivePath.StartsWith('//')) {
    throw (New-QmdException -Message "Absolute ZIP entry path is forbidden: '$ArchivePath'.")
  }

  $isDirectory = $ArchivePath.EndsWith('/')
  if ($isDirectory -and -not $AllowDirectory) {
    throw (New-QmdException -Message "Unexpected ZIP directory entry: '$ArchivePath'.")
  }
  $trimmed = $ArchivePath.TrimEnd('/')
  $components = @($trimmed.Split('/', [System.StringSplitOptions]::None))
  foreach ($component in $components) {
    if (
      [string]::IsNullOrWhiteSpace($component) -or
      $component -eq '.' -or
      $component -eq '..' -or
      $component.EndsWith('.') -or
      $component.EndsWith(' ') -or
      (Test-ReservedWindowsName -Component $component)
    ) {
      throw (New-QmdException -Message "Unsafe ZIP entry path: '$ArchivePath'.")
    }
  }
}

function ConvertTo-QmdArchivePath {
  param(
    [Parameter(Mandatory)]
    [string]$RelativePath
  )

  $archivePath = $RelativePath.Replace('\', '/').TrimStart('/')
  Assert-SafeArchivePath -ArchivePath $archivePath
  $archivePath
}

function Assert-SafeWindowsTargetPath {
  param(
    [Parameter(Mandatory)]
    [string]$TargetPath
  )

  if (-not [System.IO.Path]::IsPathFullyQualified($TargetPath)) {
    throw (New-QmdException -Message "Restore target is not an absolute Windows path: '$TargetPath'.")
  }
  if ($TargetPath.StartsWith('\\?\') -or $TargetPath.StartsWith('\\.\')) {
    throw (New-QmdException -Message "Device paths are forbidden restore targets: '$TargetPath'.")
  }

  $fullPath = Get-CanonicalTargetPath -LiteralPath $TargetPath
  $withoutDrive = if ($fullPath -match '^[A-Za-z]:') {
    $fullPath.Substring(2)
  }
  else {
    $fullPath
  }
  if ($withoutDrive.Contains(':')) {
    throw (New-QmdException -Message "Alternate data streams are forbidden: '$TargetPath'.")
  }
  foreach ($component in @($withoutDrive.Trim('\').Split('\'))) {
    if (
      [string]::IsNullOrWhiteSpace($component) -or
      $component -eq '..' -or
      $component.EndsWith('.') -or
      $component.EndsWith(' ') -or
      (Test-ReservedWindowsName -Component $component)
    ) {
      throw (New-QmdException -Message "Unsafe restore target path: '$TargetPath'.")
    }
  }
  $fullPath
}

function Get-RelativePathWithinRoot {
  param(
    [Parameter(Mandatory)]
    [string]$RootPath,

    [Parameter(Mandatory)]
    [string]$TargetPath
  )

  $root = Get-CanonicalExistingPath -LiteralPath $RootPath -PathType Directory
  $target = Get-CanonicalExistingPath -LiteralPath $TargetPath -PathType File
  $pathComparison = if ($IsWindows) {
    [System.StringComparison]::OrdinalIgnoreCase
  }
  else {
    [System.StringComparison]::Ordinal
  }
  $pathSeparators = [char[]]@(
    [System.IO.Path]::DirectorySeparatorChar
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $rootPrefix = $root.TrimEnd($pathSeparators) +
    [System.IO.Path]::DirectorySeparatorChar
  if (
    -not (Test-PathEqual -Left $target -Right $root) -and
    -not $target.StartsWith($rootPrefix, $pathComparison)
  ) {
    throw (New-QmdException -Message (
      "Indexed path escapes its collection root: '$TargetPath'."
    ))
  }
  $relative = [System.IO.Path]::GetRelativePath($root, $target)
  ConvertTo-QmdArchivePath -RelativePath $relative
}

function Get-QmdCollectionPhysicalFiles {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [string]$CollectionRoot,

    [Parameter(Mandatory)]
    [string]$CollectionPattern,

    [AllowNull()]
    [string]$IgnorePatterns
  )

  $root = Get-CanonicalExistingPath -LiteralPath $CollectionRoot -PathType Directory
  if ([string]::IsNullOrWhiteSpace($CollectionPattern)) {
    throw (New-QmdException -Message (
      "QMD collection has no valid file pattern: '$root'."
    ))
  }

  $storeModulePath = Join-Path $Dependencies.QmdPackageRoot 'dist\store.js'
  $storeModule = Get-CanonicalExistingPath -LiteralPath $storeModulePath -PathType File
  $ignoreJson = if ([string]::IsNullOrWhiteSpace($IgnorePatterns)) {
    ''
  }
  else {
    $IgnorePatterns
  }
  $program = @'
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const [storePath, root, pattern, ignoreJson] = process.argv.slice(1);
const storeUrl = pathToFileURL(storePath).href;
const require = createRequire(storeUrl);
const fastGlobModule = require("fast-glob");
const fastGlob = fastGlobModule.default || fastGlobModule;
const { handelize } = await import(storeUrl);
const customIgnore = ignoreJson === "" ? [] : JSON.parse(ignoreJson);
if (!Array.isArray(customIgnore) || customIgnore.some((value) => typeof value !== "string")) {
  throw new Error("collection ignore patterns must be a JSON string array");
}
const ignore = [
  "**/node_modules/**",
  "**/.git/**",
  "**/.cache/**",
  "**/vendor/**",
  "**/dist/**",
  "**/build/**",
  ...customIgnore
];
const files = await fastGlob(pattern, {
  cwd: root,
  onlyFiles: true,
  followSymbolicLinks: false,
  dot: false,
  ignore
});
const result = [];
for (const physicalRelativePath of files) {
  if (physicalRelativePath.split("/").some((part) => part.startsWith("."))) {
    continue;
  }
  result.push({
    logicalPath: handelize(physicalRelativePath),
    physicalRelativePath
  });
}
process.stdout.write(JSON.stringify({ files: result }));
'@

  $result = Invoke-QmdExternalCommand -FilePath $Dependencies.NodePath -ArgumentList @(
    '--input-type=module'
    '-e'
    $program
    $storeModule
    $root
    $CollectionPattern
    $ignoreJson
  )
  if ($result.ExitCode -ne 0) {
    throw (New-QmdException -Message (
      "QMD collection files cannot be resolved for '$root': $($result.Text)"
    ))
  }

  try {
    $payload = $result.Text | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw (New-QmdException -Message (
      "QMD collection file resolution returned invalid JSON for '$root'."
    ))
  }
  @($payload.files | Sort-Object logicalPath, physicalRelativePath)
}

function Resolve-QmdIndexedFile {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Document,

    [AllowEmptyCollection()]
    [object[]]$PhysicalFiles = @()
  )

  $relativePath = [string]$Document.relativePath
  if (
    [string]::IsNullOrWhiteSpace($relativePath) -or
    [System.IO.Path]::IsPathFullyQualified($relativePath)
  ) {
    throw (New-QmdException -Message (
      "QMD index contains an invalid relative document path: '$relativePath'."
    ))
  }
  $normalizedLogicalPath = $relativePath.Replace('\', '/')
  if (@($normalizedLogicalPath.Split('/')) -contains '..') {
    throw (New-QmdException -Message (
      "QMD index contains a parent traversal path: '$relativePath'."
    ))
  }

  $physicalFileMatches = @(
    $PhysicalFiles | Where-Object {
      [string]::Equals(
        [string]$_.logicalPath,
        $normalizedLogicalPath,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    }
  )
  if ($physicalFileMatches.Count -eq 0) {
    throw (New-QmdException -Message (
      "Active QMD document has no matching physical file after QMD path normalization: " +
      "collection '$($Document.collectionName)', logical path '$relativePath'."
    ))
  }
  if ($physicalFileMatches.Count -gt 1) {
    $candidates = @($physicalFileMatches.physicalRelativePath | Sort-Object) -join "', '"
    throw (New-QmdException -Message (
      "Active QMD document path is ambiguous after QMD path normalization: " +
      "collection '$($Document.collectionName)', logical path '$relativePath', " +
      "physical candidates '$candidates'."
    ))
  }

  $physicalRelativePath = [string]$physicalFileMatches[0].physicalRelativePath
  if (
    [string]::IsNullOrWhiteSpace($physicalRelativePath) -or
    [System.IO.Path]::IsPathFullyQualified($physicalRelativePath)
  ) {
    throw (New-QmdException -Message (
      "QMD resolved an invalid physical relative path: '$physicalRelativePath'."
    ))
  }
  $normalizedPhysicalPath = $physicalRelativePath.Replace('/', '\')
  if (@($normalizedPhysicalPath.Split('\')) -contains '..') {
    throw (New-QmdException -Message (
      "QMD resolved a parent traversal path: '$physicalRelativePath'."
    ))
  }

  $root = Get-CanonicalExistingPath -LiteralPath ([string]$Document.collectionRoot) `
    -PathType Directory
  $candidate = Join-Path $root $normalizedPhysicalPath
  $canonical = Get-CanonicalExistingPath -LiteralPath $candidate -PathType File
  $null = Get-RelativePathWithinRoot -RootPath $root -TargetPath $canonical
  $null = Test-NormalFile -LiteralPath $canonical
  $canonical
}

function Get-QmdRequiredModelReferences {
  param(
    [Parameter(Mandatory)]
    [object[]]$Indexes
  )

  $environmentMap = @{
    embed = [Environment]::GetEnvironmentVariable('QMD_EMBED_MODEL', 'Process')
    generate = [Environment]::GetEnvironmentVariable('QMD_GENERATE_MODEL', 'Process')
    rerank = [Environment]::GetEnvironmentVariable('QMD_RERANK_MODEL', 'Process')
  }
  $references = [System.Collections.Generic.List[object]]::new()

  foreach ($index in $Indexes) {
    foreach ($role in @('embed', 'generate', 'rerank')) {
      $configured = $index.Configuration.models.$role
      $reference = if (-not [string]::IsNullOrWhiteSpace([string]$configured)) {
        [string]$configured
      }
      elseif (-not [string]::IsNullOrWhiteSpace([string]$environmentMap[$role])) {
        [string]$environmentMap[$role]
      }
      else {
        [string]$script:DefaultModelReferences[$role]
      }
      $references.Add([pscustomobject]@{
          IndexId = $index.Id
          Role = $role
          Reference = $reference
        })
    }
  }
  $references.ToArray()
}

function Get-QmdModelFiles {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$ResolvedPaths,

    [Parameter(Mandatory)]
    [object[]]$RequiredReferences
  )

  $cacheFiles = [System.Collections.Generic.List[object]]::new()
  if (Test-Path -LiteralPath $ResolvedPaths.ModelDirectory -PathType Container) {
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($ResolvedPaths.ModelDirectory)
    while ($pending.Count -gt 0) {
      $directory = $pending.Pop()
      foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
          throw (New-QmdException -Message (
            "Reparse point found in the QMD model cache: '$($entry.FullName)'."
          ))
        }
        if ($entry.PSIsContainer) {
          $pending.Push($entry.FullName)
        }
        else {
          $relative = [System.IO.Path]::GetRelativePath(
            $ResolvedPaths.ModelDirectory,
            $entry.FullName
          )
          $cacheFiles.Add([pscustomobject]@{
              SourcePath = Get-CanonicalExistingPath -LiteralPath $entry.FullName -PathType File
              ArchivePath = ConvertTo-QmdArchivePath -RelativePath (
                "models/cache/$relative"
              )
              References = [System.Collections.Generic.List[object]]::new()
            })
        }
      }
    }
  }

  $externalFiles = [System.Collections.Generic.List[object]]::new()
  foreach ($required in $RequiredReferences) {
    $reference = [string]$required.Reference
    if ($reference.StartsWith('hf:', [System.StringComparison]::OrdinalIgnoreCase)) {
      $fileName = ($reference -split '/')[-1]
      $cacheFileMatches = @($cacheFiles | Where-Object {
          [System.IO.Path]::GetFileName($_.SourcePath).Contains(
            $fileName,
            [System.StringComparison]::OrdinalIgnoreCase
          )
        })
      if ($cacheFileMatches.Count -eq 0) {
        throw (New-QmdException -Message (
          "Required Hugging Face model is not available offline: '$reference'."
        ))
      }
      foreach ($match in $cacheFileMatches) {
        $match.References.Add([ordered]@{
            indexId = $required.IndexId
            role = $required.Role
            reference = $reference
          })
      }
      continue
    }

    if (-not [System.IO.Path]::IsPathFullyQualified($reference)) {
      throw (New-QmdException -Message (
        "Required model reference is neither hf: nor an absolute local path: '$reference'."
      ))
    }
    $canonical = Get-CanonicalExistingPath -LiteralPath $reference -PathType File
    $existing = @($externalFiles | Where-Object {
        Test-PathEqual -Left $_.SourcePath -Right $canonical
      })
    if ($existing.Count -eq 0) {
      $identifier = Get-DeterministicIdentifier -Prefix 'model' -Value $canonical
      $record = [pscustomobject]@{
        SourcePath = $canonical
        ArchivePath = ConvertTo-QmdArchivePath -RelativePath (
          "models/external/$identifier/$([System.IO.Path]::GetFileName($canonical))"
        )
        References = [System.Collections.Generic.List[object]]::new()
      }
      $externalFiles.Add($record)
      $existing = @($record)
    }
    $existing[0].References.Add([ordered]@{
        indexId = $required.IndexId
        role = $required.Role
        reference = $reference
      })
  }

  @($cacheFiles.ToArray()) + @($externalFiles.ToArray())
}

function New-QmdArchivedFileRecord {
  param(
    [Parameter(Mandatory)]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [Parameter(Mandatory)]
    [pscustomobject]$Metadata,

    [AllowEmptyCollection()]
    [object[]]$References = @()
  )

  [ordered]@{
    kind = $Kind
    sourcePath = $SourcePath
    archivePath = $ArchivePath
    size = [int64]$Metadata.Size
    lastWriteTimeUtc = [string]$Metadata.LastWriteTimeUtc
    sha256 = [string]$Metadata.Sha256
    references = @($References)
  }
}

function Add-QmdBackupFile {
  param(
    [Parameter(Mandatory)]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [Parameter(Mandatory)]
    [string]$StagingPath,

    [AllowEmptyCollection()]
    [object[]]$References = @()
  )

  $safeArchivePath = ConvertTo-QmdArchivePath -RelativePath $ArchivePath
  $destination = Join-Path $StagingPath $safeArchivePath.Replace('/', '\')
  $metadata = Copy-StableFile -SourcePath $SourcePath -DestinationPath $destination
  New-QmdArchivedFileRecord -Kind $Kind -SourcePath $SourcePath `
    -ArchivePath $safeArchivePath -Metadata $metadata -References $References
}

function Get-QmdSourceInventory {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies,

    [Parameter(Mandatory)]
    [object[]]$Indexes,

    [Parameter(Mandatory)]
    [bool]$IncludeData,

    [Parameter(Mandatory)]
    [bool]$IncludeModels,

    [Parameter(Mandatory)]
    [pscustomobject]$ResolvedPaths
  )

  $dataFiles = [System.Collections.Generic.List[object]]::new()
  $dataByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
    $script:PathComparer
  )
  $collections = [System.Collections.Generic.List[object]]::new()
  $resolutionIssues = [System.Collections.Generic.List[object]]::new()

  foreach ($index in $Indexes) {
    $databaseCollections = @(Get-QmdDatabaseCollections -Dependencies $Dependencies `
        -DatabasePath $index.DatabasePath)
    foreach ($collection in $databaseCollections) {
      $collections.Add([ordered]@{
          indexId = $index.Id
          name = [string]$collection.name
          sourceRootPath = [string]$collection.path
          pattern = [string]$collection.pattern
        })
    }

    if (-not $IncludeData) {
      continue
    }

    $documents = @(Get-QmdIndexedDocuments -Dependencies $Dependencies `
        -DatabasePath $index.DatabasePath)
    $documentGroups = @($documents | Group-Object -Property collectionName)
    foreach ($documentGroup in $documentGroups) {
      $groupDocuments = @($documentGroup.Group)
      $representative = $groupDocuments[0]
      try {
        $physicalFiles = @(Get-QmdCollectionPhysicalFiles -Dependencies $Dependencies `
            -CollectionRoot ([string]$representative.collectionRoot) `
            -CollectionPattern ([string]$representative.collectionPattern) `
            -IgnorePatterns ([string]$representative.collectionIgnorePatterns))
      }
      catch {
        $collectionError = $_.Exception.Message
        foreach ($document in $groupDocuments) {
          $resolutionIssues.Add([pscustomobject]@{
              IndexId = [string]$index.Id
              IndexName = [string]$index.Name
              CollectionName = [string]$document.collectionName
              LogicalPath = [string]$document.relativePath
              Message = $collectionError
            })
        }
        continue
      }

      foreach ($document in $groupDocuments) {
        try {
          $sourcePath = Resolve-QmdIndexedFile -Document $document `
            -PhysicalFiles $physicalFiles
        }
        catch {
          $resolutionIssues.Add([pscustomobject]@{
              IndexId = [string]$index.Id
              IndexName = [string]$index.Name
              CollectionName = [string]$document.collectionName
              LogicalPath = [string]$document.relativePath
              Message = $_.Exception.Message
            })
          continue
        }

        $reference = [ordered]@{
          indexId = $index.Id
          collectionName = [string]$document.collectionName
          relativePath = [string]$document.relativePath
        }
        if ($dataByPath.ContainsKey($sourcePath)) {
          $dataByPath[$sourcePath].References.Add($reference)
          continue
        }

        $collectionKey = (
          "$($index.Id)|$($document.collectionName)|$($document.collectionRoot)"
        )
        $collectionId = Get-DeterministicIdentifier -Prefix 'collection' `
          -Value $collectionKey
        $relative = Get-RelativePathWithinRoot -RootPath ([string]$document.collectionRoot) `
          -TargetPath $sourcePath
        $record = [pscustomobject]@{
          SourcePath = $sourcePath
          ArchivePath = ConvertTo-QmdArchivePath -RelativePath (
            "datas/$collectionId/$relative"
          )
          References = [System.Collections.Generic.List[object]]::new()
        }
        $record.References.Add($reference)
        $dataByPath.Add($sourcePath, $record)
        $dataFiles.Add($record)
      }
    }
  }

  if ($resolutionIssues.Count -gt 0) {
    $sortedIssues = @(
      $resolutionIssues.ToArray() |
        Sort-Object IndexName, CollectionName, LogicalPath, Message
    )
    foreach ($issue in $sortedIssues) {
      Write-QmdMessage -Level 'ERROR' -Message (
        "Indexed file resolution failed | index=$($issue.IndexName) " +
        "collection=$($issue.CollectionName) logical-path=$($issue.LogicalPath) | " +
        $issue.Message
      )
    }
    throw (New-QmdException -Message (
      "$($sortedIssues.Count) active indexed file(s) could not be resolved safely. " +
      "Run 'qmd update' if source moves or deletions were intentional; otherwise " +
      'restore the source files before retrying the backup.'
    ))
  }

  $modelFiles = @()
  $requiredModels = @()
  if ($IncludeModels) {
    $requiredModels = @(Get-QmdRequiredModelReferences -Indexes $Indexes)
    $modelFiles = @(Get-QmdModelFiles -ResolvedPaths $ResolvedPaths `
        -RequiredReferences $requiredModels)
  }

  [pscustomobject]@{
    Collections = @($collections.ToArray() | Sort-Object indexId, name)
    DataFiles = @($dataFiles.ToArray() | Sort-Object SourcePath)
    RequiredModels = @($requiredModels | Sort-Object IndexId, Role, Reference)
    ModelFiles = @($modelFiles | Sort-Object SourcePath)
  }
}

function Assert-QmdFreeSpace {
  param(
    [Parameter(Mandatory)]
    [string]$DirectoryPath,

    [Parameter(Mandatory)]
    [int64]$RequiredBytes,

    [Parameter(Mandatory)]
    [string]$Purpose
  )

  try {
    $root = [System.IO.Path]::GetPathRoot($DirectoryPath)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
      Write-QmdMessage -Level 'WARN' -Message (
        "Free-space verification is unavailable for $Purpose at '$DirectoryPath'."
      )
      return
    }
    $drive = [System.IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) {
      throw [System.IO.IOException]::new("Drive '$root' is not ready.")
    }
    if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
      throw (New-QmdException -Message (
        "Insufficient free space for $Purpose. Required=$RequiredBytes " +
        "available=$($drive.AvailableFreeSpace)."
      ))
    }
    Write-QmdMessage -Level 'DEBUG' -Message (
      "Free space verified for $Purpose | required=$RequiredBytes " +
      "available=$($drive.AvailableFreeSpace)"
    )
  }
  catch {
    if ($_.Exception.Data.Contains('QmdReturnCode')) {
      throw
    }
    throw (New-QmdException -Message (
      "Free-space verification failed for ${Purpose}: $($_.Exception.Message)"
    ))
  }
}

function Remove-QmdOwnedDirectory {
  param(
    [Parameter(Mandatory)]
    [string]$DirectoryPath,

    [Parameter(Mandatory)]
    [string]$ExpectedParent,

    [Parameter(Mandatory)]
    [string]$ExpectedNamePrefix
  )

  if (-not [System.IO.Directory]::Exists($DirectoryPath)) {
    return
  }
  $fullDirectory = [System.IO.Path]::GetFullPath($DirectoryPath)
  $fullParent = [System.IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\') + '\'
  $leafName = [System.IO.Path]::GetFileName($fullDirectory.TrimEnd('\'))
  if (
    -not $fullDirectory.StartsWith($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not $leafName.StartsWith($ExpectedNamePrefix, [System.StringComparison]::Ordinal)
  ) {
    throw (New-QmdException -Message (
      "Refusing to remove an unverified temporary directory: '$fullDirectory'."
    ) -ReturnCode 3)
  }
  [System.IO.Directory]::Delete($fullDirectory, $true)
}

function Get-QmdZipTimestamp {
  param(
    [Parameter(Mandatory)]
    [datetime]$LastWriteTimeUtc
  )

  $minimum = [datetime]::SpecifyKind([datetime]'1980-01-01T00:00:00', 'Utc')
  $maximum = [datetime]::SpecifyKind([datetime]'2107-12-31T23:59:58', 'Utc')
  $value = $LastWriteTimeUtc.ToUniversalTime()
  if ($value -lt $minimum) {
    $value = $minimum
  }
  elseif ($value -gt $maximum) {
    $value = $maximum
  }
  [DateTimeOffset]::new($value)
}

function New-QmdZipFromStaging {
  param(
    [Parameter(Mandatory)]
    [string]$StagingPath,

    [Parameter(Mandatory)]
    [string]$DestinationPath,

    [AllowEmptyCollection()]
    [string[]]$DirectoryEntries = @()
  )

  if (Test-Path -LiteralPath $DestinationPath) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }

  $fileStream = [System.IO.File]::Open(
    $DestinationPath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
  )
  try {
    $zip = [System.IO.Compression.ZipArchive]::new(
      $fileStream,
      [System.IO.Compression.ZipArchiveMode]::Create,
      $true
    )
    try {
      foreach ($directoryEntry in @($DirectoryEntries | Sort-Object -Unique)) {
        $safeDirectory = $directoryEntry.TrimEnd('/') + '/'
        Assert-SafeArchivePath -ArchivePath $safeDirectory -AllowDirectory
        $entry = $zip.CreateEntry(
          $safeDirectory,
          [System.IO.Compression.CompressionLevel]::Optimal
        )
        $entry.LastWriteTime = Get-QmdZipTimestamp -LastWriteTimeUtc ([datetime]::UtcNow)
      }

      $files = @(Get-ChildItem -LiteralPath $StagingPath -File -Recurse -Force |
          Sort-Object -Property FullName)
      foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($StagingPath, $file.FullName)
        $archivePath = ConvertTo-QmdArchivePath -RelativePath $relative
        $entry = $zip.CreateEntry(
          $archivePath,
          [System.IO.Compression.CompressionLevel]::Optimal
        )
        $entry.LastWriteTime = Get-QmdZipTimestamp -LastWriteTimeUtc $file.LastWriteTimeUtc
        $inputStream = [System.IO.File]::Open(
          $file.FullName,
          [System.IO.FileMode]::Open,
          [System.IO.FileAccess]::Read,
          [System.IO.FileShare]::Read
        )
        $output = $entry.Open()
        try {
          $inputStream.CopyTo($output)
        }
        finally {
          $output.Dispose()
          $inputStream.Dispose()
        }
      }
    }
    finally {
      $zip.Dispose()
    }
  }
  finally {
    $fileStream.Dispose()
  }
}

function Get-QmdZipEntrySha256 {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry]$Entry
  )

  $stream = $Entry.Open()
  try {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = $algorithm.ComputeHash($stream)
    }
    finally {
      $algorithm.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
  ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-QmdRequiredManifestProperty {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Object,

    [Parameter(Mandatory)]
    [string]$Name
  )

  if ($Object.PSObject.Properties.Name -cnotcontains $Name) {
    throw (New-QmdException -Message "Archive manifest is missing '$Name'.")
  }
  $Object.$Name
}

function Assert-QmdBackupManifest {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Manifest
  )

  $formatVersion = Get-QmdRequiredManifestProperty -Object $Manifest `
    -Name 'archiveFormatVersion'
  if ([int]$formatVersion -ne $script:ArchiveFormatVersion) {
    throw (New-QmdException -Message (
      "Unsupported archive format version: '$formatVersion'."
    ))
  }
  if ((Get-QmdRequiredManifestProperty -Object $Manifest -Name 'scriptName') -cne
    $script:ScriptName) {
    throw (New-QmdException -Message 'Archive manifest has an unexpected script name.')
  }
  $mode = [string](Get-QmdRequiredManifestProperty -Object $Manifest -Name 'backupMode')
  if ($mode -notin @('INDEX', 'FULL', 'FULL-OFFLINE')) {
    throw (New-QmdException -Message "Archive manifest has an invalid backup mode: '$mode'.")
  }

  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'scriptVersion'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'createdAtUtc'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'qmdVersion'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'sqliteVersion'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'environmentVariables'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'indexes'
  $null = Get-QmdRequiredManifestProperty -Object $Manifest -Name 'collections'
  $files = @(Get-QmdRequiredManifestProperty -Object $Manifest -Name 'files')

  $seenArchivePaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )
  foreach ($file in $files) {
    foreach ($property in @(
        'kind',
        'sourcePath',
        'archivePath',
        'size',
        'lastWriteTimeUtc',
        'sha256',
        'references'
      )) {
      $null = Get-QmdRequiredManifestProperty -Object $file -Name $property
    }
    Assert-SafeArchivePath -ArchivePath ([string]$file.archivePath)
    if (-not $seenArchivePaths.Add([string]$file.archivePath)) {
      throw (New-QmdException -Message (
        "Archive manifest contains a duplicate internal path: '$($file.archivePath)'."
      ))
    }
    $null = Assert-SafeWindowsTargetPath -TargetPath ([string]$file.sourcePath)
    if ([int64]$file.size -lt 0 -or [string]$file.sha256 -notmatch '^[0-9a-f]{64}$') {
      throw (New-QmdException -Message (
        "Archive manifest has invalid file metadata for '$($file.archivePath)'."
      ))
    }
  }

  $dataFiles = @($files | Where-Object { $_.kind -eq 'Indexed collection data' })
  $modelFiles = @($files | Where-Object { $_.kind -eq 'GGUF model' })
  if ($mode -eq 'INDEX' -and ($dataFiles.Count -gt 0 -or $modelFiles.Count -gt 0)) {
    throw (New-QmdException -Message 'INDEX archive contains data or model files.')
  }
  if ($mode -eq 'FULL' -and $modelFiles.Count -gt 0) {
    throw (New-QmdException -Message 'FULL archive contains model files.')
  }
}

function Read-QmdBackupArchive {
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath
  )

  $stream = [System.IO.File]::Open(
    $ArchivePath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try {
    $zip = [System.IO.Compression.ZipArchive]::new(
      $stream,
      [System.IO.Compression.ZipArchiveMode]::Read,
      $true
    )
    try {
      $entries = @($zip.Entries)
      $entryMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
      )
      foreach ($entry in $entries) {
        Assert-SafeArchivePath -ArchivePath $entry.FullName -AllowDirectory
        if ($entryMap.ContainsKey($entry.FullName)) {
          throw (New-QmdException -Message (
            "ZIP contains duplicate case-insensitive path '$($entry.FullName)'."
          ))
        }
        $entryMap.Add($entry.FullName, $entry)
      }

      if (-not $entryMap.ContainsKey('manifest.json')) {
        throw (New-QmdException -Message 'ZIP does not contain manifest.json.')
      }
      $manifestEntry = [System.IO.Compression.ZipArchiveEntry]$entryMap['manifest.json']
      if ($manifestEntry.Length -gt 16MB) {
        throw (New-QmdException -Message 'manifest.json exceeds the supported size limit.')
      }
      $manifestStream = $manifestEntry.Open()
      $reader = [System.IO.StreamReader]::new(
        $manifestStream,
        [System.Text.Encoding]::UTF8,
        $true,
        4096,
        $false
      )
      try {
        $manifestText = $reader.ReadToEnd()
      }
      finally {
        $reader.Dispose()
      }
      try {
        $manifest = $manifestText | ConvertFrom-Json -Depth 30 -ErrorAction Stop
      }
      catch {
        throw (New-QmdException -Message 'manifest.json is not valid JSON.')
      }
      Assert-QmdBackupManifest -Manifest $manifest

      $expected = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
      )
      $null = $expected.Add('manifest.json')
      $null = $expected.Add('index/')
      if ($manifest.backupMode -in @('FULL', 'FULL-OFFLINE')) {
        $null = $expected.Add('datas/')
      }
      if ($manifest.backupMode -eq 'FULL-OFFLINE') {
        $null = $expected.Add('models/')
      }
      foreach ($file in @($manifest.files)) {
        $null = $expected.Add([string]$file.archivePath)
      }

      foreach ($entry in $entries) {
        if (-not $expected.Contains($entry.FullName)) {
          throw (New-QmdException -Message (
            "ZIP contains an unmanifested entry: '$($entry.FullName)'."
          ))
        }
      }
      foreach ($expectedPath in $expected) {
        if (-not $entryMap.ContainsKey($expectedPath)) {
          throw (New-QmdException -Message (
            "ZIP is missing expected entry: '$expectedPath'."
          ))
        }
      }

      foreach ($file in @($manifest.files)) {
        $entry = [System.IO.Compression.ZipArchiveEntry]$entryMap[[string]$file.archivePath]
        if ([int64]$entry.Length -ne [int64]$file.size) {
          throw (New-QmdException -Message (
            "ZIP size mismatch for '$($file.archivePath)'."
          ))
        }
        $hash = Get-QmdZipEntrySha256 -Entry $entry
        if ($hash -cne [string]$file.sha256) {
          throw (New-QmdException -Message (
            "ZIP SHA-256 mismatch for '$($file.archivePath)'."
          ))
        }
      }

      [pscustomobject]@{
        Manifest = $manifest
        EntryNames = @($entries.FullName)
      }
    }
    finally {
      $zip.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Expand-QmdBackupArchive {
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [Parameter(Mandatory)]
    [string]$DestinationPath
  )

  $null = [System.IO.Directory]::CreateDirectory($DestinationPath)
  $destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\') + '\'
  $stream = [System.IO.File]::OpenRead($ArchivePath)
  try {
    $zip = [System.IO.Compression.ZipArchive]::new(
      $stream,
      [System.IO.Compression.ZipArchiveMode]::Read
    )
    try {
      foreach ($entry in $zip.Entries) {
        Assert-SafeArchivePath -ArchivePath $entry.FullName -AllowDirectory
        $relative = $entry.FullName.Replace('/', '\')
        $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
        if (-not $target.StartsWith(
            $destinationRoot,
            [System.StringComparison]::OrdinalIgnoreCase
          )) {
          throw (New-QmdException -Message "ZIP entry escapes staging: '$($entry.FullName)'.")
        }
        if ($entry.FullName.EndsWith('/')) {
          $null = [System.IO.Directory]::CreateDirectory($target)
          continue
        }
        $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $inputStream = $entry.Open()
        $output = [System.IO.File]::Open(
          $target,
          [System.IO.FileMode]::CreateNew,
          [System.IO.FileAccess]::Write,
          [System.IO.FileShare]::None
        )
        try {
          $inputStream.CopyTo($output)
        }
        finally {
          $output.Dispose()
          $inputStream.Dispose()
        }
      }
    }
    finally {
      $zip.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Write-QmdJsonFile {
  param(
    [Parameter(Mandatory)]
    [object]$InputObject,

    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  $json = $InputObject | ConvertTo-Json -Depth 30 -Compress
  [System.IO.File]::WriteAllText(
    $LiteralPath,
    "$json$([Environment]::NewLine)",
    $script:Utf8NoBom
  )
}

function Get-QmdRequiredCapacity {
  param(
    [Parameter(Mandatory)]
    [int64]$BaseBytes,

    [Parameter(Mandatory)]
    [decimal]$Multiplier,

    [int64]$AdditionalBytes = 0
  )

  if ($BaseBytes -lt 0 -or $AdditionalBytes -lt 0 -or $Multiplier -le 0) {
    throw (New-QmdException -Message 'Capacity estimate inputs must be positive.')
  }

  [decimal]$estimate = (
    ([decimal]$BaseBytes * $Multiplier) + [decimal]$AdditionalBytes
  )
  if ($estimate -gt [int64]::MaxValue) {
    throw (New-QmdException -Message 'Capacity estimate exceeds the Int64 limit.')
  }

  [int64]$roundedEstimate = [decimal]::Ceiling($estimate)
  [Math]::Max([int64](64MB), $roundedEstimate)
}

function Get-QmdBackupEstimate {
  param(
    [Parameter(Mandatory)]
    [object[]]$Indexes,

    [Parameter(Mandatory)]
    [pscustomobject]$Inventory
  )

  [int64]$bytes = 0
  foreach ($index in $Indexes) {
    $bytes += (Get-Item -LiteralPath $index.ConfigurationPath).Length
    $bytes += (Get-Item -LiteralPath $index.DatabasePath).Length
  }
  foreach ($file in @($Inventory.DataFiles) + @($Inventory.ModelFiles)) {
    $bytes += (Get-Item -LiteralPath $file.SourcePath).Length
  }
  Get-QmdRequiredCapacity -BaseBytes $bytes -Multiplier 2.25
}

function Show-QmdBackupPlan {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Mode,

    [Parameter(Mandatory)]
    [object[]]$Indexes,

    [Parameter(Mandatory)]
    [pscustomobject]$Inventory,

    [Parameter(Mandatory)]
    [string]$ArchivePath,

    [Parameter(Mandatory)]
    [string]$PartialPath,

    [Parameter(Mandatory)]
    [string]$LogPath,

    [Parameter(Mandatory)]
    [pscustomobject]$McpState
  )

  Write-QmdMessage -Level 'INFO' -Message "Backup mode | $($Mode.Name)"
  foreach ($index in $Indexes) {
    Write-QmdItem -Label 'Collection configuration' -Path $index.ConfigurationPath
    Write-QmdItem -Label 'Index database snapshot' -Path $index.DatabasePath
  }
  foreach ($file in $Inventory.DataFiles) {
    Write-QmdItem -Label 'Indexed collection data' -Path $file.SourcePath
  }
  foreach ($file in $Inventory.ModelFiles) {
    Write-QmdItem -Label 'GGUF models' -Path $file.SourcePath
  }
  Write-QmdItem -Label 'Temporary archive' -Path $PartialPath
  Write-QmdItem -Label 'Final archive' -Path $ArchivePath
  Write-QmdItem -Label 'Log file' -Path $LogPath
  if ($McpState.WasRunning) {
    Write-QmdMessage -Level 'INFO' -Message (
      "Managed QMD MCP server would be stopped and restarted | PID $($McpState.ProcessId)"
    )
  }
  else {
    Write-QmdMessage -Level 'INFO' -Message 'Managed QMD MCP server is not running.'
  }
}

function Invoke-QmdBackupOperation {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Arguments
  )

  $mode = Get-BackupMode -Arguments $Arguments
  $script:CurrentMode = $mode.Name
  $script:VerboseEnabled = [bool]$Arguments.Verbose
  $outputDirectory = Assert-OperationalDirectory -LiteralPath $Arguments.OutputDirectory `
    -Purpose 'Backup output directory'
  $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
  $baseName = "qmd-$($timestamp.Substring(0, 8))-$($timestamp.Substring(9))-$($mode.Suffix)"
  $archivePath = Join-Path $outputDirectory "$baseName.zip"
  $partialPath = Join-Path $outputDirectory "$baseName.partial"
  $logPath = Join-Path $outputDirectory "$baseName.log"

  $collisions = @($archivePath, $partialPath, $logPath | Where-Object {
      Test-Path -LiteralPath $_
    })
  if ($collisions.Count -gt 0) {
    foreach ($collision in $collisions) {
      Write-QmdItem -Label 'Existing output' -Path $collision -Level WARN
    }
    if (-not $Arguments.DryRun) {
      Confirm-QmdAction -Message 'Existing backup outputs will be replaced.' `
        -Force:$Arguments.Force
    }
  }

  if (-not $Arguments.DryRun) {
    Initialize-QmdLog -LiteralPath $logPath
  }

  Write-QmdMessage -Level 'INFO' -Message "Backup mode | $($mode.Name)"
  $dependencies = Get-QmdDependencyContext
  $resolvedPaths = Get-QmdResolvedPaths
  $detected = Get-AllQmdIndexes -Dependencies $dependencies -ResolvedPaths $resolvedPaths `
    -ScanRoots @($Arguments.ScanRoots)
  $environmentState = @(Get-QmdEnvironmentState)
  $inventory = Get-QmdSourceInventory -Dependencies $dependencies -Indexes $detected.Indexes `
    -IncludeData $mode.IncludeData -IncludeModels $mode.IncludeModels `
    -ResolvedPaths $resolvedPaths
  $estimatedBytes = Get-QmdBackupEstimate -Indexes $detected.Indexes -Inventory $inventory
  Assert-QmdFreeSpace -DirectoryPath $outputDirectory -RequiredBytes $estimatedBytes `
    -Purpose 'backup staging and archive'

  $mcpState = Get-QmdManagedMcpState -ResolvedPaths $resolvedPaths
  if ($mcpState.IsStale) {
    Write-QmdMessage -Level 'WARN' -Message (
      "Stale QMD MCP PID file detected without modification: '$($mcpState.PidPath)'."
    )
  }
  if ($mcpState.WasRunning -and -not $mcpState.Restorable) {
    throw (New-QmdException -Message (
      "Managed QMD MCP process $($mcpState.ProcessId) cannot be restarted exactly."
    ))
  }
  $managedId = if ($mcpState.WasRunning) {
    [Nullable[int]]::new([int]$mcpState.ProcessId)
  }
  else {
    $null
  }
  Assert-NoQmdIncompatibleProcess -ManagedProcessId $managedId
  Show-QmdBackupPlan -Mode $mode -Indexes $detected.Indexes -Inventory $inventory `
    -ArchivePath $archivePath -PartialPath $partialPath -LogPath $logPath `
    -McpState $mcpState

  if ($Arguments.DryRun) {
    Write-QmdMessage -Level 'INFO' -Message 'Dry run completed without side effects.'
    return [pscustomobject]@{
      Status = 'COMPLETED'
      ReturnCode = 0
      SourceMode = $null
    }
  }

  $stagingPath = Join-Path $outputDirectory (
    '.qmd-backup-staging-' + [guid]::NewGuid().ToString('N')
  )
  $operationCompleted = $false
  $restartSucceeded = $true
  try {
    $null = [System.IO.Directory]::CreateDirectory($stagingPath)
    Stop-QmdManagedMcp -Dependencies $dependencies -McpState $mcpState
    Assert-NoQmdIncompatibleProcess -ManagedProcessId $null

    $files = [System.Collections.Generic.List[object]]::new()
    $manifestIndexes = [System.Collections.Generic.List[object]]::new()
    $snapshotIndexes = [System.Collections.Generic.List[object]]::new()
    foreach ($index in $detected.Indexes) {
      $configExtension = [System.IO.Path]::GetExtension($index.ConfigurationPath).TrimStart('.')
      $configArchivePath = "index/$($index.Id)/config.$configExtension"
      $configRecord = Add-QmdBackupFile -Kind 'Collection configuration' `
        -SourcePath $index.ConfigurationPath -ArchivePath $configArchivePath `
        -StagingPath $stagingPath -References @([ordered]@{ indexId = $index.Id })
      $files.Add($configRecord)

      $snapshotArchivePath = "index/$($index.Id)/index.sqlite"
      $snapshotPath = Join-Path $stagingPath $snapshotArchivePath.Replace('/', '\')
      $snapshotMetadata = New-QmdSqliteSnapshot -Dependencies $dependencies `
        -SourcePath $index.DatabasePath -DestinationPath $snapshotPath
      $snapshotRecord = New-QmdArchivedFileRecord -Kind 'Index database' `
        -SourcePath $index.DatabasePath -ArchivePath $snapshotArchivePath `
        -Metadata $snapshotMetadata -References @([ordered]@{ indexId = $index.Id })
      $files.Add($snapshotRecord)
      Write-QmdItem -Label 'Index database snapshot' -Path $index.DatabasePath

      $manifestIndexes.Add([ordered]@{
          id = $index.Id
          kind = $index.Kind
          name = $index.Name
          configurationSourcePath = $index.ConfigurationPath
          configurationArchivePath = $configArchivePath
          databaseSourcePath = $index.DatabasePath
          snapshotArchivePath = $snapshotArchivePath
        })
      $snapshotIndexes.Add([pscustomobject]@{
          Kind = $index.Kind
          Name = $index.Name
          Id = $index.Id
          ConfigurationPath = $index.ConfigurationPath
          DatabasePath = $snapshotPath
          Configuration = $index.Configuration
        })
    }

    $snapshotInventory = Get-QmdSourceInventory -Dependencies $dependencies `
      -Indexes $snapshotIndexes.ToArray() -IncludeData $mode.IncludeData `
      -IncludeModels $mode.IncludeModels -ResolvedPaths $resolvedPaths
    foreach ($snapshotIndex in $snapshotIndexes) {
      Remove-QmdOwnedSqliteSidecars -DatabasePath $snapshotIndex.DatabasePath `
        -ExpectedStagingRoot $stagingPath
    }
    foreach ($dataFile in $snapshotInventory.DataFiles) {
      Write-QmdItem -Label 'Indexed collection data' -Path $dataFile.SourcePath
      $record = Add-QmdBackupFile -Kind 'Indexed collection data' `
        -SourcePath $dataFile.SourcePath -ArchivePath $dataFile.ArchivePath `
        -StagingPath $stagingPath -References $dataFile.References.ToArray()
      $files.Add($record)
    }
    foreach ($modelFile in $snapshotInventory.ModelFiles) {
      Write-QmdItem -Label 'GGUF models' -Path $modelFile.SourcePath
      $record = Add-QmdBackupFile -Kind 'GGUF model' `
        -SourcePath $modelFile.SourcePath -ArchivePath $modelFile.ArchivePath `
        -StagingPath $stagingPath -References $modelFile.References.ToArray()
      $files.Add($record)
    }

    $manifest = [ordered]@{
      archiveFormatVersion = $script:ArchiveFormatVersion
      scriptName = $script:ScriptName
      scriptVersion = $script:ScriptVersion
      createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
      backupMode = $mode.Name
      sourceComputerName = [Environment]::MachineName
      sourceOsVersion = [Environment]::OSVersion.VersionString
      sourcePowerShellVersion = [string]$PSVersionTable.PSVersion
      qmdVersion = $dependencies.QmdVersion
      sqliteVersion = $dependencies.SqliteVersion
      environmentVariables = $environmentState
      initialMcpHttpState = [ordered]@{
        wasRunning = [bool]$mcpState.WasRunning
        port = $mcpState.Port
        indexName = $mcpState.IndexName
      }
      scanRoots = @($detected.ScanRoots)
      indexes = @($manifestIndexes.ToArray() | Sort-Object id)
      collections = @($snapshotInventory.Collections)
      requiredModels = @($snapshotInventory.RequiredModels | ForEach-Object {
          [ordered]@{
            indexId = $_.IndexId
            role = $_.Role
            reference = $_.Reference
          }
        })
      files = @($files.ToArray() | Sort-Object { $_.archivePath })
    }
    $manifestPath = Join-Path $stagingPath 'manifest.json'
    Write-QmdJsonFile -InputObject $manifest -LiteralPath $manifestPath

    $directoryEntries = @('index/')
    if ($mode.Name -in @('FULL', 'FULL-OFFLINE')) {
      $directoryEntries += 'datas/'
    }
    if ($mode.Name -eq 'FULL-OFFLINE') {
      $directoryEntries += 'models/'
    }
    New-QmdZipFromStaging -StagingPath $stagingPath -DestinationPath $partialPath `
      -DirectoryEntries $directoryEntries
    $null = Read-QmdBackupArchive -ArchivePath $partialPath
    [System.IO.File]::Move($partialPath, $archivePath, $true)
    Write-QmdItem -Label 'Final archive' -Path $archivePath
    $operationCompleted = $true
  }
  catch {
    $caught = $_
    Write-QmdMessage -Level 'ERROR' -Message $caught.Exception.Message
    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
      Remove-Item -LiteralPath $partialPath -Force
    }
  }
  finally {
    try {
      Remove-QmdOwnedDirectory -DirectoryPath $stagingPath -ExpectedParent $outputDirectory `
        -ExpectedNamePrefix '.qmd-backup-staging-'
    }
    catch {
      Write-QmdMessage -Level 'ERROR' -Message (
        "Backup staging cleanup failed: $($_.Exception.Message)"
      )
      if ($operationCompleted) {
        $restartSucceeded = $false
      }
    }

    if ($mcpState.WasRunning) {
      $restartSucceeded = (Start-QmdManagedMcp -Dependencies $dependencies `
          -McpState $mcpState) -and $restartSucceeded
    }
  }

  if (-not $operationCompleted) {
    return [pscustomobject]@{
      Status = 'FAILED'
      ReturnCode = 3
      SourceMode = $null
    }
  }
  if (-not $restartSucceeded) {
    return [pscustomobject]@{
      Status = 'COMPLETED-WITH-ERRORS'
      ReturnCode = 1
      SourceMode = $null
    }
  }
  [pscustomobject]@{
    Status = 'COMPLETED'
    ReturnCode = 0
    SourceMode = $null
  }
}

function Assert-QmdRestoreCompatibility {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Manifest,

    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies
  )

  if ([string]$Manifest.qmdVersion -cne $Dependencies.QmdVersion) {
    throw (New-QmdException -Message (
      "QMD version mismatch. Archive=$($Manifest.qmdVersion) " +
      "installed=$($Dependencies.QmdVersion). Exact compatibility is required."
    ))
  }

  foreach ($index in @($Manifest.indexes)) {
    foreach ($property in @(
        'id',
        'kind',
        'name',
        'configurationSourcePath',
        'configurationArchivePath',
        'databaseSourcePath',
        'snapshotArchivePath'
      )) {
      $null = Get-QmdRequiredManifestProperty -Object $index -Name $property
    }
  }
}

function Show-QmdEnvironmentDifferences {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Manifest
  )

  foreach ($archived in @($Manifest.environmentVariables)) {
    $name = [string]$archived.name
    $currentValue = [Environment]::GetEnvironmentVariable($name, 'Process')
    $currentDefined = $null -ne $currentValue
    if (
      [bool]$archived.isDefined -ne $currentDefined -or
      ([bool]$archived.isDefined -and [string]$archived.value -cne [string]$currentValue)
    ) {
      $archiveDisplay = if ([bool]$archived.isDefined) {
        [string]$archived.value
      }
      else {
        '<undefined>'
      }
      $currentDisplay = if ($currentDefined) { $currentValue } else { '<undefined>' }
      Write-QmdMessage -Level 'WARN' -Message (
        "Environment difference | $name | archive='$archiveDisplay' current='$currentDisplay'"
      )
    }
  }
}

function Assert-QmdRestoreRootAvailable {
  param(
    [Parameter(Mandatory)]
    [string]$TargetPath
  )

  $root = [System.IO.Path]::GetPathRoot($TargetPath)
  if ([string]::IsNullOrWhiteSpace($root) -or -not [System.IO.Directory]::Exists($root)) {
    throw (New-QmdException -Message (
      "Restore target root is unavailable: '$TargetPath'."
    ))
  }
}

function New-QmdRestorePlanItem {
  param(
    [Parameter(Mandatory)]
    [string]$Kind,

    [Parameter(Mandatory)]
    [string]$TargetPath,

    [Parameter(Mandatory)]
    [ValidateSet('CREATE', 'REPLACE', 'MOVE-TO-ROLLBACK', 'UNCHANGED')]
    [string]$Action,

    [pscustomobject]$ArchivedFile,

    [pscustomobject]$TargetMetadata
  )

  [pscustomobject]@{
    Kind = $Kind
    TargetPath = $TargetPath
    Action = $Action
    ArchivedFile = $ArchivedFile
    TargetMetadata = $TargetMetadata
  }
}

function Format-QmdDateValue {
  param(
    [Parameter(Mandatory)]
    [object]$Value
  )

  if ($Value -is [DateTimeOffset]) {
    return $Value.ToUniversalTime().ToString('o')
  }
  if ($Value -is [datetime]) {
    return $Value.ToUniversalTime().ToString('o')
  }
  [string]$Value
}

function Get-QmdRestorePlan {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Manifest
  )

  $plan = [System.Collections.Generic.List[object]]::new()
  $seenTargets = [System.Collections.Generic.HashSet[string]]::new($script:PathComparer)

  foreach ($file in @($Manifest.files | Sort-Object sourcePath)) {
    $targetPath = Assert-SafeWindowsTargetPath -TargetPath ([string]$file.sourcePath)
    Assert-QmdRestoreRootAvailable -TargetPath $targetPath
    if (-not $seenTargets.Add($targetPath)) {
      throw (New-QmdException -Message (
        "Archive maps multiple files to the same restore target: '$targetPath'."
      ))
    }

    if (Test-Path -LiteralPath $targetPath -PathType Container) {
      throw (New-QmdException -Message (
        "Restore target is a directory where a file is required: '$targetPath'."
      ))
    }
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
      $metadata = Get-FileMetadata -LiteralPath $targetPath -IncludeHash
      $action = if ($metadata.Sha256 -ceq [string]$file.sha256) {
        'UNCHANGED'
      }
      else {
        'REPLACE'
      }
      $plan.Add((New-QmdRestorePlanItem -Kind ([string]$file.kind) `
          -TargetPath $targetPath -Action $action -ArchivedFile $file `
          -TargetMetadata $metadata))
    }
    else {
      $plan.Add((New-QmdRestorePlanItem -Kind ([string]$file.kind) `
          -TargetPath $targetPath -Action CREATE -ArchivedFile $file))
    }

    if ([string]$file.kind -cne 'Index database') {
      continue
    }
    foreach ($suffix in @('-wal', '-shm')) {
      $sidecarPath = "$targetPath$suffix"
      if (Test-Path -LiteralPath $sidecarPath -PathType Container) {
        throw (New-QmdException -Message (
          "SQLite sidecar target is a directory: '$sidecarPath'."
        ))
      }
      if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
        continue
      }
      if (-not $seenTargets.Add($sidecarPath)) {
        throw (New-QmdException -Message (
          "Archive produces a duplicate SQLite sidecar target: '$sidecarPath'."
        ))
      }
      $sidecarMetadata = Get-FileMetadata -LiteralPath $sidecarPath -IncludeHash
      $plan.Add((New-QmdRestorePlanItem -Kind 'SQLite sidecar' `
          -TargetPath $sidecarPath -Action MOVE-TO-ROLLBACK `
          -TargetMetadata $sidecarMetadata))
    }
  }

  $plan.ToArray()
}

function Show-QmdRestorePlan {
  param(
    [Parameter(Mandatory)]
    [object[]]$Plan,

    [Parameter(Mandatory)]
    [string]$RollbackPath,

    [Parameter(Mandatory)]
    [string]$LogPath,

    [Parameter(Mandatory)]
    [pscustomobject]$McpState,

    [Parameter(Mandatory)]
    [string]$SourceMode
  )

  Write-QmdMessage -Level 'INFO' -Message "Restore source mode | $SourceMode"
  foreach ($item in $Plan) {
    Write-QmdItem -Label $item.Kind -Path $item.TargetPath
    $archiveSize = if ($null -ne $item.ArchivedFile) {
      [string]$item.ArchivedFile.size
    }
    else {
      '<none>'
    }
    $archiveTime = if ($null -ne $item.ArchivedFile) {
      Format-QmdDateValue -Value $item.ArchivedFile.lastWriteTimeUtc
    }
    else {
      '<none>'
    }
    $archiveHash = if ($null -ne $item.ArchivedFile) {
      [string]$item.ArchivedFile.sha256
    }
    else {
      '<none>'
    }
    $targetSize = if ($null -ne $item.TargetMetadata) {
      [string]$item.TargetMetadata.Size
    }
    else {
      '<missing>'
    }
    $targetTime = if ($null -ne $item.TargetMetadata) {
      [string]$item.TargetMetadata.LastWriteTimeUtc
    }
    else {
      '<missing>'
    }
    $targetHash = if ($null -ne $item.TargetMetadata) {
      [string]$item.TargetMetadata.Sha256
    }
    else {
      '<missing>'
    }
    Write-QmdMessage -Level 'INFO' -Message (
      "Action=$($item.Action) ArchivedSize=$archiveSize TargetSize=$targetSize " +
      "ArchivedTime=$archiveTime TargetTime=$targetTime " +
      "ArchivedSHA256=$archiveHash TargetSHA256=$targetHash"
    )
  }
  Write-QmdItem -Label 'Rollback archive' -Path $RollbackPath
  Write-QmdItem -Label 'Restore log' -Path $LogPath
  if ($McpState.WasRunning) {
    Write-QmdMessage -Level 'INFO' -Message (
      "Managed QMD MCP server will be stopped and restarted | PID $($McpState.ProcessId)"
    )
  }
  else {
    Write-QmdMessage -Level 'INFO' -Message 'Managed QMD MCP server is not running.'
  }
}

function Assert-QmdPlanItemStillCurrent {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$PlanItem
  )

  if ($null -eq $PlanItem.TargetMetadata) {
    if (Test-Path -LiteralPath $PlanItem.TargetPath) {
      throw (New-QmdException -Message (
        "Restore target appeared after planning: '$($PlanItem.TargetPath)'."
      ) -ReturnCode 3)
    }
    return
  }

  if (-not (Test-Path -LiteralPath $PlanItem.TargetPath -PathType Leaf)) {
    throw (New-QmdException -Message (
      "Restore target disappeared after planning: '$($PlanItem.TargetPath)'."
    ) -ReturnCode 3)
  }
  $current = Get-FileMetadata -LiteralPath $PlanItem.TargetPath -IncludeHash
  if (
    $current.Size -ne $PlanItem.TargetMetadata.Size -or
    $current.LastWriteTimeUtc -cne $PlanItem.TargetMetadata.LastWriteTimeUtc -or
    $current.Sha256 -cne $PlanItem.TargetMetadata.Sha256
  ) {
    throw (New-QmdException -Message (
      "Restore target changed after planning: '$($PlanItem.TargetPath)'."
    ) -ReturnCode 3)
  }
}

function Get-QmdMissingParentDirectories {
  param(
    [Parameter(Mandatory)]
    [string]$TargetPath
  )

  $missing = [System.Collections.Generic.List[string]]::new()
  $directory = Split-Path -Parent $TargetPath
  while (-not [string]::IsNullOrWhiteSpace($directory) -and
    -not [System.IO.Directory]::Exists($directory)) {
    $missing.Add($directory)
    $parent = Split-Path -Parent $directory
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $directory) {
      break
    }
    $directory = $parent
  }
  @($missing.ToArray() | Sort-Object { $_.Length })
}

function Assert-QmdRollbackArchive {
  param(
    [Parameter(Mandatory)]
    [string]$ArchivePath
  )

  $stream = [System.IO.File]::OpenRead($ArchivePath)
  try {
    $zip = [System.IO.Compression.ZipArchive]::new(
      $stream,
      [System.IO.Compression.ZipArchiveMode]::Read
    )
    try {
      $entries = @($zip.Entries)
      $map = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
      )
      foreach ($entry in $entries) {
        Assert-SafeArchivePath -ArchivePath $entry.FullName -AllowDirectory
        if ($map.ContainsKey($entry.FullName)) {
          throw (New-QmdException -Message (
            "Rollback ZIP has a duplicate entry: '$($entry.FullName)'."
          ) -ReturnCode 3)
        }
        $map.Add($entry.FullName, $entry)
      }
      if (-not $map.ContainsKey('rollback-manifest.json')) {
        throw (New-QmdException -Message 'Rollback ZIP has no manifest.' -ReturnCode 3)
      }
      $manifestEntry = [System.IO.Compression.ZipArchiveEntry]$map['rollback-manifest.json']
      $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
      try {
        $manifest = $reader.ReadToEnd() | ConvertFrom-Json -Depth 20 -ErrorAction Stop
      }
      finally {
        $reader.Dispose()
      }
      if ([int]$manifest.rollbackFormatVersion -ne $script:RollbackFormatVersion) {
        throw (New-QmdException -Message 'Rollback manifest version is unsupported.' `
            -ReturnCode 3)
      }
      foreach ($file in @($manifest.originalFiles)) {
        if (-not $map.ContainsKey([string]$file.archivePath)) {
          throw (New-QmdException -Message (
            "Rollback ZIP is missing '$($file.archivePath)'."
          ) -ReturnCode 3)
        }
        $entry = [System.IO.Compression.ZipArchiveEntry]$map[[string]$file.archivePath]
        if (
          [int64]$entry.Length -ne [int64]$file.size -or
          (Get-QmdZipEntrySha256 -Entry $entry) -cne [string]$file.sha256
        ) {
          throw (New-QmdException -Message (
            "Rollback ZIP validation failed for '$($file.targetPath)'."
          ) -ReturnCode 3)
        }
      }
      $manifest
    }
    finally {
      $zip.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function New-QmdRollback {
  param(
    [Parameter(Mandatory)]
    [object[]]$Plan,

    [Parameter(Mandatory)]
    [string]$RollbackStagingPath,

    [Parameter(Mandatory)]
    [string]$RollbackArchivePath
  )

  $null = [System.IO.Directory]::CreateDirectory($RollbackStagingPath)
  $originalFiles = [System.Collections.Generic.List[object]]::new()
  $createdFiles = [System.Collections.Generic.List[string]]::new()
  $createdDirectories = [System.Collections.Generic.HashSet[string]]::new(
    $script:PathComparer
  )

  foreach ($item in $Plan) {
    if ($item.Action -eq 'UNCHANGED') {
      continue
    }
    Assert-QmdPlanItemStillCurrent -PlanItem $item
    if ($item.Action -eq 'CREATE') {
      $createdFiles.Add($item.TargetPath)
      foreach ($directory in @(Get-QmdMissingParentDirectories -TargetPath $item.TargetPath)) {
        $null = $createdDirectories.Add($directory)
      }
      continue
    }

    $identifier = Get-DeterministicIdentifier -Prefix 'original' -Value $item.TargetPath
    $archivePath = ConvertTo-QmdArchivePath -RelativePath (
      "files/$identifier/$([System.IO.Path]::GetFileName($item.TargetPath))"
    )
    $destination = Join-Path $RollbackStagingPath $archivePath.Replace('/', '\')
    $metadata = Copy-StableFile -SourcePath $item.TargetPath -DestinationPath $destination
    $originalFiles.Add([ordered]@{
        targetPath = $item.TargetPath
        archivePath = $archivePath
        size = [int64]$metadata.Size
        lastWriteTimeUtc = $metadata.LastWriteTimeUtc
        sha256 = $metadata.Sha256
      })
    Write-QmdItem -Label 'Rollback source' -Path $item.TargetPath
  }

  $manifest = [ordered]@{
    rollbackFormatVersion = $script:RollbackFormatVersion
    scriptName = $script:ScriptName
    scriptVersion = $script:ScriptVersion
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    originalFiles = @($originalFiles.ToArray() | Sort-Object targetPath)
    createdFiles = @($createdFiles.ToArray() | Sort-Object)
    createdDirectories = @($createdDirectories | Sort-Object { $_.Length })
  }
  Write-QmdJsonFile -InputObject $manifest `
    -LiteralPath (Join-Path $RollbackStagingPath 'rollback-manifest.json')
  New-QmdZipFromStaging -StagingPath $RollbackStagingPath `
    -DestinationPath $RollbackArchivePath -DirectoryEntries @('files/')
  $validated = Assert-QmdRollbackArchive -ArchivePath $RollbackArchivePath
  Write-QmdItem -Label 'Rollback archive' -Path $RollbackArchivePath

  [pscustomobject]@{
    Manifest = $validated
    StagingPath = $RollbackStagingPath
  }
}

function Copy-QmdRestoreFileAtomically {
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$TargetPath,

    [Parameter(Mandatory)]
    [string]$ExpectedSha256
  )

  $targetDirectory = Split-Path -Parent $TargetPath
  $null = [System.IO.Directory]::CreateDirectory($targetDirectory)
  $temporaryName = '.{0}.qmd-restore-{1}.tmp' -f (
    [System.IO.Path]::GetFileName($TargetPath),
    [guid]::NewGuid().ToString('N')
  )
  $temporaryPath = Join-Path $targetDirectory $temporaryName
  try {
    [System.IO.File]::Copy($SourcePath, $temporaryPath, $false)
    $temporaryHash = Get-Sha256Hex -LiteralPath $temporaryPath
    if ($temporaryHash -cne $ExpectedSha256) {
      throw (New-QmdException -Message (
        "Temporary restore hash mismatch for '$TargetPath'."
      ) -ReturnCode 3)
    }
    [System.IO.File]::Move($temporaryPath, $TargetPath, $true)
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }

  $targetHash = Get-Sha256Hex -LiteralPath $TargetPath
  if ($targetHash -cne $ExpectedSha256) {
    throw (New-QmdException -Message (
      "Post-write restore hash mismatch for '$TargetPath'."
    ) -ReturnCode 3)
  }
}

function Invoke-QmdRollback {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Rollback
  )

  $complete = $true
  Write-QmdMessage -Level 'WARN' -Message 'Starting automatic rollback.'
  foreach ($file in @($Rollback.Manifest.originalFiles | Sort-Object targetPath)) {
    try {
      $targetPath = [string]$file.targetPath
      $alreadyRestored = (
        (Test-Path -LiteralPath $targetPath -PathType Leaf) -and
        (Get-Sha256Hex -LiteralPath $targetPath) -ceq [string]$file.sha256
      )
      if (-not $alreadyRestored) {
        $sourcePath = Join-Path $Rollback.StagingPath (
          ([string]$file.archivePath).Replace('/', '\')
        )
        Copy-QmdRestoreFileAtomically -SourcePath $sourcePath -TargetPath $targetPath `
          -ExpectedSha256 ([string]$file.sha256)
      }
      Write-QmdItem -Label 'Rollback restored' -Path $targetPath
    }
    catch {
      $complete = $false
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback restore failed for '$($file.targetPath)': $($_.Exception.Message)"
      )
    }
  }

  foreach ($targetPath in @($Rollback.Manifest.createdFiles)) {
    try {
      if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        Remove-Item -LiteralPath $targetPath -Force
        Write-QmdItem -Label 'Rollback removed' -Path $targetPath
      }
    }
    catch {
      $complete = $false
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback could not remove created file '$targetPath': $($_.Exception.Message)"
      )
    }
  }

  foreach ($directory in @($Rollback.Manifest.createdDirectories |
      Sort-Object { ([string]$_).Length } -Descending)) {
    try {
      if (
        [System.IO.Directory]::Exists([string]$directory) -and
        @(Get-ChildItem -LiteralPath ([string]$directory) -Force).Count -eq 0
      ) {
        [System.IO.Directory]::Delete([string]$directory, $false)
      }
    }
    catch {
      $complete = $false
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback could not remove directory '$directory': $($_.Exception.Message)"
      )
    }
  }

  foreach ($file in @($Rollback.Manifest.originalFiles)) {
    if (
      -not (Test-Path -LiteralPath $file.targetPath -PathType Leaf) -or
      (Get-Sha256Hex -LiteralPath $file.targetPath) -cne [string]$file.sha256
    ) {
      $complete = $false
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback verification failed for '$($file.targetPath)'."
      )
    }
  }
  foreach ($targetPath in @($Rollback.Manifest.createdFiles)) {
    if (Test-Path -LiteralPath $targetPath) {
      $complete = $false
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback verification found a created target still present: '$targetPath'."
      )
    }
  }

  if ($complete) {
    Write-QmdMessage -Level 'INFO' -Message 'Automatic rollback completed and verified.'
  }
  else {
    Write-QmdMessage -Level 'FATAL' -Message (
      'Automatic rollback is incomplete. Manual intervention is required.'
    )
  }
  $complete
}

function Assert-QmdExtractedFiles {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Manifest,

    [Parameter(Mandatory)]
    [string]$StagingPath,

    [Parameter(Mandatory)]
    [pscustomobject]$Dependencies
  )

  foreach ($file in @($Manifest.files)) {
    $path = Join-Path $StagingPath ([string]$file.archivePath).Replace('/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw (New-QmdException -Message (
        "Extracted archive is missing '$($file.archivePath)'."
      ) -ReturnCode 3)
    }
    $metadata = Get-FileMetadata -LiteralPath $path -IncludeHash
    if (
      $metadata.Size -ne [int64]$file.size -or
      $metadata.Sha256 -cne [string]$file.sha256
    ) {
      throw (New-QmdException -Message (
        "Extracted file validation failed for '$($file.archivePath)'."
      ) -ReturnCode 3)
    }
    if ([string]$file.kind -eq 'Index database') {
      Assert-QmdSqliteIntegrity -Dependencies $Dependencies -DatabasePath $path
    }
  }
}

function Invoke-QmdRestoreWrites {
  param(
    [Parameter(Mandatory)]
    [object[]]$Plan,

    [Parameter(Mandatory)]
    [string]$RestoreStagingPath
  )

  $movedSidecarRoot = Join-Path $RestoreStagingPath 'moved-sidecars'
  foreach ($item in @($Plan | Where-Object { $_.Action -eq 'MOVE-TO-ROLLBACK' })) {
    Assert-QmdPlanItemStillCurrent -PlanItem $item
    $identifier = Get-DeterministicIdentifier -Prefix 'sidecar' -Value $item.TargetPath
    $destination = Join-Path $movedSidecarRoot (
      "$identifier\$([System.IO.Path]::GetFileName($item.TargetPath))"
    )
    $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    [System.IO.File]::Move($item.TargetPath, $destination, $false)
    Write-QmdItem -Label 'SQLite sidecar moved' -Path $item.TargetPath
  }

  $kindOrder = @{
    'Collection configuration' = 10
    'Indexed collection data' = 20
    'GGUF model' = 30
    'Index database' = 40
  }
  $writeItems = @($Plan | Where-Object {
      $_.Action -in @('CREATE', 'REPLACE')
    } | Sort-Object @{ Expression = {
          if ($kindOrder.ContainsKey($_.Kind)) { $kindOrder[$_.Kind] } else { 25 }
        } }, TargetPath)

  foreach ($item in $writeItems) {
    Assert-QmdPlanItemStillCurrent -PlanItem $item
    $sourcePath = Join-Path $RestoreStagingPath (
      ([string]$item.ArchivedFile.archivePath).Replace('/', '\')
    )
    Write-QmdItem -Label $item.Kind -Path $item.TargetPath
    Copy-QmdRestoreFileAtomically -SourcePath $sourcePath -TargetPath $item.TargetPath `
      -ExpectedSha256 ([string]$item.ArchivedFile.sha256)
  }

  foreach ($item in $writeItems) {
    if (
      -not (Test-Path -LiteralPath $item.TargetPath -PathType Leaf) -or
      (Get-Sha256Hex -LiteralPath $item.TargetPath) -cne [string]$item.ArchivedFile.sha256
    ) {
      throw (New-QmdException -Message (
        "Final restore verification failed for '$($item.TargetPath)'."
      ) -ReturnCode 3)
    }
  }
}

function Invoke-QmdRestoreOperation {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Arguments
  )

  $script:CurrentMode = 'RESTORE'
  $script:VerboseEnabled = [bool]$Arguments.Verbose
  $sourceFile = Get-CanonicalExistingPath -LiteralPath $Arguments.SourceFile -PathType File
  $null = Test-NormalFile -LiteralPath $sourceFile
  if ([System.IO.Path]::GetExtension($sourceFile) -cne '.zip') {
    throw (New-QmdException -Message '--source-file must name a ZIP archive.')
  }

  $workDirectoryInput = if ([string]::IsNullOrWhiteSpace($Arguments.OutputDirectory)) {
    Split-Path -Parent $sourceFile
  }
  else {
    $Arguments.OutputDirectory
  }
  $workDirectory = Assert-OperationalDirectory -LiteralPath $workDirectoryInput `
    -Purpose 'Restore work directory'
  $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
  $archiveStem = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile)
  $logPath = Join-Path $workDirectory "$archiveStem-restore-$timestamp.log"
  $rollbackPath = Join-Path $workDirectory "$archiveStem-rollback-$timestamp.zip"

  $collisions = @($logPath, $rollbackPath | Where-Object {
      Test-Path -LiteralPath $_
    })
  if ($collisions.Count -gt 0) {
    foreach ($collision in $collisions) {
      Write-QmdItem -Label 'Existing restore output' -Path $collision -Level WARN
    }
    if (-not $Arguments.DryRun) {
      Confirm-QmdAction -Message 'Existing restore outputs will be replaced.' `
        -Force:$Arguments.Force
    }
  }
  if (-not $Arguments.DryRun) {
    Initialize-QmdLog -LiteralPath $logPath
  }

  Write-QmdMessage -Level 'INFO' -Message 'Restore mode | RESTORE'
  $dependencies = Get-QmdDependencyContext
  $archive = Read-QmdBackupArchive -ArchivePath $sourceFile
  $manifest = $archive.Manifest
  Assert-QmdRestoreCompatibility -Manifest $manifest -Dependencies $dependencies
  Show-QmdEnvironmentDifferences -Manifest $manifest
  $plan = @(Get-QmdRestorePlan -Manifest $manifest)

  [int64]$archiveBytes = (Get-Item -LiteralPath $sourceFile).Length
  [int64]$existingBytes = 0
  foreach ($item in $plan) {
    if ($null -ne $item.TargetMetadata -and $item.Action -ne 'UNCHANGED') {
      $existingBytes += [int64]$item.TargetMetadata.Size
    }
  }
  $requiredBytes = Get-QmdRequiredCapacity -BaseBytes $archiveBytes `
    -Multiplier 3 -AdditionalBytes $existingBytes
  Assert-QmdFreeSpace -DirectoryPath $workDirectory `
    -RequiredBytes $requiredBytes `
    -Purpose 'restore staging and rollback'

  $resolvedPaths = Get-QmdResolvedPaths
  $mcpState = Get-QmdManagedMcpState -ResolvedPaths $resolvedPaths
  if ($mcpState.IsStale) {
    Write-QmdMessage -Level 'WARN' -Message (
      "Stale QMD MCP PID file detected without modification: '$($mcpState.PidPath)'."
    )
  }
  if ($mcpState.WasRunning -and -not $mcpState.Restorable) {
    throw (New-QmdException -Message (
      "Managed QMD MCP process $($mcpState.ProcessId) cannot be restarted exactly."
    ))
  }
  $managedId = if ($mcpState.WasRunning) {
    [Nullable[int]]::new([int]$mcpState.ProcessId)
  }
  else {
    $null
  }
  Assert-NoQmdIncompatibleProcess -ManagedProcessId $managedId
  Show-QmdRestorePlan -Plan $plan -RollbackPath $rollbackPath -LogPath $logPath `
    -McpState $mcpState -SourceMode ([string]$manifest.backupMode
  )

  if ($Arguments.DryRun) {
    Write-QmdMessage -Level 'WARN' -Message (
      'SQLite snapshot integrity is validated during real restore after isolated extraction; ' +
      'dry-run performs ZIP entry and SHA-256 validation without extracting files.'
    )
    Write-QmdMessage -Level 'INFO' -Message 'Dry run completed without side effects.'
    return [pscustomobject]@{
      Status = 'COMPLETED'
      ReturnCode = 0
      SourceMode = [string]$manifest.backupMode
    }
  }

  $changes = @($plan | Where-Object { $_.Action -ne 'UNCHANGED' })
  if ($changes.Count -gt 0) {
    Confirm-QmdAction -Message (
      'The displayed restore plan will modify target files.'
    ) -Force:$Arguments.Force
  }

  $restoreStagingPath = Join-Path $workDirectory (
    '.qmd-restore-staging-' + [guid]::NewGuid().ToString('N')
  )
  $rollbackStagingPath = Join-Path $workDirectory (
    '.qmd-rollback-staging-' + [guid]::NewGuid().ToString('N')
  )
  $rollback = $null
  $operationCompleted = $false
  $rollbackComplete = $true
  $restartSucceeded = $true
  $failureOccurred = $false

  try {
    $null = [System.IO.Directory]::CreateDirectory($restoreStagingPath)
    Expand-QmdBackupArchive -ArchivePath $sourceFile -DestinationPath $restoreStagingPath
    Assert-QmdExtractedFiles -Manifest $manifest -StagingPath $restoreStagingPath `
      -Dependencies $dependencies

    Stop-QmdManagedMcp -Dependencies $dependencies -McpState $mcpState
    Assert-NoQmdIncompatibleProcess -ManagedProcessId $null

    if (Test-Path -LiteralPath $rollbackPath) {
      Remove-Item -LiteralPath $rollbackPath -Force
    }
    $rollback = New-QmdRollback -Plan $plan -RollbackStagingPath $rollbackStagingPath `
      -RollbackArchivePath $rollbackPath
    Invoke-QmdRestoreWrites -Plan $plan -RestoreStagingPath $restoreStagingPath
    $operationCompleted = $true
  }
  catch {
    $failureOccurred = $true
    $caught = $_
    Write-QmdMessage -Level 'ERROR' -Message $caught.Exception.Message
    if ($null -ne $rollback) {
      $rollbackComplete = Invoke-QmdRollback -Rollback $rollback
    }
    else {
      $rollbackComplete = $true
      Write-QmdMessage -Level 'INFO' -Message (
        'No target modification occurred because rollback validation did not complete.'
      )
    }
  }
  finally {
    try {
      Remove-QmdOwnedDirectory -DirectoryPath $restoreStagingPath `
        -ExpectedParent $workDirectory -ExpectedNamePrefix '.qmd-restore-staging-'
    }
    catch {
      Write-QmdMessage -Level 'ERROR' -Message (
        "Restore staging cleanup failed: $($_.Exception.Message)"
      )
      if ($operationCompleted) {
        $restartSucceeded = $false
      }
    }
    try {
      Remove-QmdOwnedDirectory -DirectoryPath $rollbackStagingPath `
        -ExpectedParent $workDirectory -ExpectedNamePrefix '.qmd-rollback-staging-'
    }
    catch {
      Write-QmdMessage -Level 'ERROR' -Message (
        "Rollback staging cleanup failed: $($_.Exception.Message)"
      )
      if ($operationCompleted) {
        $restartSucceeded = $false
      }
    }

    if ($mcpState.WasRunning) {
      $restartSucceeded = (Start-QmdManagedMcp -Dependencies $dependencies `
          -McpState $mcpState) -and $restartSucceeded
    }
  }

  if ($failureOccurred) {
    return [pscustomobject]@{
      Status = 'FAILED'
      ReturnCode = if ($rollbackComplete) { 3 } else { 4 }
      SourceMode = [string]$manifest.backupMode
    }
  }
  if (-not $operationCompleted) {
    return [pscustomobject]@{
      Status = 'FAILED'
      ReturnCode = 3
      SourceMode = [string]$manifest.backupMode
    }
  }
  if (-not $restartSucceeded) {
    return [pscustomobject]@{
      Status = 'COMPLETED-WITH-ERRORS'
      ReturnCode = 1
      SourceMode = [string]$manifest.backupMode
    }
  }
  [pscustomobject]@{
    Status = 'COMPLETED'
    ReturnCode = 0
    SourceMode = [string]$manifest.backupMode
  }
}

if ($MyInvocation.InvocationName -eq '.') {
  return
}

$result = $null
try {
  $arguments = Get-ParsedArguments -Tokens @($args)
  Assert-ValidArgumentCombination -Arguments $arguments
  if ($arguments.Help) {
    [Console]::Out.WriteLine(($script:HelpLines -join [Environment]::NewLine))
    exit 0
  }
  if ($arguments.Version) {
    [Console]::Out.WriteLine($script:ScriptVersion)
    exit 0
  }

  if ($arguments.Backup) {
    $result = Invoke-QmdBackupOperation -Arguments $arguments
  }
  else {
    $result = Invoke-QmdRestoreOperation -Arguments $arguments
  }
}
catch {
  $caught = $_
  $returnCode = Get-QmdExceptionReturnCode -ErrorRecord $caught
  Write-QmdMessage -Level 'FATAL' -Message $caught.Exception.Message
  Write-QmdMessage -Level 'DEBUG' -Message $caught.ScriptStackTrace
  $result = [pscustomobject]@{
    Status = 'FAILED'
    ReturnCode = $returnCode
    SourceMode = $null
  }
}

Write-QmdFinalStatus -Status $result.Status -Mode $script:CurrentMode `
  -ReturnCode $result.ReturnCode -SourceMode $result.SourceMode
exit $result.ReturnCode
