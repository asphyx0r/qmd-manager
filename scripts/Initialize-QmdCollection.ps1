#Requires -Version 7.0
#Requires -PSEdition Core

<#
.SYNOPSIS
Initializes a QMD collection for an existing Markdown directory.

.DESCRIPTION
Validates a Windows 11 and PowerShell 7 environment, manages the supported
Node.js, npm, and QMD prerequisites, creates the collection, adds its root
context, and generates embeddings scoped to that collection.

.PARAMETER Path
Specifies the existing readable directory that contains at least one Markdown
file.

.PARAMETER Name
Specifies the collection name. Use only ASCII letters, digits, underscores,
and hyphens.

.PARAMETER Context
Specifies the non-empty collection context or description.

.PARAMETER DryRun
Evaluates and reports the execution plan without changing software or QMD data.

.PARAMETER Help
Displays the command-line help and exits.

.PARAMETER Version
Displays the script version and exits.

.EXAMPLE
.\scripts\Initialize-QmdCollection.ps1 -Path . -Name docs -Context 'Project documentation'

.EXAMPLE
.\scripts\Initialize-QmdCollection.ps1 --dry-run --path . --name docs --context 'Project documentation'

.NOTES
The legacy short and GNU-style options remain supported. Use -WhatIf for a
native PowerShell preview or -Confirm for one confirmation before mutations.
#>
[CmdletBinding(
  SupportsShouldProcess = $true,
  ConfirmImpact = 'Medium',
  PositionalBinding = $false
)]
param(
  [Parameter()]
  [Alias('p')]
  [string]$Path,

  [Parameter()]
  [Alias('n')]
  [string]$Name,

  [Parameter()]
  [Alias('c')]
  [string]$Context,

  [Parameter()]
  [Alias('v')]
  [switch]$DetailedLogging,

  [Parameter()]
  [Alias('h')]
  [switch]$Help,

  [Parameter()]
  [switch]$Version,

  [Parameter()]
  [switch]$DryRun,

  [Parameter(ValueFromRemainingArguments = $true)]
  [AllowEmptyCollection()]
  [object[]]$RemainingArguments = @()
)

$ScriptVersion = 'v0.1.0'
$UserAgent = "Initialize-QmdCollection/$($ScriptVersion.TrimStart('v'))"
$MinimumNodeVersion = [System.Management.Automation.SemanticVersion]::new(
  '22.22.2'
)
$MinimumNpmVersion = [System.Management.Automation.SemanticVersion]::new(
  '11.16.0'
)
$MaximumNpmVersionExclusive = [System.Management.Automation.SemanticVersion]::new(
  '13.0.0'
)
$BootstrapNpmVersion = [System.Management.Automation.SemanticVersion]::new(
  '11.17.0'
)
$RequiredQmdVersion = [System.Management.Automation.SemanticVersion]::new(
  '2.5.3'
)
$QmdAllowedInstallScripts = @(
  'better-sqlite3'
  'node-llama-cpp'
  'tree-sitter-go'
  'tree-sitter-python'
  'tree-sitter-rust'
  'tree-sitter-typescript'
  'tree-sitter-javascript'
) -join ','
$WinGetNoApplicationsFound = -1978335212
$WinGetNoApplicableUpdate = -1978335189
$NetworkTimeoutSeconds = 10
$script:VerboseEnabled = $false

$HelpLines = @(
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

function Write-QmdLog {
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

  $Prefix = switch ($Level) {
    'DEBUG' { '[DEBUG]' }
    'INFO' { '[INFO ]' }
    'WARN' { '[WARN ]' }
    'ERROR' { '[ERROR]' }
    'FATAL' { '[FATAL]' }
  }
  $Timestamp = [DateTimeOffset]::Now.ToString(
    'yyyy-MM-dd HH:mm:ss',
    [System.Globalization.CultureInfo]::InvariantCulture
  )
  $Line = '{0} {1} {2}' -f $Timestamp, $Prefix, $Message

  if ($Level -in @('ERROR', 'FATAL')) {
    [Console]::Error.WriteLine($Line)
  }
  else {
    [Console]::Out.WriteLine($Line)
  }
}

function Get-ParsedArgumentSet {
  param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$NativeArguments,

    [Parameter()]
    [AllowEmptyCollection()]
    [object[]]$Tokens = @()
  )

  $Parsed = [ordered]@{
    Help = $false
    Version = $false
    DryRun = $false
    Verbose = $false
    Path = $null
    Name = $null
    Context = $null
  }
  $Seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
  )
  $NativeOptionMap = @(
    [pscustomobject]@{
      Key = 'Path'
      LogicalName = 'Path'
      Token = '-Path'
      IsSwitch = $false
    }
    [pscustomobject]@{
      Key = 'Name'
      LogicalName = 'Name'
      Token = '-Name'
      IsSwitch = $false
    }
    [pscustomobject]@{
      Key = 'Context'
      LogicalName = 'Context'
      Token = '-Context'
      IsSwitch = $false
    }
    [pscustomobject]@{
      Key = 'DetailedLogging'
      LogicalName = 'Verbose'
      Token = '-v'
      IsSwitch = $true
    }
    [pscustomobject]@{
      Key = 'Verbose'
      LogicalName = 'Verbose'
      Token = '-Verbose'
      IsSwitch = $true
    }
    [pscustomobject]@{
      Key = 'Help'
      LogicalName = 'Help'
      Token = '-Help'
      IsSwitch = $true
    }
    [pscustomobject]@{
      Key = 'Version'
      LogicalName = 'Version'
      Token = '-Version'
      IsSwitch = $true
    }
    [pscustomobject]@{
      Key = 'DryRun'
      LogicalName = 'DryRun'
      Token = '-DryRun'
      IsSwitch = $true
    }
  )

  foreach ($NativeOption in $NativeOptionMap) {
    if ($NativeArguments.Keys -notcontains $NativeOption.Key) {
      continue
    }

    $NativeValue = $NativeArguments[$NativeOption.Key]
    if ($NativeOption.IsSwitch -and -not [bool]$NativeValue) {
      continue
    }

    if (-not $Seen.Add($NativeOption.LogicalName)) {
      throw [System.ArgumentException]::new(
        "Option '$($NativeOption.Token)' duplicates the " +
        "'$($NativeOption.LogicalName)' option."
      )
    }

    if ($NativeOption.IsSwitch) {
      $Parsed[$NativeOption.LogicalName] = $true
    }
    else {
      $Parsed[$NativeOption.LogicalName] = [string]$NativeValue
    }
  }

  $KnownOptionTokens = @(
    '-h'
    '--help'
    '--version'
    '--dry-run'
    '-v'
    '--verbose'
    '-p'
    '--path'
    '-n'
    '--name'
    '-c'
    '--context'
  )

  for ($Index = 0; $Index -lt $Tokens.Count; $Index++) {
    $Token = [string]$Tokens[$Index]

    if ($Token -match '^--[^=]+=') {
      throw [System.ArgumentException]::new(
        "The --option=value syntax is not supported: '$Token'."
      )
    }

    $LogicalName = $null
    $RequiresValue = $false

    switch ($Token) {
      '-h' {
        $LogicalName = 'Help'
      }
      '--help' {
        $LogicalName = 'Help'
      }
      '--version' {
        $LogicalName = 'Version'
      }
      '--dry-run' {
        $LogicalName = 'DryRun'
      }
      '-v' {
        $LogicalName = 'Verbose'
      }
      '--verbose' {
        $LogicalName = 'Verbose'
      }
      '-p' {
        $LogicalName = 'Path'
        $RequiresValue = $true
      }
      '--path' {
        $LogicalName = 'Path'
        $RequiresValue = $true
      }
      '-n' {
        $LogicalName = 'Name'
        $RequiresValue = $true
      }
      '--name' {
        $LogicalName = 'Name'
        $RequiresValue = $true
      }
      '-c' {
        $LogicalName = 'Context'
        $RequiresValue = $true
      }
      '--context' {
        $LogicalName = 'Context'
        $RequiresValue = $true
      }
      default {
        if ($Token.StartsWith('-')) {
          throw [System.ArgumentException]::new("Unknown option: '$Token'.")
        }

        throw [System.ArgumentException]::new(
          "Unexpected positional argument: '$Token'."
        )
      }
    }

    if (-not $Seen.Add($LogicalName)) {
      throw [System.ArgumentException]::new(
        "Option '$Token' duplicates the '$LogicalName' option."
      )
    }

    if ($RequiresValue) {
      if ($Index + 1 -ge $Tokens.Count) {
        throw [System.ArgumentException]::new(
          "Option '$Token' requires a non-empty value."
        )
      }

      $Value = [string]$Tokens[$Index + 1]
      if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value -in $KnownOptionTokens -or
        $Value -match '^--[^=]+='
      ) {
        throw [System.ArgumentException]::new(
          "Option '$Token' requires a non-empty value."
        )
      }

      $Parsed[$LogicalName] = $Value
      $Index++
    }
    else {
      $Parsed[$LogicalName] = $true
    }
  }

  if (($Parsed.Help -or $Parsed.Version) -and $Seen.Count -ne 1) {
    $ExclusiveOption = if ($Parsed.Help) { '--help' } else { '--version' }
    throw [System.ArgumentException]::new(
      "Option '$ExclusiveOption' must be used alone."
    )
  }

  $Parsed['ProvidedOptionCount'] = $Seen.Count
  return [pscustomobject]$Parsed
}

