<#
.SYNOPSIS
    Performance quality gate: read a JMeter CSV JTL, compute statistics, compare with thresholds.

.DESCRIPTION
    JMeter exits 0 even when every request failed, so the build cannot trust JMeter's exit code
    to judge performance. This script makes the pass/fail decision explicit and version-controlled.

    It writes three files next to the JTL (or into -OutputDir):
      quality-gate.md         human-readable summary (also printed to the Jenkins console)
      quality-gate.json       machine-readable numbers (for trend scripts, dashboards)
      quality-gate-junit.xml  one test case per gate, so Jenkins' 'junit' step shows them

    Exit codes (designed for Jenkins):
      0 = all gates passed
      1 = at least one FAIL threshold breached     -> mark build FAILURE
      2 = input problem (file missing, empty, not CSV, too few samples)
      3 = only WARN thresholds breached            -> mark build UNSTABLE

    Compatible with Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    .\scripts\validate-jtl.ps1 -JtlPath results\smoke\results.jtl
.EXAMPLE
    .\scripts\validate-jtl.ps1 -JtlPath results\regression\results.jtl -MaxErrorPct 1 -MaxP95Ms 800 -WarnP95Ms 500
.EXAMPLE
    # From CMD / a 'bat' step:
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate-jtl.ps1 -JtlPath results\smoke\results.jtl

.NOTES
    Percentiles use the nearest-rank method. The JMeter HTML dashboard uses a slightly different
    estimator, so p90/p95/p99 can differ by a few milliseconds on small samples. That is expected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JtlPath,
    [double]$MaxErrorPct = 1.0,      # FAIL if overall error % is above this
    [int]$MaxP95Ms       = 1000,     # FAIL if overall 95th percentile (ms) is above this
    [int]$MaxAvgMs       = 0,        # FAIL if overall average (ms) is above this; 0 = not checked
    [double]$WarnErrorPct = 0,       # UNSTABLE if error % is above this; 0 = not checked
    [int]$WarnP95Ms      = 0,        # UNSTABLE if p95 is above this; 0 = not checked
    [int]$MinSamples     = 1,        # input problem if fewer samples than this
    [string]$LabelFilter = '',       # regex: only evaluate labels that match (e.g. '^REG_')
    [string]$OutputDir   = ''
)

$ErrorActionPreference = 'Stop'

