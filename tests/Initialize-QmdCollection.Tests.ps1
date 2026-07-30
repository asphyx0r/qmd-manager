#Requires -Version 7.0
#Requires -PSEdition Core

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$TargetScript = Join-Path $RepositoryRoot 'scripts\Initialize-QmdCollection.ps1'
$TestRoot = Join-Path (
  [System.IO.Path]::GetTempPath()
) "qmd-manager-tests-$([guid]::NewGuid().ToString('N'))"
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
    [string]$MessagePattern
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

function Get-TestLocalState {
  param(
    [Parameter()]
    [bool]$NpmFunctional = $true,

    [Parameter()]
    [string]$NpmVersion = '12.0.2',

    [Parameter()]
    [string]$QmdVersion = '2.5.3',

    [Parameter()]
    [string]$WingetPath = 'C:\fake\winget.exe'
  )

  return [pscustomobject]@{
    WingetPath = $WingetPath
    NodePath = 'C:\fake\node.exe'
    NodeFunctional = $true
    NodeVersion = [System.Management.Automation.SemanticVersion]::new('22.22.2')
    NpmPath = 'C:\fake\npm.cmd'
    NpmFunctional = $NpmFunctional
    NpmVersion = ConvertTo-SemanticVersion -Value $NpmVersion
    NpmPrefix = 'C:\fake'
    QmdPath = 'C:\fake\qmd.cmd'
    Qmd = [pscustomobject]@{
      PackageInstalled = $true
      PackageVersion = ConvertTo-SemanticVersion -Value $QmdVersion
      ExpectedCommandPath = 'C:\fake\qmd.cmd'
      ResolvedFromNpmPrefix = $true
      CommandFunctional = $true
    }
  }
}

function Get-TestNetworkState {
  param(
    [Parameter()]
    [bool]$WinGetAndNodeAvailable = $false,

    [Parameter()]
    [bool]$NpmRegistryAvailable = $true
  )

  return [pscustomobject]@{
    WinGetAndNodeAvailable = $WinGetAndNodeAvailable
    NpmRegistryAvailable = $NpmRegistryAvailable
    HuggingFaceAvailable = $true
  }
}

