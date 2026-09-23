#Requires -Version 7.4
#Requires -PSEdition Core

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$TargetScript = Join-Path $RepositoryRoot 'scripts\Invoke-QmdBackup.ps1'
$TestRoot = Join-Path (
  [System.IO.Path]::GetTempPath()
) "qmd-backup-tests-$([guid]::NewGuid().ToString('N'))"
$script:PassedCount = 0
$script:FailedTests = [System.Collections.Generic.List[string]]::new()

. $TargetScript

function Assert-TestCondition {
  param(
    [Parameter(Mandatory)]
    [bool]$Condition,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if (-not $Condition) {
    throw [System.InvalidOperationException]::new($Message)
  }
}

function Assert-TestEqual {
  param(
    [AllowNull()]
    [object]$Actual,

    [AllowNull()]
    [object]$Expected,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw [System.InvalidOperationException]::new(
      "$Message Expected '$Expected', received '$Actual'."
    )
  }
}

function Assert-TestThrow {
  param(
    [Parameter(Mandatory)]
    [scriptblock]$Action,

    [Parameter(Mandatory)]
    [string]$MessagePattern,

    [AllowNull()]
    [Nullable[int]]$ReturnCode
  )

  $DidThrow = $false
  try {
    & $Action
  }
  catch {
    $ErrorRecord = $_
    $DidThrow = $true
    if ($ErrorRecord.Exception.Message -notmatch $MessagePattern) {
      throw [System.InvalidOperationException]::new(
        "Exception '$($ErrorRecord.Exception.Message)' does not match " +
        "'$MessagePattern'."
      )
    }
    if ($null -ne $ReturnCode) {
      $ActualReturnCode = $ErrorRecord.Exception.Data['QmdReturnCode']
      Assert-TestEqual -Actual $ActualReturnCode -Expected ([int]$ReturnCode) `
        -Message 'Exception return code mismatch.'
    }
  }

  if (-not $DidThrow) {
    throw [System.InvalidOperationException]::new(
      "Expected an exception matching '$MessagePattern'."
    )
  }
}

function Invoke-TestCase {
  param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [scriptblock]$Action
  )

  try {
    & $Action
    $script:PassedCount++
    [Console]::Out.WriteLine("PASS: $Name")
  }
  catch {
    $ErrorRecord = $_
    $script:FailedTests.Add("$Name`: $($ErrorRecord.Exception.Message)")
    [Console]::Error.WriteLine(
      "FAIL: $Name`: $($ErrorRecord.Exception.Message)"
    )
  }
}

try {
  $null = New-Item -ItemType Directory -Path $TestRoot
  $CollectionRoot = Join-Path $TestRoot 'collection'
  $SpacedDirectory = Join-Path $CollectionRoot 'Blood Angels 500pts'
  $HyphenDirectory = Join-Path $CollectionRoot 'Actual-Hyphen'
  $null = New-Item -ItemType Directory -Path $SpacedDirectory
  $null = New-Item -ItemType Directory -Path $HyphenDirectory
  $SpacedFile = Join-Path $SpacedDirectory 'README.md'
  $HyphenFile = Join-Path $HyphenDirectory 'README.md'
  [System.IO.File]::WriteAllText($SpacedFile, "# Spaced path`n", $script:Utf8NoBom)
  [System.IO.File]::WriteAllText($HyphenFile, "# Hyphen path`n", $script:Utf8NoBom)
  $NodePath = [string](
    Get-Command 'node' -CommandType Application | Select-Object -First 1
  ).Source
  $QmdPackageRoot = Join-Path $TestRoot 'qmd-package'
  $QmdDistDirectory = Join-Path $QmdPackageRoot 'dist'
  $FastGlobDirectory = Join-Path $QmdPackageRoot 'node_modules\fast-glob'
  $null = New-Item -ItemType Directory -Path $QmdDistDirectory
  $null = New-Item -ItemType Directory -Path $FastGlobDirectory
  [System.IO.File]::WriteAllText(
    (Join-Path $QmdPackageRoot 'package.json'),
    '{"type":"module"}',
    $script:Utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $QmdDistDirectory 'store.js'),
    'export function handelize(value) { return value.replaceAll(" ", "-"); }',
    $script:Utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $FastGlobDirectory 'index.cjs'),
    'module.exports = async () => [' +
      '"Actual-Hyphen/README.md","Blood Angels 500pts/README.md"];',
    $script:Utf8NoBom
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $FastGlobDirectory 'package.json'),
    '{"main":"index.cjs"}',
    $script:Utf8NoBom
  )

  Invoke-TestCase -Name 'log timestamps use the compact local format' -Action {
    $OriginalOutput = [Console]::Out
    $OriginalError = [Console]::Error
    $OriginalLogPath = $script:LogPath
    $OutputWriter = [System.IO.StringWriter]::new()
    $ErrorWriter = [System.IO.StringWriter]::new()
    $TimestampLogPath = Join-Path $TestRoot 'timestamp.log'
    try {
      [Console]::SetOut($OutputWriter)
      [Console]::SetError($ErrorWriter)
      $script:LogPath = $TimestampLogPath
      Write-QmdMessage -Level 'INFO' -Message 'Timestamp format test.'
      Write-QmdMessage -Level 'ERROR' -Message 'Timestamp error test.'
    }
    finally {
      [Console]::SetOut($OriginalOutput)
      [Console]::SetError($OriginalError)
      $script:LogPath = $OriginalLogPath
    }

    $TimestampPattern = '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
    $OutputLine = $OutputWriter.ToString().Trim()
    $ErrorLine = $ErrorWriter.ToString().Trim()
    Assert-TestCondition -Condition (
      $OutputLine -match "^$TimestampPattern \[INFO \] Timestamp format test\.$"
    ) -Message 'Standard-output log timestamp format mismatch.'
    Assert-TestCondition -Condition (
      $ErrorLine -match "^$TimestampPattern \[ERROR\] Timestamp error test\.$"
    ) -Message 'Standard-error log timestamp format mismatch.'

    $LogLines = @(Get-Content -LiteralPath $TimestampLogPath)
    Assert-TestEqual -Actual $LogLines.Count -Expected 2 `
      -Message 'Timestamp log line count mismatch.'
    Assert-TestEqual -Actual $LogLines[0] -Expected $OutputLine `
      -Message 'Standard-output and file log lines differ.'
    Assert-TestEqual -Actual $LogLines[1] -Expected $ErrorLine `
      -Message 'Standard-error and file log lines differ.'
  }

  Invoke-TestCase -Name 'QMD logical path resolves a physical path with spaces' -Action {
    $Document = [pscustomobject]@{
      collectionName = 'docs'
      collectionRoot = $CollectionRoot
      relativePath = 'Blood-Angels-500pts/README.md'
    }
    $PhysicalFiles = @(
      [pscustomobject]@{
        logicalPath = 'Blood-Angels-500pts/README.md'
        physicalRelativePath = 'Blood Angels 500pts/README.md'
      }
    )
    $Resolved = Resolve-QmdIndexedFile -Document $Document `
      -PhysicalFiles $PhysicalFiles
    Assert-TestEqual -Actual $Resolved -Expected (
      [System.IO.Path]::GetFullPath($SpacedFile)
    ) -Message 'Resolved spaced path mismatch.'
  }

  Invoke-TestCase -Name 'a physical path containing hyphens remains supported' -Action {
    $Document = [pscustomobject]@{
      collectionName = 'docs'
      collectionRoot = $CollectionRoot
      relativePath = 'Actual-Hyphen/README.md'
    }
    $PhysicalFiles = @(
      [pscustomobject]@{
        logicalPath = 'Actual-Hyphen/README.md'
        physicalRelativePath = 'Actual-Hyphen/README.md'
      }
    )
    $Resolved = Resolve-QmdIndexedFile -Document $Document `
      -PhysicalFiles $PhysicalFiles
    Assert-TestEqual -Actual $Resolved -Expected (
      [System.IO.Path]::GetFullPath($HyphenFile)
    ) -Message 'Resolved hyphenated path mismatch.'
  }

  Invoke-TestCase -Name 'missing physical files are rejected' -Action {
    $Document = [pscustomobject]@{
      collectionName = 'docs'
      collectionRoot = $CollectionRoot
      relativePath = 'Missing-File.md'
    }
    Assert-TestThrow -Action {
      $null = Resolve-QmdIndexedFile -Document $Document -PhysicalFiles @()
    } -MessagePattern 'no matching physical file'
  }

  Invoke-TestCase -Name 'QMD path normalization collisions are rejected' -Action {
    $Document = [pscustomobject]@{
      collectionName = 'docs'
      collectionRoot = $CollectionRoot
      relativePath = 'Blood-Angels-500pts/README.md'
    }
    $PhysicalFiles = @(
      [pscustomobject]@{
        logicalPath = 'Blood-Angels-500pts/README.md'
        physicalRelativePath = 'Blood Angels 500pts/README.md'
      }
      [pscustomobject]@{
        logicalPath = 'Blood-Angels-500pts/README.md'
        physicalRelativePath = 'Blood-Angels-500pts/README.md'
      }
    )
    Assert-TestThrow -Action {
      $null = Resolve-QmdIndexedFile -Document $Document `
        -PhysicalFiles $PhysicalFiles
    } -MessagePattern 'ambiguous'
  }

  Invoke-TestCase -Name 'source existence is checked immediately before copy' -Action {
    $MissingSource = Join-Path $TestRoot 'missing-source.md'
    $Destination = Join-Path $TestRoot 'copied.md'
    Assert-TestThrow -Action {
      $null = Copy-StableFile -SourcePath $MissingSource `
        -DestinationPath $Destination
    } -MessagePattern 'immediately before copy' -ReturnCode 3
    Assert-TestCondition -Condition (
      -not (Test-Path -LiteralPath $Destination)
    ) -Message 'A destination was created for a missing source.'
  }

  Invoke-TestCase -Name 'QMD scanner returns logical and physical paths' -Action {
    $Dependencies = [pscustomobject]@{
      NodePath = $NodePath
      QmdPackageRoot = $QmdPackageRoot
    }
    $PhysicalFiles = @(Get-QmdCollectionPhysicalFiles -Dependencies $Dependencies `
        -CollectionRoot $CollectionRoot -CollectionPattern '**/*.md' `
        -IgnorePatterns $null)
    $SpacedRecord = @(
      $PhysicalFiles | Where-Object {
        $_.physicalRelativePath -ceq 'Blood Angels 500pts/README.md'
      }
    )
    Assert-TestEqual -Actual $SpacedRecord.Count -Expected 1 `
      -Message 'Spaced physical path record count mismatch.'
    Assert-TestEqual -Actual $SpacedRecord[0].logicalPath `
      -Expected 'Blood-Angels-500pts/README.md' `
      -Message 'QMD logical path mismatch.'
  }

  Invoke-TestCase -Name 'external UTF-8 output survives an OEM console code page' -Action {
    $OriginalEncoding = [Console]::OutputEncoding
    try {
      [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(850)
      $Result = Invoke-QmdExternalCommand -FilePath $NodePath -ArgumentList @(
        '-e'
        'process.stdout.write("Génerali|Culture Générale")'
      )
    }
    finally {
      [Console]::OutputEncoding = $OriginalEncoding
    }
    Assert-TestEqual -Actual $Result.ExitCode -Expected 0 `
      -Message 'UTF-8 command exit code mismatch.'
    Assert-TestEqual -Actual $Result.Text `
      -Expected 'Génerali|Culture Générale' `
      -Message 'UTF-8 command output mismatch.'
  }

  Invoke-TestCase -Name 'backup capacity supports estimates above Int32' -Action {
    $Estimate = Get-QmdRequiredCapacity -BaseBytes ([int64](3GB)) `
      -Multiplier 2.25
    Assert-TestCondition -Condition ($Estimate -is [int64]) `
      -Message 'Capacity estimate is not Int64.'
    Assert-TestEqual -Actual $Estimate -Expected ([int64]7247757312) `
      -Message 'Large backup capacity estimate mismatch.'
  }

  Invoke-TestCase -Name 'restore capacity supports estimates above Int32' -Action {
    $Estimate = Get-QmdRequiredCapacity -BaseBytes ([int64](2GB)) `
      -Multiplier 3 -AdditionalBytes ([int64](1GB))
    Assert-TestCondition -Condition ($Estimate -is [int64]) `
      -Message 'Restore capacity estimate is not Int64.'
    Assert-TestEqual -Actual $Estimate -Expected ([int64](7GB)) `
      -Message 'Large restore capacity estimate mismatch.'
  }

  Invoke-TestCase -Name 'CLI version reports the corrected script version' -Action {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $VersionOutput = @(
      & $PowerShellPath -NoLogo -NoProfile -File $TargetScript --version
    )
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 0 `
      -Message 'Version exit code mismatch.'
    Assert-TestEqual -Actual $VersionOutput[-1] -Expected 'v0.1.3' `
      -Message 'Version output mismatch.'
  }
}
finally {
  if (Test-Path -LiteralPath $TestRoot -PathType Container) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}

if ($script:FailedTests.Count -gt 0) {
  [Console]::Error.WriteLine(
    "$($script:FailedTests.Count) test(s) failed:"
  )
  foreach ($Failure in $script:FailedTests) {
    [Console]::Error.WriteLine("  $Failure")
  }
  exit 1
}

[Console]::Out.WriteLine(
  "All $script:PassedCount Invoke-QmdBackup tests passed."
)