function Test-SupportedPlatform {
  if (-not $IsWindows) {
    throw [System.PlatformNotSupportedException]::new(
      'This script supports Windows 11 only.'
    )
  }

  if ($PSVersionTable.PSVersion.Major -ne 7) {
    throw [System.PlatformNotSupportedException]::new(
      'This script requires PowerShell 7.x exactly.'
    )
  }

  $CurrentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  try {
    $CurrentVersion = Get-ItemProperty -LiteralPath $CurrentVersionPath
    $BuildNumber = [int]$CurrentVersion.CurrentBuildNumber
    $InstallationType = [string]$CurrentVersion.InstallationType
  }
  catch {
    $ErrorRecord = $_
    throw [System.PlatformNotSupportedException]::new(
      "Unable to verify Windows 11: $($ErrorRecord.Exception.Message)"
    )
  }

  if ($InstallationType -ne 'Client' -or $BuildNumber -lt 22000) {
    throw [System.PlatformNotSupportedException]::new(
      'This script supports Windows 11 client editions only.'
    )
  }

  Write-QmdLog -Level 'INFO' -Message (
    "Validated Windows 11 build $BuildNumber and PowerShell " +
    "$($PSVersionTable.PSVersion)."
  )
}

function Test-RequiredArgumentSet {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$ParsedArguments
  )

  $Missing = [System.Collections.Generic.List[string]]::new()
  if ([string]::IsNullOrWhiteSpace([string]$ParsedArguments.Path)) {
    $Missing.Add('--path')
  }
  if ([string]::IsNullOrWhiteSpace([string]$ParsedArguments.Name)) {
    $Missing.Add('--name')
  }
  if ([string]::IsNullOrWhiteSpace([string]$ParsedArguments.Context)) {
    $Missing.Add('--context')
  }

  if ($Missing.Count -gt 0) {
    throw [System.ArgumentException]::new(
      "Missing required option(s): $($Missing -join ', ')."
    )
  }

  if ([string]$ParsedArguments.Name -notmatch '^[A-Za-z0-9_-]+$') {
    throw [System.ArgumentException]::new(
      'Collection name must contain only ASCII letters, digits, underscores, ' +
      'or hyphens.'
    )
  }
}

function Resolve-CollectionDirectory {
  param(
    [Parameter(Mandatory)]
    [string]$LiteralPath
  )

  Write-QmdLog -Level 'INFO' -Message "Validating collection path '$LiteralPath'."

  if (-not (Test-Path -LiteralPath $LiteralPath)) {
    throw [System.IO.DirectoryNotFoundException]::new(
      "Collection path does not exist: '$LiteralPath'."
    )
  }

  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
    throw [System.IO.IOException]::new(
      "Collection path is not a directory: '$LiteralPath'."
    )
  }

  try {
    $ResolvedPath = (Resolve-Path -LiteralPath $LiteralPath).ProviderPath
    $CanonicalPath = [System.IO.Path]::GetFullPath($ResolvedPath)
    $null = Get-ChildItem -LiteralPath $CanonicalPath -Force -ErrorAction Stop |
      Select-Object -First 1
  }
  catch {
    $ErrorRecord = $_
    throw [System.UnauthorizedAccessException]::new(
      "Collection path is not readable: '$LiteralPath'. " +
      $ErrorRecord.Exception.Message
    )
  }

  try {
    $MarkdownSearch = @{
      LiteralPath = $CanonicalPath
      Filter = '*.md'
      File = $true
      Recurse = $true
      ErrorAction = 'Stop'
    }
    $MarkdownFile = Get-ChildItem @MarkdownSearch |
      Select-Object -First 1
  }
  catch {
    $ErrorRecord = $_
    throw [System.UnauthorizedAccessException]::new(
      "Unable to search the collection path for Markdown files: " +
      "'$LiteralPath'. $($ErrorRecord.Exception.Message)"
    )
  }

  if ($null -eq $MarkdownFile) {
    throw [System.IO.InvalidDataException]::new(
      "Collection path contains no Markdown files: '$LiteralPath'."
    )
  }

  Write-QmdLog -Level 'INFO' -Message "Collection path resolved to '$CanonicalPath'."
  return $CanonicalPath
}

function Get-ApplicationPath {
  param(
    [Parameter(Mandatory)]
    [string]$Name
  )

  $Command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $Command) {
    return $null
  }

  return [System.IO.Path]::GetFullPath($Command.Source)
}