try {
  $null = New-Item -ItemType Directory -Path $TestRoot

  Invoke-TestCase -Name 'log timestamps use the compact local format' -Action {
    $OriginalOutput = [Console]::Out
    $OriginalError = [Console]::Error
    $OutputWriter = [System.IO.StringWriter]::new()
    $ErrorWriter = [System.IO.StringWriter]::new()
    try {
      [Console]::SetOut($OutputWriter)
      [Console]::SetError($ErrorWriter)
      Write-QmdLog -Level 'INFO' -Message 'Timestamp format test.'
      Write-QmdLog -Level 'ERROR' -Message 'Timestamp error test.'
    }
    finally {
      [Console]::SetOut($OriginalOutput)
      [Console]::SetError($OriginalError)
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
  }

  Invoke-TestCase -Name 'native arguments are normalized' -Action {
    $NativeArguments = @{
      Path = 'C:\docs'
      Name = 'docs_1'
      Context = 'Documentation'
      DetailedLogging = $true
    }
    $Parsed = Get-ParsedArgumentSet -NativeArguments $NativeArguments
    Assert-TestEqual -Actual $Parsed.Path -Expected 'C:\docs' -Message 'Path mismatch.'
    Assert-TestEqual -Actual $Parsed.Name -Expected 'docs_1' -Message 'Name mismatch.'
    Assert-TestCondition -Condition $Parsed.Verbose -Message 'Verbose was not enabled.'
  }

  Invoke-TestCase -Name 'legacy GNU arguments remain supported' -Action {
    $LegacyArguments = @(
      '--path'
      'C:\docs'
      '--name'
      'docs'
      '--context'
      'Documentation'
      '--dry-run'
    )
    $ParserArguments = @{
      NativeArguments = @{}
      Tokens = $LegacyArguments
    }
    $Parsed = Get-ParsedArgumentSet @ParserArguments
    Assert-TestEqual -Actual $Parsed.Name -Expected 'docs' -Message 'Name mismatch.'
    Assert-TestCondition -Condition $Parsed.DryRun -Message 'Dry run was not enabled.'
  }

  Invoke-TestCase -Name 'mixed syntax duplicates are rejected' -Action {
    $ParserArguments = @{
      NativeArguments = @{ Path = 'C:\first' }
      Tokens = @('--path', 'C:\second')
    }
    Assert-TestThrow -Action {
      $null = Get-ParsedArgumentSet @ParserArguments
    } -MessagePattern 'duplicates'
  }

  Invoke-TestCase -Name 'collection names are constrained to the QMD grammar' -Action {
    $ValidArguments = [pscustomobject]@{
      Path = 'C:\docs'
      Name = 'Docs_2026-01'
      Context = 'Documentation'
    }
    Test-RequiredArgumentSet -ParsedArguments $ValidArguments

    $InvalidArguments = [pscustomobject]@{
      Path = 'C:\docs'
      Name = 'docs/main'
      Context = 'Documentation'
    }
    Assert-TestThrow -Action {
      Test-RequiredArgumentSet -ParsedArguments $InvalidArguments
    } -MessagePattern 'ASCII letters'
  }

  Invoke-TestCase -Name 'a recursive Markdown file is required' -Action {
    $EmptyDirectory = Join-Path $TestRoot 'empty'
    $MarkdownDirectory = Join-Path $TestRoot 'markdown'
    $NestedDirectory = Join-Path $MarkdownDirectory 'nested'
    $null = New-Item -ItemType Directory -Path $EmptyDirectory
    $null = New-Item -ItemType Directory -Path $NestedDirectory
    Set-Content -LiteralPath (Join-Path $NestedDirectory 'README.md') -Value '# Test'

    Assert-TestThrow -Action {
      $null = Resolve-CollectionDirectory -LiteralPath $EmptyDirectory
    } -MessagePattern 'contains no Markdown files'

    $Resolved = Resolve-CollectionDirectory -LiteralPath $MarkdownDirectory
    Assert-TestEqual -Actual $Resolved -Expected (
      [System.IO.Path]::GetFullPath($MarkdownDirectory)
    ) -Message 'Resolved Markdown directory mismatch.'
  }

  Invoke-TestCase -Name 'npm policy keeps only supported versions' -Action {
    $Npm116 = ConvertTo-SemanticVersion -Value '11.16.0'
    $Npm120 = ConvertTo-SemanticVersion -Value '12.0.2'
    $NpmOld = ConvertTo-SemanticVersion -Value '11.15.0'
    $NpmFuture = ConvertTo-SemanticVersion -Value '13.0.0'

    $Npm116Action = Get-NpmManagementAction -Functional $true -Version $Npm116 -RegistryAvailable $false
    $Npm120Action = Get-NpmManagementAction -Functional $true -Version $Npm120 -RegistryAvailable $false
    $OldOnlineAction = Get-NpmManagementAction -Functional $true -Version $NpmOld -RegistryAvailable $true
    $OldOfflineAction = Get-NpmManagementAction -Functional $true -Version $NpmOld -RegistryAvailable $false
    $FutureAction = Get-NpmManagementAction -Functional $true -Version $NpmFuture -RegistryAvailable $true

    Assert-TestEqual -Actual $Npm116Action -Expected 'Keep' -Message (
      'npm 11.16.0 should be kept.'
    )
    Assert-TestEqual -Actual $Npm120Action -Expected 'Keep' -Message (
      'npm 12.0.2 should be kept.'
    )
    Assert-TestEqual -Actual $OldOnlineAction -Expected 'InstallBootstrap' -Message (
      'Old npm should be replaced.'
    )
    Assert-TestEqual -Actual $OldOfflineAction -Expected 'Unavailable' -Message (
      'Old offline npm should fail.'
    )
    Assert-TestEqual -Actual $FutureAction -Expected 'InstallBootstrap' -Message (
      'Future npm should be bounded.'
    )
  }

  Invoke-TestCase -Name 'QMD policy requires exactly version 2.5.3' -Action {
    $ExactState = (Get-TestLocalState).Qmd
    $OldState = (Get-TestLocalState -QmdVersion '2.5.2').Qmd
    Assert-TestEqual -Actual (
      Get-QmdManagementAction -State $ExactState -RegistryAvailable $false
    ) -Expected 'Keep' -Message 'Exact QMD should be kept.'
    Assert-TestEqual -Actual (
      Get-QmdManagementAction -State $OldState -RegistryAvailable $true
    ) -Expected 'InstallRequired' -Message 'Old QMD should be replaced.'
    Assert-TestEqual -Actual (
      Get-QmdManagementAction -State $OldState -RegistryAvailable $false
    ) -Expected 'Unavailable' -Message 'Old offline QMD should fail.'
  }

  Invoke-TestCase -Name 'offline unsupported dependencies make execution impossible' -Action {
    $LocalState = Get-TestLocalState -NpmVersion '10.0.0' -QmdVersion '2.5.2'
    $NetworkState = Get-TestNetworkState -NpmRegistryAvailable $false
    $Plan = Get-QmdExecutionPlan -LocalState $LocalState -NetworkState $NetworkState
    Assert-TestCondition -Condition (-not $Plan.ExecutionPossible) -Message (
      'Unsupported offline dependencies should make the plan impossible.'
    )
    Assert-TestEqual -Actual $Plan.NpmAction -Expected 'Unavailable' -Message (
      'Offline npm action mismatch.'
    )
    Assert-TestEqual -Actual $Plan.QmdAction -Expected 'Blocked' -Message (
      'Offline QMD action mismatch.'
    )
  }

  Invoke-TestCase -Name 'install arguments are deterministic and strict' -Action {
    $NpmArguments = Get-NpmInstallArgumentList
    $QmdArguments = Get-QmdInstallArgumentList
    Assert-TestEqual -Actual ($NpmArguments -join '|') -Expected (
      'install|--global|npm@11.17.0'
    ) -Message 'npm install arguments mismatch.'
    Assert-TestCondition -Condition (
      $QmdArguments -contains '--strict-allow-scripts=true'
    ) -Message 'Strict allow-scripts is missing.'
    Assert-TestCondition -Condition (
      $QmdArguments -contains '@tobilu/qmd@2.5.3'
    ) -Message 'Pinned QMD package is missing.'
    $AllowScriptArguments = @(
      $QmdArguments | Where-Object { $_ -like '--allow-scripts=*' }
    )
    Assert-TestCondition -Condition ($AllowScriptArguments.Count -eq 1) -Message (
      'QMD lifecycle allowlist is missing.'
    )
  }

  Invoke-TestCase -Name 'Node changes never reuse stale npm state' -Action {
    $OriginalWinGetState = (Get-Command Get-WinGetNodePackageState).ScriptBlock
    try {
      Set-Item -LiteralPath Function:\Get-WinGetNodePackageState -Value {
        return 'Installed'
      }
      $LocalState = Get-TestLocalState -NpmVersion '10.0.0' -QmdVersion '1.0.0'
      $NetworkState = Get-TestNetworkState -WinGetAndNodeAvailable $true
      $Plan = Get-QmdExecutionPlan -LocalState $LocalState -NetworkState $NetworkState
      Assert-TestEqual -Actual $Plan.NodeAction -Expected 'Upgrade' -Message (
        'Node action mismatch.'
      )
      Assert-TestEqual -Actual $Plan.NpmAction -Expected 'RevalidateThenEnsure' -Message (
        'The plan reused stale npm state.'
      )
      Assert-TestEqual -Actual $Plan.QmdAction -Expected 'RevalidateThenEnsure' -Message (
        'The plan reused stale QMD state.'
      )
    }
    finally {
      Set-Item -LiteralPath Function:\Get-WinGetNodePackageState -Value (
        $OriginalWinGetState
      )
    }
  }

  Invoke-TestCase -Name 'dry run and WhatIf cannot reach mutation functions' -Action {
    $PreviewCount = 0
    Set-Item -LiteralPath Function:\Resolve-CollectionDirectory -Value {
      return 'C:\fixture'
    }
    Set-Item -LiteralPath Function:\Test-SupportedPlatform -Value {}
    Set-Item -LiteralPath Function:\Get-LocalPrerequisiteState -Value {
      return Get-TestLocalState
    }
    Set-Item -LiteralPath Function:\Get-NetworkState -Value {
      return Get-TestNetworkState
    }
    Set-Item -LiteralPath Function:\Get-QmdExecutionPlan -Value {
      return [pscustomobject]@{
        ExecutionPossible = $true
        Failures = @()
        NodeAction = 'Keep'
        NodeWillChange = $false
        NpmAction = 'Keep'
        QmdAction = 'Keep'
      }
    }
    Set-Item -LiteralPath Function:\Write-QmdExecutionPlan -Value {
      $script:PreviewCount++
    }
    $MutationGuard = {
      throw [System.InvalidOperationException]::new(
        'A mutation function was called during preview.'
      )
    }
    Set-Item -LiteralPath Function:\Invoke-NodeManagement -Value $MutationGuard
    Set-Item -LiteralPath Function:\Invoke-NpmManagement -Value $MutationGuard
    Set-Item -LiteralPath Function:\Invoke-QmdManagement -Value $MutationGuard
    Set-Item -LiteralPath Function:\Invoke-QmdWorkflow -Value $MutationGuard
    $script:PreviewCount = $PreviewCount

    function Invoke-PreviewMain {
      [CmdletBinding(SupportsShouldProcess = $true)]
      param(
        [Parameter(Mandatory)]
        [bool]$UseWhatIf,

        [Parameter(Mandatory)]
        [bool]$UseDryRun
      )

      $NativeArguments = @{
        Path = 'C:\fixture'
        Name = 'docs'
        Context = 'Documentation'
      }
      if ($UseDryRun) {
        $NativeArguments.DryRun = $true
      }
      if ($UseWhatIf) {
        $null = $PSCmdlet.ShouldProcess(
          'QMD preview test',
          'Verify native WhatIf propagation'
        )
      }
      $MainArguments = @{
        NativeArguments = $NativeArguments
        LegacyArguments = @()
        CmdletContext = $PSCmdlet
        WhatIfRequested = $UseWhatIf
      }
      return Invoke-QmdCollectionMain @MainArguments
    }

    $DryRunResult = Invoke-PreviewMain -UseWhatIf $false -UseDryRun $true
    $WhatIfResult = Invoke-PreviewMain -UseWhatIf $true -UseDryRun $false -WhatIf
    Assert-TestEqual -Actual $DryRunResult -Expected 0 -Message 'Dry run failed.'
    Assert-TestEqual -Actual $WhatIfResult -Expected 0 -Message 'WhatIf failed.'
    Assert-TestEqual -Actual $script:PreviewCount -Expected 2 -Message (
      'Preview renderer call count mismatch.'
    )
  }

  Invoke-TestCase -Name 'help and version entry points succeed' -Action {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $ExpectedHelpOutput = @(
      "Initialize-QmdCollection.ps1 $ScriptVersion"
      ''
      'usage: Initialize-QmdCollection.ps1 [--dry-run] [-v|--verbose]'
      '       (-p|--path) <COLLECTION-PATH>'
      '       (-n|--name) <COLLECTION-NAME>'
      '       (-c|--context) <COLLECTION-DESCRIPTION>'
      '       Initialize-QmdCollection.ps1 (-h|--help)'
      '       Initialize-QmdCollection.ps1 --version'
      ''
      'Initialize a QMD collection, add its context, and generate scoped vector embeddings.'
      ''
      'options:'
      '  -h, --help                    show this help message and exit'
      '  --version                     show the version and exit'
      '  --dry-run                     preview without mutations'
      '  -v, --verbose                 enable DEBUG logs'
      '  -p, --path <COLLECTION-PATH>  existing directory with Markdown files'
      '  -n, --name <COLLECTION-NAME>  letters, digits, underscores, or hyphens'
      '  -c, --context <DESCRIPTION>   non-empty collection context'
    )
    $OptionDescriptions = @(
      'show this help message and exit'
      'show the version and exit'
      'preview without mutations'
      'enable DEBUG logs'
      'existing directory with Markdown files'
      'letters, digits, underscores, or hyphens'
      'non-empty collection context'
    )

    $HelpOutput = @(
      & $PowerShellPath -NoLogo -NoProfile -File $TargetScript --help
    )
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 0 -Message 'Help exit code mismatch.'
    Assert-TestEqual -Actual ($HelpOutput -join "`n") -Expected (
      $ExpectedHelpOutput -join "`n"
    ) -Message 'GNU help output mismatch.'

    $OptionsHeaderIndex = [array]::IndexOf($HelpOutput, 'options:')
    $DescriptionColumns = @(
      for ($Index = 0; $Index -lt $OptionDescriptions.Count; $Index++) {
        $HelpOutput[$OptionsHeaderIndex + $Index + 1].IndexOf(
          $OptionDescriptions[$Index],
          [System.StringComparison]::Ordinal
        )
      }
    )
    Assert-TestEqual -Actual (
      @($DescriptionColumns | Select-Object -Unique).Count
    ) -Expected 1 -Message 'Option descriptions are not aligned.'

    $ShortHelpOutput = @(
      & $PowerShellPath -NoLogo -NoProfile -File $TargetScript -h
    )
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 0 -Message (
      'Short help exit code mismatch.'
    )
    Assert-TestEqual -Actual ($ShortHelpOutput -join "`n") -Expected (
      $ExpectedHelpOutput -join "`n"
    ) -Message 'Short help output mismatch.'

    $VersionOutput = @(
      & $PowerShellPath -NoLogo -NoProfile -File $TargetScript -Version
    )
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 0 -Message (
      'Version exit code mismatch.'
    )
    Assert-TestEqual -Actual $VersionOutput[-1] -Expected $ScriptVersion -Message (
      'Version output mismatch.'
    )
  }

  Invoke-TestCase -Name 'invalid command lines return exit code one' -Action {
    $PowerShellPath = (Get-Process -Id $PID).Path
    $NoArgumentOutput = @(
      & $PowerShellPath -NoLogo -NoProfile -File $TargetScript 2>&1
    )
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 1 -Message (
      'No-argument exit code mismatch.'
    )
    $TimestampPattern = '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
    Assert-TestEqual -Actual $NoArgumentOutput.Count -Expected 1 -Message (
      'No-argument diagnostic count mismatch.'
    )
    Assert-TestCondition -Condition (
      [string]$NoArgumentOutput[0] -match (
        "^$TimestampPattern \[ERROR\] No arguments were provided\. " +
        'Use --help for usage\.$'
      )
    ) -Message 'No-argument diagnostic timestamp format mismatch.'

    $InvalidNameArguments = @(
      '-NoLogo'
      '-NoProfile'
      '-File'
      $TargetScript
      '-Path'
      $RepositoryRoot
      '-Name'
      'docs/main'
      '-Context'
      'Documentation'
    )
    $null = & $PowerShellPath @InvalidNameArguments 2>&1
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 1 -Message (
      'Invalid-name exit code mismatch.'
    )

    $EmptyDirectory = Join-Path $TestRoot 'cli-empty'
    $null = New-Item -ItemType Directory -Path $EmptyDirectory
    $EmptyDirectoryArguments = @(
      '-NoLogo'
      '-NoProfile'
      '-File'
      $TargetScript
      '-Path'
      $EmptyDirectory
      '-Name'
      'docs'
      '-Context'
      'Documentation'
    )
    $null = & $PowerShellPath @EmptyDirectoryArguments 2>&1
    Assert-TestEqual -Actual $LASTEXITCODE -Expected 1 -Message (
      'No-Markdown exit code mismatch.'
    )
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
  "All $script:PassedCount Initialize-QmdCollection tests passed."
)