function Get-Percentile([double[]]$sorted, [double]$p) {
    # nearest-rank: smallest value with at least p% of samples at or below it
    if ($sorted.Count -eq 0) { return 0 }
    $rank = [Math]::Ceiling(($p / 100.0) * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    return $sorted[[int]$rank - 1]
}

function Get-Stats($rows) {
    $elapsed = [double[]]($rows | ForEach-Object { [double]$_.elapsed })
    [Array]::Sort($elapsed)
    $count  = $elapsed.Count
    $errors = @($rows | Where-Object { $_.success -ne 'true' }).Count
    $ts     = [double[]]($rows | ForEach-Object { [double]$_.timeStamp })
    $start  = ($ts | Measure-Object -Minimum).Minimum
    $end    = ($rows | ForEach-Object { [double]$_.timeStamp + [double]$_.elapsed } | Measure-Object -Maximum).Maximum
    $spanS  = [Math]::Max(0.001, ($end - $start) / 1000.0)
    [pscustomobject]@{
        samples       = $count
        errors        = $errors
        errorPct      = [Math]::Round(100.0 * $errors / [Math]::Max(1, $count), 2)
        avgMs         = [Math]::Round(($elapsed | Measure-Object -Average).Average, 1)
        minMs         = $elapsed[0]
        p90Ms         = Get-Percentile $elapsed 90
        p95Ms         = Get-Percentile $elapsed 95
        p99Ms         = Get-Percentile $elapsed 99
        maxMs         = $elapsed[$count - 1]
        throughputRps = [Math]::Round($count / $spanS, 2)
    }
}

function Esc([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

# ---------------------------------------------------------------- 1. read & sanity-check input
if (-not (Test-Path $JtlPath)) {
    Write-Host "[quality-gate] ERROR: JTL not found: $JtlPath" -ForegroundColor Red
    exit 2
}
$JtlPath = (Resolve-Path $JtlPath).Path
if (-not $OutputDir) { $OutputDir = Split-Path $JtlPath -Parent }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$header = Get-Content $JtlPath -TotalCount 1
if ($header -notmatch 'timeStamp' -or $header -notmatch 'elapsed' -or $header -notmatch 'success') {
    Write-Host "[quality-gate] ERROR: '$JtlPath' is not a CSV JTL with a header row." -ForegroundColor Red
    Write-Host "[quality-gate]        Run JMeter with jmeter.save.saveservice.output_format=csv (config\jmeter-ci.properties)."
    exit 2
}

$rows = @(Import-Csv $JtlPath)
if ($LabelFilter) { $rows = @($rows | Where-Object { $_.label -match $LabelFilter }) }
if ($rows.Count -lt $MinSamples) {
    Write-Host "[quality-gate] ERROR: only $($rows.Count) samples (minimum $MinSamples). A test that barely ran proves nothing." -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- 2. statistics
$overall  = Get-Stats $rows
$perLabel = foreach ($g in ($rows | Group-Object label | Sort-Object Name)) {
    $s = Get-Stats $g.Group
    $s | Add-Member -NotePropertyName label -NotePropertyValue $g.Name -PassThru
}
$topErrors = $rows | Where-Object { $_.success -ne 'true' } |
    Group-Object { "$($_.label) | $($_.responseCode) | $($_.responseMessage) | $($_.failureMessage)" } |
    Sort-Object Count -Descending | Select-Object -First 5

# ---------------------------------------------------------------- 3. gates
$gates = New-Object System.Collections.Generic.List[object]
function Add-Gate($name, $actual, $limit, $unit, $level) {
    $breached = ($limit -gt 0) -and ($actual -gt $limit)
    $gates.Add([pscustomobject]@{
        name = $name; actual = $actual; limit = $limit; unit = $unit; level = $level
        status = $(if ($limit -le 0) { 'SKIPPED' } elseif ($breached) { $level } else { 'PASS' })
    })
}
Add-Gate 'Error rate'          $overall.errorPct $MaxErrorPct  '%'  'FAIL'
Add-Gate '95th percentile'     $overall.p95Ms    $MaxP95Ms     'ms' 'FAIL'
Add-Gate 'Average'             $overall.avgMs    $MaxAvgMs     'ms' 'FAIL'
Add-Gate 'Error rate (warn)'   $overall.errorPct $WarnErrorPct '%'  'WARN'
Add-Gate '95th percentile (warn)' $overall.p95Ms $WarnP95Ms    'ms' 'WARN'

$failed = @($gates | Where-Object { $_.status -eq 'FAIL' }).Count
$warned = @($gates | Where-Object { $_.status -eq 'WARN' }).Count
$verdict = if ($failed -gt 0) { 'FAILED' } elseif ($warned -gt 0) { 'UNSTABLE' } else { 'PASSED' }

# ---------------------------------------------------------------- 4. markdown summary
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Performance quality gate: **$verdict**")
[void]$md.AppendLine('')
[void]$md.AppendLine("JTL: ``$JtlPath``  ")
[void]$md.AppendLine("Samples: $($overall.samples), errors: $($overall.errors) ($($overall.errorPct)%), throughput: $($overall.throughputRps)/s")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Gate | Actual | Limit | Result |')
[void]$md.AppendLine('|---|---:|---:|---|')
foreach ($g in $gates) {
    $lim = if ($g.limit -gt 0) { "$($g.limit) $($g.unit)" } else { '-' }
    [void]$md.AppendLine("| $($g.name) | $($g.actual) $($g.unit) | $lim | $($g.status) |")
}
[void]$md.AppendLine('')
[void]$md.AppendLine('| Label | Samples | Err % | Avg | p90 | p95 | p99 | Max | Req/s |')
[void]$md.AppendLine('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($l in $perLabel) {
    [void]$md.AppendLine("| $($l.label) | $($l.samples) | $($l.errorPct) | $($l.avgMs) | $($l.p90Ms) | $($l.p95Ms) | $($l.p99Ms) | $($l.maxMs) | $($l.throughputRps) |")
}
if ($topErrors) {
    [void]$md.AppendLine('')
    [void]$md.AppendLine('Top errors (label | code | message | assertion):')
    [void]$md.AppendLine('')
    foreach ($e in $topErrors) { [void]$md.AppendLine("- $($e.Count) x $($e.Name)") }
}
$mdText = $md.ToString()
Set-Content -Path (Join-Path $OutputDir 'quality-gate.md') -Value $mdText -Encoding UTF8

# ---------------------------------------------------------------- 5. json
[ordered]@{
    verdict  = $verdict
    jtl      = $JtlPath
    overall  = $overall
    gates    = $gates
    labels   = $perLabel
} | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputDir 'quality-gate.json') -Encoding UTF8

# ---------------------------------------------------------------- 6. junit xml
# A WARN gate is reported as passed-with-message: JUnit has no "unstable" state, and we
# let the pipeline decide UNSTABLE from this script's exit code instead.
$xml = New-Object System.Text.StringBuilder
$active = @($gates | Where-Object { $_.status -ne 'SKIPPED' })
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine("<testsuite name=""performance-quality-gate"" tests=""$($active.Count)"" failures=""$failed"" errors=""0"" skipped=""0"">")
foreach ($g in $active) {
    $case = Esc "$($g.name) <= $($g.limit) $($g.unit)"
    [void]$xml.AppendLine("  <testcase classname=""quality-gate"" name=""$case"">")
    if ($g.status -eq 'FAIL') {
        [void]$xml.AppendLine("    <failure message=""$(Esc "actual $($g.actual) $($g.unit) > limit $($g.limit) $($g.unit)")"" />")
    } elseif ($g.status -eq 'WARN') {
        [void]$xml.AppendLine("    <system-out>$(Esc "WARNING: actual $($g.actual) $($g.unit) > warn limit $($g.limit) $($g.unit)")</system-out>")
    }
    [void]$xml.AppendLine('  </testcase>')
}
[void]$xml.AppendLine('</testsuite>')
Set-Content -Path (Join-Path $OutputDir 'quality-gate-junit.xml') -Value $xml.ToString() -Encoding UTF8

# ---------------------------------------------------------------- 7. console + exit code
Write-Host ''
Write-Host $mdText
Write-Host "[quality-gate] Reports written to $OutputDir (quality-gate.md / .json / -junit.xml)"
switch ($verdict) {
    'FAILED'   { Write-Host '[quality-gate] RESULT: FAILED' -ForegroundColor Red; exit 1 }
    'UNSTABLE' { Write-Host '[quality-gate] RESULT: UNSTABLE (warning thresholds breached)' -ForegroundColor Yellow; exit 3 }
    default    { Write-Host '[quality-gate] RESULT: PASSED' -ForegroundColor Green; exit 0 }
}