function Invoke-NativeCapture {
  param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [Parameter()]
    [string[]]$ArgumentList = @()
  )

  $NativeOutput = @(& $FilePath @ArgumentList 2>&1)
  $ExitCode = $LASTEXITCODE
  $OutputLines = @(
    foreach ($OutputItem in $NativeOutput) {
      [string]$OutputItem
    }
  )

  return [pscustomobject]@{
    ExitCode = [int]$ExitCode
    Output = $OutputLines
  }
}

function ConvertTo-SemanticVersion {
  param(
    [Parameter(Mandatory)]
    [string]$Value
  )

  $Normalized = $Value.Trim()
  if ($Normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
    $Normalized = $Normalized.Substring(1)
  }

  try {
    return [System.Management.Automation.SemanticVersion]::new($Normalized)
  }
  catch {
    $ErrorRecord = $_
    Write-QmdLog -Level 'DEBUG' -Message (
      "Unable to parse semantic version '$Value': " +
      $ErrorRecord.Exception.Message
    )
    return $null
  }
}

function Get-VersionFromOutput {
  param(
    [Parameter(Mandatory)]
    [string[]]$Output
  )

  foreach ($Line in $Output) {
    $TrimmedLine = $Line.Trim()
    if ($TrimmedLine -match '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
      return ConvertTo-SemanticVersion -Value $TrimmedLine
    }
  }

  return $null
}

function Get-NpmGlobalPrefix {
  param(
    [Parameter(Mandatory)]
    [string]$NpmPath
  )

  $Result = Invoke-NativeCapture -FilePath $NpmPath -ArgumentList @(
    'prefix'
    '--global'
  )
  if ($Result.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new(
      "npm prefix --global failed with exit code $($Result.ExitCode)."
    )
  }

  $Prefix = $Result.Output |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1
  if ([string]::IsNullOrWhiteSpace([string]$Prefix)) {
    throw [System.InvalidOperationException]::new(
      'npm prefix --global returned no path.'
    )
  }

  return [System.IO.Path]::GetFullPath(([string]$Prefix).Trim())
}

function Test-PathEquality {
  param(
    [Parameter(Mandatory)]
    [string]$FirstPath,

    [Parameter(Mandatory)]
    [string]$SecondPath
  )

  $FirstFullPath = [System.IO.Path]::GetFullPath($FirstPath).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $SecondFullPath = [System.IO.Path]::GetFullPath($SecondPath).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )

  return $FirstFullPath.Equals(
    $SecondFullPath,
    [System.StringComparison]::OrdinalIgnoreCase
  )
}

function Get-QmdLocalState {
  param(
    [AllowNull()]
    [string]$NpmPrefix,

    [AllowNull()]
    [string]$ResolvedQmdPath
  )

  $State = [ordered]@{
    PackageInstalled = $false
    PackageVersion = $null
    ExpectedCommandPath = $null
    ResolvedFromNpmPrefix = $false
    CommandFunctional = $false
  }

  if ([string]::IsNullOrWhiteSpace($NpmPrefix)) {
    return [pscustomobject]$State
  }

  $PackageJsonPath = Join-Path -Path $NpmPrefix -ChildPath (
    'node_modules\@tobilu\qmd\package.json'
  )
  $ExpectedCommandPath = Join-Path -Path $NpmPrefix -ChildPath 'qmd.cmd'
  $State.ExpectedCommandPath = [System.IO.Path]::GetFullPath($ExpectedCommandPath)

  if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
    return [pscustomobject]$State
  }

  try {
    $PackageMetadata = Get-Content -LiteralPath $PackageJsonPath -Raw |
      ConvertFrom-Json
    $PackageVersion = ConvertTo-SemanticVersion -Value (
      [string]$PackageMetadata.version
    )
  }
  catch {
    $ErrorRecord = $_
    Write-QmdLog -Level 'DEBUG' -Message (
      "Unable to read QMD package metadata: $($ErrorRecord.Exception.Message)"
    )
    return [pscustomobject]$State
  }

  if ($null -eq $PackageVersion) {
    return [pscustomobject]$State
  }

  $State.PackageInstalled = $true
  $State.PackageVersion = $PackageVersion

  if (
    -not [string]::IsNullOrWhiteSpace($ResolvedQmdPath) -and
    (Test-Path -LiteralPath $ExpectedCommandPath -PathType Leaf) -and
    (Test-PathEquality -FirstPath $ResolvedQmdPath -SecondPath $ExpectedCommandPath)
  ) {
    $State.ResolvedFromNpmPrefix = $true
    $VersionResult = Invoke-NativeCapture -FilePath $ResolvedQmdPath -ArgumentList @(
      '--version'
    )
    $State.CommandFunctional = $VersionResult.ExitCode -eq 0
  }

  return [pscustomobject]$State
}

function Get-LocalPrerequisiteState {
  Write-QmdLog -Level 'INFO' -Message 'Detecting local prerequisite executables.'

  $WingetPath = Get-ApplicationPath -Name 'winget.exe'
  $NodePath = Get-ApplicationPath -Name 'node.exe'
  $NpmPath = Get-ApplicationPath -Name 'npm.cmd'
  $QmdPath = Get-ApplicationPath -Name 'qmd.cmd'

  $NodeFunctional = $false
  $NodeVersion = $null
  if ($null -ne $NodePath) {
    $NodeResult = Invoke-NativeCapture -FilePath $NodePath -ArgumentList @(
      '--version'
    )
    $NodeFunctional = $NodeResult.ExitCode -eq 0
    if ($NodeFunctional) {
      $NodeVersion = Get-VersionFromOutput -Output $NodeResult.Output
      $NodeFunctional = $null -ne $NodeVersion
    }
  }

  $NpmFunctional = $false
  $NpmVersion = $null
  $NpmPrefix = $null
  if ($null -ne $NpmPath) {
    $NpmResult = Invoke-NativeCapture -FilePath $NpmPath -ArgumentList @(
      '--version'
    )
    $NpmFunctional = $NpmResult.ExitCode -eq 0
    if ($NpmFunctional) {
      $NpmVersion = Get-VersionFromOutput -Output $NpmResult.Output
      $NpmFunctional = $null -ne $NpmVersion
    }

    if ($NpmFunctional) {
      try {
        $NpmPrefix = Get-NpmGlobalPrefix -NpmPath $NpmPath
      }
      catch {
        $ErrorRecord = $_
        Write-QmdLog -Level 'DEBUG' -Message $ErrorRecord.Exception.Message
        $NpmFunctional = $false
      }
    }
  }

  $QmdState = Get-QmdLocalState -NpmPrefix $NpmPrefix -ResolvedQmdPath $QmdPath

  if ($null -eq $WingetPath) {
    Write-QmdLog -Level 'WARN' -Message 'winget.exe was not found.'
  }
  else {
    Write-QmdLog -Level 'INFO' -Message "Detected winget.exe at '$WingetPath'."
  }

  if ($NodeFunctional) {
    Write-QmdLog -Level 'INFO' -Message "Detected Node.js $NodeVersion."
  }
  else {
    Write-QmdLog -Level 'WARN' -Message 'A functional node.exe was not found.'
  }

  if ($NpmFunctional) {
    Write-QmdLog -Level 'INFO' -Message "Detected npm $NpmVersion."
  }
  else {
    Write-QmdLog -Level 'WARN' -Message 'A functional npm.cmd was not found.'
  }

  if ($QmdState.CommandFunctional) {
    Write-QmdLog -Level 'INFO' -Message (
      "Detected npm-global QMD $($QmdState.PackageVersion)."
    )
  }
  else {
    Write-QmdLog -Level 'WARN' -Message (
      'A functional npm-global qmd.cmd was not found.'
    )
  }

  return [pscustomobject]@{
    WingetPath = $WingetPath
    NodePath = $NodePath
    NodeFunctional = $NodeFunctional
    NodeVersion = $NodeVersion
    NpmPath = $NpmPath
    NpmFunctional = $NpmFunctional
    NpmVersion = $NpmVersion
    NpmPrefix = $NpmPrefix
    QmdPath = $QmdPath
    Qmd = $QmdState
  }
}

