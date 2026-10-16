<#
.SYNOPSIS
    Run one JMeter test plan in non-GUI mode on Windows and record how it was run.

.DESCRIPTION
    PowerShell twin of run-jmeter.bat. Same inputs, same output layout, plus:
      * typed, validated parameters (a typo fails before JMeter starts)
      * run-info.json - exactly which settings, Java, JMeter and Git commit produced the results
    Works in Windows PowerShell 5.1 (Jenkins 'powershell' step) and PowerShell 7 ('pwsh' step).

    Every parameter falls back to an environment variable of the same meaning, so Jenkins
    parameters (USERS, RAMP_UP, DURATION, ...) flow in without extra wiring.

.EXAMPLE
    .\scripts\run-jmeter.ps1 -TestName smoke
.EXAMPLE
    .\scripts\run-jmeter.ps1 -TestName regression -Users 10 -RampUp 20 -Duration 120 -TargetEnv local
.EXAMPLE
    # From CMD or a Jenkins 'bat' step:
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-jmeter.ps1 -TestName smoke

.NOTES
    Exit codes: 0 ran OK, 2 configuration problem, 3 no usable results, other = JMeter's exit code.
    Exit code 0 is NOT a performance verdict - run validate-jtl.ps1 for that.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$TestName = 'smoke',
    [string]$TargetEnv  = $(if ($env:TARGET_ENV)  { $env:TARGET_ENV }  else { 'local' }),
    [string]$TargetHost = $env:TARGET_HOST,
    [string]$TargetPort = $env:TARGET_PORT,
    [ValidateRange(1, 5000)][int]$Users    = $(if ($env:USERS)    { [int]$env:USERS }    else { 2 }),
    [ValidateRange(0, 3600)][int]$RampUp   = $(if ($env:RAMP_UP)  { [int]$env:RAMP_UP }  else { 5 }),
    [ValidateRange(1, 86400)][int]$Duration = $(if ($env:DURATION) { [int]$env:DURATION } else { 60 }),
    [ValidateRange(1, 100000)][int]$Loops  = $(if ($env:LOOPS)    { [int]$env:LOOPS }    else { 3 }),
    [ValidateRange(0, 60000)][int]$ThinkMs = $(if ($env:THINK_MS) { [int]$env:THINK_MS } else { 300 }),
    [string]$JMeterHome = $(if ($env:JMETER_HOME) { $env:JMETER_HOME } else { 'C:\tools\apache-jmeter-5.6.3' }),
    [string]$JavaHome   = $env:JAVA_HOME,
    [string]$Heap       = $env:JMETER_HEAP,
    [string]$ResultsDir = $env:RESULTS_DIR,
    [switch]$NoReport
)

$ErrorActionPreference = 'Stop'
function Write-Step([string]$msg) { Write-Host "[run-jmeter.ps1] $msg" }
function Fail([int]$code, [string]$msg) { Write-Host "[run-jmeter.ps1] ERROR: $msg" -ForegroundColor Red; exit $code }

# ---- 1. Paths, all relative to the repository (this file lives in <repo>\scripts)
$repoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testPlan  = Join-Path $repoRoot "tests\$TestName\$TestName-test.jmx"
$ciProps   = Join-Path $repoRoot 'config\jmeter-ci.properties'
$envProps  = Join-Path $repoRoot "config\env\$TargetEnv.properties"
$jmeterBat = Join-Path $JMeterHome 'bin\jmeter.bat'
if (-not $ResultsDir) { $ResultsDir = Join-Path $repoRoot "results\$TestName" }

# ---- 2. Validate before spending time on a run
if (-not (Test-Path $jmeterBat)) { Fail 2 "JMeter not found at '$jmeterBat'. Set JMETER_HOME or -JMeterHome." }
if (-not (Test-Path $testPlan))  {
    $valid = (Get-ChildItem (Join-Path $repoRoot 'tests') -Directory | Select-Object -ExpandProperty Name) -join ', '
    Fail 2 "Test plan not found: '$testPlan'. Valid test names: $valid"
}
if (-not (Test-Path $envProps))  { Fail 2 "No environment file '$envProps' for TargetEnv '$TargetEnv'." }

