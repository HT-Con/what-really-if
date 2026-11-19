#requires -Version 7.2
<#
.SYNOPSIS
Render Azure What-If JSON as a conservative Markdown deployment report.
.DESCRIPTION
Requires PowerShell 7.2+ and jq 1.6+. Shares what-really-if.jq and the default
what-really-if.json configuration with the Bash entry point. Does not connect
to Azure. Supports flat Azure CLI results and REST properties.changes results.

Exit codes: 0 = report generated (may include changes to review),
2 = invalid input/configuration or renderer failure,
3 = report generated with unacknowledged unknown effects or analysis gaps requiring review.
Publish the report and raw JSON even when the exit code is 3.
.EXAMPLE
./what-really-if.ps1 -InputFile whatif.json -OutputFile whatif.md -SummaryFile summary.json
.EXAMPLE
./what-really-if.ps1 -InputFile whatif.json -OutputFile whatif.md -ConfigFile project-rules.json
#>
[CmdletBinding()]
param(
    [Alias('Input')] [string] $InputFile,
    [Alias('Output')] [string] $OutputFile,
    [Alias('Config')] [string] $ConfigFile = (Join-Path $PSScriptRoot 'what-really-if.json'),
    [string] $SummaryFile,
    [string] $Title = 'what-really-if — Bicep deployment preview',
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
Usage: ./what-really-if.ps1 -InputFile whatif.json -OutputFile whatif.md [options]

  -ConfigFile FILE   Project rules (default: what-really-if.json beside script)
  -SummaryFile FILE  Also write machine-readable counts and analysis issues
  -Title TEXT        Markdown report title
  -Help             Show this help

Requires PowerShell 7.2+ and jq 1.6+. Keep what-really-if.jq beside this script.
Uses the same filtering engine and JSON configuration as what-really-if.sh.
Project configs may use "extends": "default". Rules support beforeIn and
allowStructural; acknowledgeUnsupported records reviewed analysis gaps.
See README.md for matching behavior and examples.

Exit codes:
  0  Report generated, no unacknowledged unknown effects or analysis gaps.
     May include changes requiring approval. This is not permission to deploy.
  2  Invalid input/configuration, unsuccessful operation, or renderer failure.
  3  Report generated, unknown effects or analysis gaps require review.

Use full What-If JSON (--no-pretty-print --result-format FullResourcePayloads).
Check the Azure CLI exit status before rendering. Keep the raw JSON as an
artifact and publish reports even when the renderer returns exit code 3.
'@
    exit 0
}

function Get-CanonicalFilePath([string] $Path) {
    # Use PowerShell's current filesystem location rather than the process CWD.
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not $parent -or $parent -eq $fullPath) { return $fullPath }
    $resolvedParent = Get-CanonicalFilePath $parent
    $resolved = [System.IO.Path]::Combine($resolvedParent, [System.IO.Path]::GetFileName($fullPath))
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        $target = $item.ResolveLinkTarget($true)
        if ($null -ne $target) { return Get-CanonicalFilePath $target.FullName }
    }
    return $resolved
}

function Invoke-WhatIfJq([string] $Executable, [string[]] $JqArguments) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    # ArgumentList handles quoting on Windows/Linux/macOS, including spaces,
    # quotes, Unicode, and shell syntax in filenames or custom report titles.
    foreach ($argument in $JqArguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Cannot start jq' }
        # Drain both streams concurrently so a long diagnostic cannot deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Report not generated; jq exited with code $($process.ExitCode): $($errorText.Trim())"
        }
        return $outputText
    }
    finally { $process.Dispose() }
}

function Publish-ReportFile([string] $Destination, [string] $Content) {
    $directory = [System.IO.Path]::GetDirectoryName($Destination)
    [void][System.IO.Directory]::CreateDirectory($directory)
    $staged = Join-Path $directory ('.what-really-if.' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($staged, $Content + "`n", [System.Text.UTF8Encoding]::new($false))
        # Stage on the destination filesystem, then replace in one rename.
        [System.IO.File]::Move($staged, $Destination, $true)
    }
    finally {
        if ([System.IO.File]::Exists($staged)) { [System.IO.File]::Delete($staged) }
    }
}

try {
    if ([string]::IsNullOrEmpty($InputFile) -or [string]::IsNullOrEmpty($OutputFile)) {
        throw '-InputFile and -OutputFile are required (see -Help)'
    }
    $jqCommand = Get-Command jq -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $jqCommand) { throw 'jq 1.6+ is required; ensure jq is on PATH' }

    $inputPath = Get-CanonicalFilePath $InputFile
    $configPath = Get-CanonicalFilePath $ConfigFile
    $defaultsPath = Get-CanonicalFilePath (Join-Path $PSScriptRoot 'what-really-if.json')
    $enginePath = Get-CanonicalFilePath (Join-Path $PSScriptRoot 'what-really-if.jq')
    $outputPath = Get-CanonicalFilePath $OutputFile
    $summaryPath = if ($SummaryFile) { Get-CanonicalFilePath $SummaryFile } else { $null }
    if (-not [System.IO.File]::Exists($inputPath)) { throw "Input does not exist: $InputFile" }
    if (-not [System.IO.File]::Exists($configPath)) { throw "Configuration does not exist: $ConfigFile" }

    $comparison = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    foreach ($source in @($inputPath, $configPath, $defaultsPath, $enginePath)) {
        if ($comparison.Equals($source, $outputPath)) { throw 'Output must differ from input, config, and bundled engine/defaults' }
        if ($summaryPath -and $comparison.Equals($source, $summaryPath)) { throw 'Summary must differ from input, config, and bundled engine/defaults' }
    }
    if ($summaryPath -and $comparison.Equals($summaryPath, $outputPath)) {
        throw 'Summary must differ from Markdown output'
    }

    $jqArguments = @(
        '-s', '--slurpfile', 'config', $configPath, '--slurpfile', 'defaults', $defaultsPath, '--arg', 'title', $Title,
        '-f', $enginePath, '--', $inputPath
    )
    $resultText = Invoke-WhatIfJq $jqCommand.Source $jqArguments
    $result = ConvertFrom-Json -InputObject $resultText -AsHashtable -Depth 100
    Publish-ReportFile $outputPath $result.markdown
    if ($summaryPath) {
        Publish-ReportFile $summaryPath (ConvertTo-Json -InputObject $result.summary -Depth 100)
    }
    exit ([int]$result.exitCode)
}
catch {
    [Console]::Error.WriteLine("what-really-if: $($_.Exception.Message)")
    exit 2
}