function Test-HttpsAccess {
  param(
    [Parameter(Mandatory)]
    [uri]$Uri
  )

  $Handler = [System.Net.Http.HttpClientHandler]::new()
  $Handler.AllowAutoRedirect = $true
  $Client = [System.Net.Http.HttpClient]::new($Handler)
  $Client.Timeout = [TimeSpan]::FromSeconds($NetworkTimeoutSeconds)
  $Request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Get,
    $Uri
  )
  $Request.Headers.UserAgent.ParseAdd($UserAgent)

  try {
    $Response = $Client.SendAsync(
      $Request,
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()
    try {
      return [int]$Response.StatusCode -ge 200 -and
        [int]$Response.StatusCode -lt 400
    }
    finally {
      $Response.Dispose()
    }
  }
  catch {
    $ErrorRecord = $_
    Write-QmdLog -Level 'DEBUG' -Message (
      "HTTPS check failed for '$Uri': $($ErrorRecord.Exception.Message)"
    )
    return $false
  }
  finally {
    $Request.Dispose()
    $Client.Dispose()
    $Handler.Dispose()
  }
}

function Get-NetworkState {
  Write-QmdLog -Level 'INFO' -Message 'Testing required HTTPS access.'

  $WingetSourceAvailable = Test-HttpsAccess -Uri (
    'https://cdn.winget.microsoft.com/cache/source2.msix'
  )
  $NodeDownloadAvailable = Test-HttpsAccess -Uri (
    'https://nodejs.org/dist/index.json'
  )
  $WinGetAndNodeAvailable = $WingetSourceAvailable -and $NodeDownloadAvailable

  if ($WinGetAndNodeAvailable) {
    Write-QmdLog -Level 'INFO' -Message (
      'WinGet source and Node.js download access are available.'
    )
  }
  else {
    Write-QmdLog -Level 'WARN' -Message (
      'WinGet source or Node.js download access is unavailable.'
    )
  }

  $NpmRegistryAvailable = Test-HttpsAccess -Uri (
    'https://registry.npmjs.org/-/ping'
  )

  if ($NpmRegistryAvailable) {
    Write-QmdLog -Level 'INFO' -Message (
      'npm registry access is available for deterministic package management.'
    )
  }
  else {
    Write-QmdLog -Level 'WARN' -Message 'npm registry access is unavailable.'
  }

  $HuggingFaceAvailable = Test-HttpsAccess -Uri (
    'https://huggingface.co/api/models/ggml-org/embeddinggemma-300M-GGUF'
  )
  if ($HuggingFaceAvailable) {
    Write-QmdLog -Level 'INFO' -Message 'Hugging Face access is available.'
  }
  else {
    Write-QmdLog -Level 'WARN' -Message (
      'Hugging Face access is unavailable; a cached embedding model may still work.'
    )
  }

  return [pscustomobject]@{
    WinGetAndNodeAvailable = $WinGetAndNodeAvailable
    NpmRegistryAvailable = $NpmRegistryAvailable
    HuggingFaceAvailable = $HuggingFaceAvailable
  }
}

function Get-WinGetNodePackageState {
  param(
    [Parameter(Mandatory)]
    [string]$WingetPath
  )

  Write-QmdLog -Level 'INFO' -Message (
    'Checking whether WinGet records OpenJS.NodeJS as installed.'
  )
  $Result = Invoke-NativeCapture -FilePath $WingetPath -ArgumentList @(
    'list'
    '--id'
    'OpenJS.NodeJS'
    '--exact'
    '--disable-interactivity'
  )

  if ($Result.ExitCode -eq 0) {
    Write-QmdLog -Level 'INFO' -Message (
      'WinGet records OpenJS.NodeJS as installed.'
    )
    return 'Installed'
  }

  if ($Result.ExitCode -eq $WinGetNoApplicationsFound) {
    Write-QmdLog -Level 'INFO' -Message (
      'WinGet does not record OpenJS.NodeJS as installed.'
    )
    return 'Absent'
  }

  throw [System.InvalidOperationException]::new(
    "winget list failed with exit code $($Result.ExitCode)."
  )
}

function Sync-ProcessPath {
  $PathValues = [System.Collections.Generic.List[string]]::new()
  $SeenPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
  )

  foreach ($Scope in @('Machine', 'User', 'Process')) {
    $ScopePath = if ($Scope -eq 'Process') {
      $env:PATH
    }
    else {
      [System.Environment]::GetEnvironmentVariable('Path', $Scope)
    }

    foreach ($PathEntry in ([string]$ScopePath -split ';')) {
      $TrimmedEntry = $PathEntry.Trim()
      if (
        -not [string]::IsNullOrWhiteSpace($TrimmedEntry) -and
        $SeenPaths.Add($TrimmedEntry)
      ) {
        $PathValues.Add($TrimmedEntry)
      }
    }
  }

  $env:PATH = $PathValues -join ';'
  Write-QmdLog -Level 'DEBUG' -Message (
    'Refreshed PATH for the current process only.'
  )
}

function Add-ProcessPathPrefix {
  param(
    [Parameter(Mandatory)]
    [string]$Prefix
  )

  $NormalizedPrefix = [System.IO.Path]::GetFullPath($Prefix).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $PathValues = [System.Collections.Generic.List[string]]::new()
  $PathValues.Add($NormalizedPrefix)

  foreach ($PathEntry in ([string]$env:PATH -split ';')) {
    $TrimmedEntry = $PathEntry.Trim()
    if (
      -not [string]::IsNullOrWhiteSpace($TrimmedEntry) -and
      -not $TrimmedEntry.TrimEnd('\', '/').Equals(
        $NormalizedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
      )
    ) {
      $PathValues.Add($TrimmedEntry)
    }
  }

  $env:PATH = $PathValues -join ';'
  Write-QmdLog -Level 'DEBUG' -Message (
    "Prepended npm global prefix '$NormalizedPrefix' to the process PATH."
  )
}