# ---- 3. jmeter.bat launches the first java.exe on PATH and ignores JAVA_HOME.
#         Put the intended Java first, for this process (and its children) only.
if ($JavaHome) {
    $javaExe = Join-Path $JavaHome 'bin\java.exe'
    if (Test-Path $javaExe) { $env:PATH = (Join-Path $JavaHome 'bin') + ';' + $env:PATH }
    else { Write-Step "WARNING: '$javaExe' not found - using java from PATH" }
}
$javaCmd = Get-Command java.exe -ErrorAction SilentlyContinue
if (-not $javaCmd) { Fail 2 "java.exe is not on PATH for $env:USERDOMAIN\$env:USERNAME. Install Java 21 or set JAVA_HOME." }
# 'java -version' writes to stderr; run it through cmd so PowerShell 5.1 does not treat that as an error
$javaVersion = (cmd /c "`"$($javaCmd.Source)`" -version 2>&1" | Select-Object -First 1)

if ($Heap) { $env:HEAP = "-Xms$Heap -Xmx$Heap -XX:MaxMetaspaceSize=256m" }

# ---- 4. Fresh results folder (JMeter will not write a report into a non-empty folder)
if (Test-Path $ResultsDir) { Remove-Item $ResultsDir -Recurse -Force }
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$jtl    = Join-Path $ResultsDir 'results.jtl'
$log    = Join-Path $ResultsDir 'jmeter.log'
$report = Join-Path $ResultsDir 'html-report'

# ---- 5. Build the argument list as an ARRAY: each element is passed as one argument,
#         so paths with spaces need no manual quoting.
$jmArgs = @('-n', '-t', $testPlan, '-q', $ciProps, '-q', $envProps, '-l', $jtl, '-j', $log,
            "-Jusers=$Users", "-Jrampup=$RampUp", "-Jduration=$Duration", "-Jloops=$Loops", "-JthinkMs=$ThinkMs")
if ($TargetHost) { $jmArgs += "-Jhost=$TargetHost" }
if ($TargetPort) { $jmArgs += "-Jport=$TargetPort" }
if (-not $NoReport) { $jmArgs += @('-e', '-o', $report) }

Write-Host ('=' * 60)
Write-Host " JMeter run     : $TestName"
Write-Host " Test plan      : $testPlan"
Write-Host " Environment    : $TargetEnv ($envProps)"
Write-Host " Load           : users=$Users rampup=${RampUp}s duration=${Duration}s loops=$Loops thinkMs=$ThinkMs"
Write-Host " Overrides      : host=$TargetHost port=$TargetPort heap=$Heap"
Write-Host " Results folder : $ResultsDir"
Write-Host " Running as     : $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
Write-Host " Java           : $($javaCmd.Source) -> $javaVersion"
Write-Host ('=' * 60)

# ---- 6. Run. Piping $null gives jmeter.bat an empty stdin so its error 'pause' never waits.
#         ErrorActionPreference is relaxed around native commands: in Windows PowerShell 5.1 a
#         native program writing to stderr can otherwise be turned into a terminating error.
$started = Get-Date
$ErrorActionPreference = 'Continue'
$null | & $jmeterBat @jmArgs
$rc = $LASTEXITCODE
$finished = Get-Date
Write-Step "JMeter exit code: $rc"

# ---- 7. Record exactly how this run was produced (reproducibility)
$gitCommit = $null
if (Get-Command git.exe -ErrorAction SilentlyContinue) {
    $gitCommit = (& git.exe -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $gitCommit = $null }
}
$ErrorActionPreference = 'Stop'
$sampleCount = 0
if (Test-Path $jtl) { $sampleCount = [Math]::Max(0, (Get-Content $jtl | Measure-Object -Line).Lines - 1) }
[ordered]@{
    testName     = $TestName
    targetEnv    = $TargetEnv
    targetHost   = $TargetHost
    targetPort   = $TargetPort
    users        = $Users
    rampUp       = $RampUp
    duration     = $Duration
    loops        = $Loops
    thinkMs      = $ThinkMs
    jmeterHome   = $JMeterHome
    java         = $javaVersion
    machine      = $env:COMPUTERNAME
    runAs        = "$env:USERDOMAIN\$env:USERNAME"
    gitCommit    = $gitCommit
    jenkinsBuild = $env:BUILD_TAG
    started      = $started.ToString('o')
    finished     = $finished.ToString('o')
    exitCode     = $rc
    samples      = $sampleCount
} | ConvertTo-Json | Set-Content -Path (Join-Path $ResultsDir 'run-info.json') -Encoding UTF8

if ($rc -ne 0) { Fail $rc "JMeter failed. Read '$log' - the first ERROR line is usually the cause." }
if ($sampleCount -lt 1) { Fail 3 "No samples in '$jtl'. Did any thread start? Check users/duration and the log." }

Write-Step "OK: $sampleCount samples -> $jtl"
if (-not $NoReport) { Write-Step "HTML dashboard -> $report\index.html" }
exit 0