function Get-VerifiedNodeAndNpmState {
  $NodePath = Get-ApplicationPath -Name 'node.exe'
  if ($null -eq $NodePath) {
    throw [System.InvalidOperationException]::new(
      'node.exe is not available after Node.js management.'
    )
  }

  Write-QmdLog -Level 'INFO' -Message 'Verifying Node.js.'
  $NodeResult = Invoke-NativeCapture -FilePath $NodePath -ArgumentList @(
    '--version'
  )
  if ($NodeResult.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new(
      "node.exe --version failed with exit code $($NodeResult.ExitCode)."
    )
  }

  $NodeVersion = Get-VersionFromOutput -Output $NodeResult.Output
  if ($null -eq $NodeVersion) {
    throw [System.InvalidOperationException]::new(
      'Unable to parse the installed Node.js version.'
    )
  }
  if ($NodeVersion -lt $MinimumNodeVersion) {
    throw [System.InvalidOperationException]::new(
      "Node.js $NodeVersion is below the required version $MinimumNodeVersion."
    )
  }
  Write-QmdLog -Level 'INFO' -Message "Validated Node.js $NodeVersion."

  $NpmPath = Get-ApplicationPath -Name 'npm.cmd'
  if ($null -eq $NpmPath) {
    throw [System.InvalidOperationException]::new(
      'npm.cmd is not available after Node.js management.'
    )
  }

  Write-QmdLog -Level 'INFO' -Message 'Verifying npm.'
  $NpmResult = Invoke-NativeCapture -FilePath $NpmPath -ArgumentList @(
    '--version'
  )
  if ($NpmResult.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new(
      "npm.cmd --version failed with exit code $($NpmResult.ExitCode)."
    )
  }

  $NpmVersion = Get-VersionFromOutput -Output $NpmResult.Output
  if ($null -eq $NpmVersion) {
    throw [System.InvalidOperationException]::new(
      'Unable to parse the installed npm version.'
    )
  }
  Write-QmdLog -Level 'INFO' -Message "Validated npm $NpmVersion."

  return [pscustomobject]@{
    NodePath = $NodePath
    NodeVersion = $NodeVersion
    NpmPath = $NpmPath
    NpmVersion = $NpmVersion
  }
}

function Invoke-NodeManagement {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$LocalState,

    [Parameter(Mandatory)]
    [pscustomobject]$ExecutionPlan
  )

  if ($ExecutionPlan.NodeAction -in @('Install', 'Upgrade')) {
    if ($ExecutionPlan.NodeAction -eq 'Upgrade') {
      $WingetArguments = @(
        'upgrade'
        '--id'
        'OpenJS.NodeJS'
        '--exact'
        '--source'
        'winget'
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--silent'
        '--disable-interactivity'
      )
      Write-QmdLog -Level 'INFO' -Message (
        'Updating OpenJS.NodeJS to the latest WinGet version.'
      )
    }
    else {
      $WingetArguments = @(
        'install'
        '--id'
        'OpenJS.NodeJS'
        '--exact'
        '--source'
        'winget'
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--silent'
        '--disable-interactivity'
      )
      Write-QmdLog -Level 'INFO' -Message (
        'Installing the latest OpenJS.NodeJS package with WinGet.'
      )
    }

    $null = & $LocalState.WingetPath @WingetArguments
    $WingetExitCode = $LASTEXITCODE
    if (
      $WingetExitCode -ne 0 -and
      $WingetExitCode -ne $WinGetNoApplicableUpdate
    ) {
      throw [System.InvalidOperationException]::new(
        "WinGet Node.js management failed with exit code $WingetExitCode."
      )
    }

    if ($WingetExitCode -eq $WinGetNoApplicableUpdate) {
      Write-QmdLog -Level 'INFO' -Message (
        'WinGet reported no applicable Node.js update; validating the local installation.'
      )
    }
    else {
      Write-QmdLog -Level 'INFO' -Message (
        'WinGet Node.js management completed successfully.'
      )
    }
  }
  else {
    Write-QmdLog -Level 'WARN' -Message (
      'Using the local Node.js installation because online management is unavailable.'
    )
  }

  Sync-ProcessPath
  return Get-VerifiedNodeAndNpmState
}

function Test-NpmVersionSupported {
  param(
    [AllowNull()]
    [System.Management.Automation.SemanticVersion]$Version
  )

  return (
    $null -ne $Version -and
    $Version -ge $MinimumNpmVersion -and
    $Version -lt $MaximumNpmVersionExclusive
  )
}

function Test-RequiredQmdState {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$State
  )

  return (
    $State.PackageInstalled -and
    $State.ResolvedFromNpmPrefix -and
    $State.CommandFunctional -and
    $null -ne $State.PackageVersion -and
    $State.PackageVersion -eq $RequiredQmdVersion
  )
}

function Get-NpmManagementAction {
  param(
    [Parameter(Mandatory)]
    [bool]$Functional,

    [AllowNull()]
    [System.Management.Automation.SemanticVersion]$Version,

    [Parameter(Mandatory)]
    [bool]$RegistryAvailable
  )

  if ($Functional -and (Test-NpmVersionSupported -Version $Version)) {
    return 'Keep'
  }

  if ($RegistryAvailable) {
    return 'InstallBootstrap'
  }

  return 'Unavailable'
}

function Get-QmdManagementAction {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$State,

    [Parameter(Mandatory)]
    [bool]$RegistryAvailable
  )

  if (Test-RequiredQmdState -State $State) {
    return 'Keep'
  }

  if ($RegistryAvailable) {
    return 'InstallRequired'
  }

  return 'Unavailable'
}

function Get-NpmInstallArgumentList {
  return @(
    'install'
    '--global'
    "npm@$BootstrapNpmVersion"
  )
}

function Get-QmdInstallArgumentList {
  return @(
    'install'
    '--global'
    '--strict-allow-scripts=true'
    "--allow-scripts=$QmdAllowedInstallScripts"
    "@tobilu/qmd@$RequiredQmdVersion"
  )
}

function Get-QmdExecutionPlan {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$LocalState,

    [Parameter(Mandatory)]
    [pscustomobject]$NetworkState
  )

  $Failures = [System.Collections.Generic.List[string]]::new()
  $NodeWillChange = $false

  if ($NetworkState.WinGetAndNodeAvailable) {
    if ($null -eq $LocalState.WingetPath) {
      $NodeAction = 'Unavailable'
      $Failures.Add(
        'winget.exe is required to apply the online Node.js policy.'
      )
    }
    else {
      $PackageState = Get-WinGetNodePackageState -WingetPath (
        $LocalState.WingetPath
      )
      $NodeAction = if ($PackageState -eq 'Installed') {
        'Upgrade'
      }
      else {
        'Install'
      }
      $NodeWillChange = $true
    }
  }
  else {
    $NodeAction = 'Keep'
    if (
      -not $LocalState.NodeFunctional -or
      $null -eq $LocalState.NodeVersion -or
      $LocalState.NodeVersion -lt $MinimumNodeVersion
    ) {
      $NodeAction = 'Unavailable'
      $Failures.Add(
        "Node.js $MinimumNodeVersion or later is required while online " +
        'management is unavailable.'
      )
    }
  }

  if ($NodeWillChange) {
    $NpmAction = if ($NetworkState.NpmRegistryAvailable) {
      'RevalidateThenEnsure'
    }
    else {
      'RevalidateOffline'
    }
    $QmdAction = $NpmAction
  }
  elseif ($NodeAction -eq 'Unavailable') {
    $NpmAction = 'Blocked'
    $QmdAction = 'Blocked'
  }
  else {
    $NpmActionArguments = @{
      Functional = $LocalState.NpmFunctional
      Version = $LocalState.NpmVersion
      RegistryAvailable = $NetworkState.NpmRegistryAvailable
    }
    $NpmAction = Get-NpmManagementAction @NpmActionArguments

    if ($NpmAction -eq 'Unavailable') {
      $Failures.Add(
        "npm must be between $MinimumNpmVersion inclusive and " +
        "$MaximumNpmVersionExclusive exclusive while the registry is unavailable."
      )
      $QmdAction = 'Blocked'
    }
    elseif ($NpmAction -eq 'InstallBootstrap') {
      $QmdAction = 'RevalidateThenEnsure'
    }
    else {
      $QmdActionArguments = @{
        State = $LocalState.Qmd
        RegistryAvailable = $NetworkState.NpmRegistryAvailable
      }
      $QmdAction = Get-QmdManagementAction @QmdActionArguments
      if ($QmdAction -eq 'Unavailable') {
        $Failures.Add(
          "npm-global QMD $RequiredQmdVersion is required while the registry " +
          'is unavailable.'
        )
      }
    }
  }

  return [pscustomobject]@{
    ExecutionPossible = $Failures.Count -eq 0
    Failures = $Failures.ToArray()
    NodeAction = $NodeAction
    NodeWillChange = $NodeWillChange
    NpmAction = $NpmAction
    QmdAction = $QmdAction
  }
}

function Write-QmdExecutionPlan {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$ExecutionPlan,

    [Parameter(Mandatory)]
    [pscustomobject]$LocalState,

    [Parameter(Mandatory)]
    [pscustomobject]$NetworkState,

    [Parameter(Mandatory)]
    [string]$CollectionPath,

    [Parameter(Mandatory)]
    [string]$CollectionName
  )

  Write-QmdLog -Level 'INFO' -Message (
    'Preview enabled; no installation, update, or QMD mutation will be executed.'
  )

  switch ($ExecutionPlan.NodeAction) {
    'Install' {
      Write-QmdLog -Level 'INFO' -Message (
        'Would install OpenJS.NodeJS with WinGet and then re-detect Node.js and npm.'
      )
    }
    'Upgrade' {
      Write-QmdLog -Level 'INFO' -Message (
        'Would upgrade OpenJS.NodeJS with WinGet and then re-detect Node.js and npm.'
      )
    }
    'Keep' {
      Write-QmdLog -Level 'INFO' -Message (
        "Would keep local Node.js $($LocalState.NodeVersion)."
      )
    }
  }

  switch ($ExecutionPlan.NpmAction) {
    'Keep' {
      Write-QmdLog -Level 'INFO' -Message (
        "Would keep supported npm $($LocalState.NpmVersion)."
      )
    }
    'InstallBootstrap' {
      Write-QmdLog -Level 'INFO' -Message (
        "Would run: npm.cmd install --global npm@$BootstrapNpmVersion"
      )
    }
    'RevalidateThenEnsure' {
      Write-QmdLog -Level 'INFO' -Message (
        'Would re-detect npm after prerequisite management and install ' +
        "npm@$BootstrapNpmVersion only if the detected version is outside " +
        "[$MinimumNpmVersion, $MaximumNpmVersionExclusive)."
      )
    }
    'RevalidateOffline' {
      Write-QmdLog -Level 'WARN' -Message (
        'Would re-detect npm after Node.js management; the real run will fail ' +
        'if the bundled version is outside the supported range.'
      )
    }
  }

  switch ($ExecutionPlan.QmdAction) {
    'Keep' {
      Write-QmdLog -Level 'INFO' -Message (
        "Would keep npm-global QMD $RequiredQmdVersion."
      )
    }
    'InstallRequired' {
      $QmdArguments = Get-QmdInstallArgumentList
      Write-QmdLog -Level 'INFO' -Message (
        "Would run: npm.cmd $($QmdArguments -join ' ')"
      )
    }
    'RevalidateThenEnsure' {
      Write-QmdLog -Level 'INFO' -Message (
        'Would re-detect QMD after npm management and install exactly ' +
        "@tobilu/qmd@$RequiredQmdVersion with strict lifecycle-script approval " +
        'only if required.'
      )
    }
    'RevalidateOffline' {
      Write-QmdLog -Level 'WARN' -Message (
        'Would re-detect QMD after Node.js management; the real run will fail ' +
        "unless npm-global QMD $RequiredQmdVersion is already functional."
      )
    }
  }

  foreach ($Failure in $ExecutionPlan.Failures) {
    Write-QmdLog -Level 'FATAL' -Message $Failure
  }

  if (-not $NetworkState.HuggingFaceAvailable) {
    Write-QmdLog -Level 'WARN' -Message (
      'Embedding would still be attempted because the model may already be cached.'
    )
  }

  if ($ExecutionPlan.ExecutionPossible) {
    Write-QmdLog -Level 'INFO' -Message (
      "Would run: qmd.cmd collection add `"$CollectionPath`" --name " +
      "`"$CollectionName`" --mask `"**/*.md`""
    )
    Write-QmdLog -Level 'INFO' -Message (
      "Would run: qmd.cmd context add `"qmd://$CollectionName`" " +
      '"<COLLECTION-DESCRIPTION>"'
    )
    Write-QmdLog -Level 'INFO' -Message (
      "Would run: qmd.cmd embed -f -c `"$CollectionName`" " +
      '--chunk-strategy regex --timeout 0'
    )
    Write-QmdLog -Level 'WARN' -Message (
      'A real run will fail without replacement if the collection name or ' +
      'path/mask already exists.'
    )
    Write-QmdLog -Level 'INFO' -Message 'Preview completed successfully.'
  }
}

function Invoke-NpmManagement {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$NodeState,

    [Parameter(Mandatory)]
    [pscustomobject]$NetworkState
  )

  $NpmPath = $NodeState.NpmPath
  $ActionArguments = @{
    Functional = $true
    Version = $NodeState.NpmVersion
    RegistryAvailable = $NetworkState.NpmRegistryAvailable
  }
  $Action = Get-NpmManagementAction @ActionArguments

  if ($Action -eq 'Unavailable') {
    throw [System.InvalidOperationException]::new(
      "npm $($NodeState.NpmVersion) is outside the supported range " +
      "[$MinimumNpmVersion, $MaximumNpmVersionExclusive), and the registry " +
      'is unavailable.'
    )
  }

  if ($Action -eq 'InstallBootstrap') {
    $NpmArguments = Get-NpmInstallArgumentList
    Write-QmdLog -Level 'INFO' -Message (
      "Installing deterministic npm bootstrap version $BootstrapNpmVersion."
    )
    $null = & $NpmPath @NpmArguments
    $NpmExitCode = $LASTEXITCODE
    if ($NpmExitCode -ne 0) {
      throw [System.InvalidOperationException]::new(
        "npm $BootstrapNpmVersion installation failed with exit code " +
        "$NpmExitCode."
      )
    }

    $NpmPath = Get-ApplicationPath -Name 'npm.cmd'
    if ($null -eq $NpmPath) {
      throw [System.InvalidOperationException]::new(
        'npm.cmd could not be resolved after bootstrap installation.'
      )
    }
  }

  $VersionResult = Invoke-NativeCapture -FilePath $NpmPath -ArgumentList @(
    '--version'
  )
  if ($VersionResult.ExitCode -ne 0) {
    throw [System.InvalidOperationException]::new(
      "npm.cmd --version failed with exit code $($VersionResult.ExitCode)."
    )
  }
  $NpmVersion = Get-VersionFromOutput -Output $VersionResult.Output
  if (-not (Test-NpmVersionSupported -Version $NpmVersion)) {
    throw [System.InvalidOperationException]::new(
      "Resolved npm $NpmVersion is outside the supported range " +
      "[$MinimumNpmVersion, $MaximumNpmVersionExclusive)."
    )
  }
  if (
    $Action -eq 'InstallBootstrap' -and
    $NpmVersion -ne $BootstrapNpmVersion
  ) {
    throw [System.InvalidOperationException]::new(
      "Resolved npm $NpmVersion does not match bootstrap version " +
      "$BootstrapNpmVersion."
    )
  }

  $NpmPrefix = Get-NpmGlobalPrefix -NpmPath $NpmPath
  Add-ProcessPathPrefix -Prefix $NpmPrefix
  Write-QmdLog -Level 'INFO' -Message "Validated supported npm $NpmVersion."

  return [pscustomobject]@{
    NpmPath = $NpmPath
    NpmVersion = $NpmVersion
    NpmPrefix = $NpmPrefix
  }
}

function Invoke-QmdManagement {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$NpmState,

    [Parameter(Mandatory)]
    [pscustomobject]$NetworkState
  )

  $NpmPrefix = Get-NpmGlobalPrefix -NpmPath $NpmState.NpmPath
  Add-ProcessPathPrefix -Prefix $NpmPrefix
  $QmdPath = Get-ApplicationPath -Name 'qmd.cmd'
  $QmdState = Get-QmdLocalState -NpmPrefix $NpmPrefix -ResolvedQmdPath $QmdPath
  $ActionArguments = @{
    State = $QmdState
    RegistryAvailable = $NetworkState.NpmRegistryAvailable
  }
  $Action = Get-QmdManagementAction @ActionArguments

  if ($Action -eq 'Unavailable') {
    throw [System.InvalidOperationException]::new(
      "A functional npm-global QMD $RequiredQmdVersion installation is " +
      'required while the npm registry is unavailable.'
    )
  }

  if ($Action -eq 'InstallRequired') {
    $QmdArguments = Get-QmdInstallArgumentList
    Write-QmdLog -Level 'INFO' -Message (
      "Installing deterministic QMD version $RequiredQmdVersion."
    )
    $null = & $NpmState.NpmPath @QmdArguments
    $QmdInstallExitCode = $LASTEXITCODE
    if ($QmdInstallExitCode -ne 0) {
      throw [System.InvalidOperationException]::new(
        "QMD $RequiredQmdVersion installation failed with exit code " +
        "$QmdInstallExitCode."
      )
    }

    $QmdPath = Get-ApplicationPath -Name 'qmd.cmd'
    $QmdStateArguments = @{
      NpmPrefix = $NpmPrefix
      ResolvedQmdPath = $QmdPath
    }
    $QmdState = Get-QmdLocalState @QmdStateArguments
  }

  if (-not (Test-RequiredQmdState -State $QmdState)) {
    throw [System.InvalidOperationException]::new(
      "npm-global QMD validation failed; version $RequiredQmdVersion must be " +
      'installed, resolve from the npm prefix, and pass qmd.cmd --version.'
    )
  }

  Write-QmdLog -Level 'INFO' -Message (
    "Validated npm-global QMD $($QmdState.PackageVersion)."
  )
  return [pscustomobject]@{
    QmdPath = $QmdPath
    QmdVersion = $QmdState.PackageVersion
  }
}

function Invoke-QmdWorkflow {
  param(
    [Parameter(Mandatory)]
    [string]$QmdPath,

    [Parameter(Mandatory)]
    [string]$CollectionPath,

    [Parameter(Mandatory)]
    [string]$CollectionName,

    [Parameter(Mandatory)]
    [string]$CollectionContext
  )

  $AddArguments = @(
    'collection'
    'add'
    $CollectionPath
    '--name'
    $CollectionName
    '--mask'
    '**/*.md'
  )
  Write-QmdLog -Level 'INFO' -Message (
    "Creating and text-indexing QMD collection '$CollectionName'."
  )
  $null = & $QmdPath @AddArguments
  $AddExitCode = $LASTEXITCODE
  if ($AddExitCode -ne 0) {
    Write-QmdLog -Level 'ERROR' -Message (
      "qmd collection add failed with exit code $AddExitCode."
    )
    Write-QmdLog -Level 'WARN' -Message (
      'QMD may have retained partial collection or text-index state; inspect it manually.'
    )
    return $false
  }
  Write-QmdLog -Level 'INFO' -Message (
    'QMD collection and initial text index were created successfully.'
  )

  $ContextArguments = @(
    'context'
    'add'
    "qmd://$CollectionName"
    $CollectionContext
  )
  Write-QmdLog -Level 'INFO' -Message (
    "Adding root context to QMD collection '$CollectionName'."
  )
  $null = & $QmdPath @ContextArguments
  $ContextExitCode = $LASTEXITCODE
  if ($ContextExitCode -ne 0) {
    Write-QmdLog -Level 'ERROR' -Message (
      "qmd context add failed with exit code $ContextExitCode."
    )
    Write-QmdLog -Level 'WARN' -Message (
      'The collection and text index were retained, but the context may be absent.'
    )
    return $false
  }
  Write-QmdLog -Level 'INFO' -Message 'QMD root context was added successfully.'

  $EmbedArguments = @(
    'embed'
    '-f'
    '-c'
    $CollectionName
    '--chunk-strategy'
    'regex'
    '--timeout'
    '0'
  )
  Write-QmdLog -Level 'INFO' -Message (
    "Generating embeddings only for QMD collection '$CollectionName'."
  )
  $null = & $QmdPath @EmbedArguments
  $EmbedExitCode = $LASTEXITCODE
  if ($EmbedExitCode -ne 0) {
    Write-QmdLog -Level 'ERROR' -Message (
      "qmd embed failed with exit code $EmbedExitCode."
    )
    Write-QmdLog -Level 'WARN' -Message (
      'The collection, text index, and context were retained, but embeddings may be incomplete or absent.'
    )
    return $false
  }

  Write-QmdLog -Level 'INFO' -Message (
    'Scoped QMD embeddings were generated successfully.'
  )
  return $true
}

function Invoke-QmdCollectionMain {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([int])]
  param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$NativeArguments,

    [Parameter()]
    [AllowEmptyCollection()]
    [object[]]$LegacyArguments = @(),

    [Parameter(Mandatory)]
    [System.Management.Automation.PSCmdlet]$CmdletContext,

    [Parameter(Mandatory)]
    [bool]$WhatIfRequested
  )

  $OriginalErrorActionPreference = $ErrorActionPreference
  $OriginalNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
  $OriginalVerboseEnabled = $script:VerboseEnabled

  try {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false

    try {
      $ParserArguments = @{
        NativeArguments = $NativeArguments
        Tokens = $LegacyArguments
      }
      $ParsedArguments = Get-ParsedArgumentSet @ParserArguments
    }
    catch {
      $ErrorRecord = $_
      Write-QmdLog -Level 'ERROR' -Message $ErrorRecord.Exception.Message
      return 1
    }

    if ($ParsedArguments.ProvidedOptionCount -eq 0) {
      Write-QmdLog -Level 'ERROR' -Message (
        'No arguments were provided. Use --help for usage.'
      )
      return 1
    }

    if ($ParsedArguments.Help) {
      [Console]::Out.WriteLine(($HelpLines -join [Environment]::NewLine))
      return 0
    }

    if ($ParsedArguments.Version) {
      [Console]::Out.WriteLine($ScriptVersion)
      return 0
    }

    $script:VerboseEnabled = $ParsedArguments.Verbose

    try {
      Test-RequiredArgumentSet -ParsedArguments $ParsedArguments
    }
    catch {
      $ErrorRecord = $_
      Write-QmdLog -Level 'ERROR' -Message $ErrorRecord.Exception.Message
      return 1
    }

    try {
      $CollectionPath = Resolve-CollectionDirectory -LiteralPath (
        $ParsedArguments.Path
      )
    }
    catch {
      $ErrorRecord = $_
      Write-QmdLog -Level 'FATAL' -Message $ErrorRecord.Exception.Message
      return 1
    }

    try {
      Test-SupportedPlatform
    }
    catch {
      $ErrorRecord = $_
      Write-QmdLog -Level 'FATAL' -Message $ErrorRecord.Exception.Message
      return 1
    }

    try {
      $LocalState = Get-LocalPrerequisiteState
      $NetworkState = Get-NetworkState
      $PlanArguments = @{
        LocalState = $LocalState
        NetworkState = $NetworkState
      }
      $ExecutionPlan = Get-QmdExecutionPlan @PlanArguments

      if ($ParsedArguments.DryRun -or $WhatIfRequested) {
        if ($WhatIfRequested) {
          $null = $CmdletContext.ShouldProcess(
            "QMD collection '$($ParsedArguments.Name)'",
            'Initialize prerequisites, collection, context, and embeddings'
          )
        }

        $PreviewArguments = @{
          ExecutionPlan = $ExecutionPlan
          LocalState = $LocalState
          NetworkState = $NetworkState
          CollectionPath = $CollectionPath
          CollectionName = $ParsedArguments.Name
        }
        Write-QmdExecutionPlan @PreviewArguments
        if ($ExecutionPlan.ExecutionPossible) {
          return 0
        }

        return 1
      }

      if (-not $ExecutionPlan.ExecutionPossible) {
        foreach ($Failure in $ExecutionPlan.Failures) {
          Write-QmdLog -Level 'FATAL' -Message $Failure
        }
        return 1
      }

      $ShouldProcess = $CmdletContext.ShouldProcess(
        "QMD collection '$($ParsedArguments.Name)'",
        'Initialize prerequisites, collection, context, and embeddings'
      )
      if (-not $ShouldProcess) {
        Write-QmdLog -Level 'WARN' -Message (
          'Initialization was cancelled before any mutation.'
        )
        return 0
      }

      $NodeArguments = @{
        LocalState = $LocalState
        ExecutionPlan = $ExecutionPlan
      }
      $NodeState = Invoke-NodeManagement @NodeArguments
      $NpmArguments = @{
        NodeState = $NodeState
        NetworkState = $NetworkState
      }
      $NpmState = Invoke-NpmManagement @NpmArguments
      $QmdArguments = @{
        NpmState = $NpmState
        NetworkState = $NetworkState
      }
      $QmdState = Invoke-QmdManagement @QmdArguments

      $WorkflowArguments = @{
        QmdPath = $QmdState.QmdPath
        CollectionPath = $CollectionPath
        CollectionName = $ParsedArguments.Name
        CollectionContext = $ParsedArguments.Context
      }
      $WorkflowSucceeded = Invoke-QmdWorkflow @WorkflowArguments
      if (-not $WorkflowSucceeded) {
        return 1
      }

      Write-QmdLog -Level 'INFO' -Message (
        "QMD collection '$($ParsedArguments.Name)' was initialized successfully."
      )
      return 0
    }
    catch {
      $ErrorRecord = $_
      Write-QmdLog -Level 'FATAL' -Message $ErrorRecord.Exception.Message
      return 1
    }
  }
  finally {
    $script:VerboseEnabled = $OriginalVerboseEnabled
    $PSNativeCommandUseErrorActionPreference = $OriginalNativeErrorPreference
    $ErrorActionPreference = $OriginalErrorActionPreference
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  $WhatIfRequested = (
    $PSBoundParameters.ContainsKey('WhatIf') -and
    [bool]$PSBoundParameters['WhatIf']
  )
  $MainArguments = @{
    NativeArguments = $PSBoundParameters
    LegacyArguments = $RemainingArguments
    CmdletContext = $PSCmdlet
    WhatIfRequested = $WhatIfRequested
  }
  exit (Invoke-QmdCollectionMain @MainArguments)
}
