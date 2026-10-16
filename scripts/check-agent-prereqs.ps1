<#
.SYNOPSIS
    Pre-flight check for a JMeter execution node. Run it as the FIRST stage of every pipeline.

.DESCRIPTION
    A load test that fails after 20 minutes because Java is missing wastes 20 minutes.
    This script fails in seconds, with a message that names the fix. It checks the environment
    AS THE JENKINS AGENT SEES IT - which is often different from what you see in your own
    PowerShell window (different user account, different PATH, no restart since PATH changed).

    Checks (FAIL stops the build, WARN only reports):
      FAIL  java.exe on PATH, major version >= 17 (course standard: 21)
      FAIL  JMETER_HOME set and contains bin\jmeter.bat and lib\ext\ApacheJMeter_core.jar
      WARN  Java major version is not 21 (course standard)
      WARN  JMeter version is not 5.6.3 (course standard)
      WARN  git.exe not on PATH (Jenkins can still use its own Git tool configuration)
      WARN  less than 2 GB free on the workspace drive
      FAIL  target URL /health does not answer (only when -TargetUrl is given)

    Run on: JMETER-AGENT (normally from a Jenkins 'powershell' step). Read-only.

.EXAMPLE
    .\scripts\check-agent-prereqs.ps1
.EXAMPLE
    .\scripts\check-agent-prereqs.ps1 -TargetUrl http://localhost:8081
.EXAMPLE
    # Same target resolution as run-jmeter.*: env file first, TARGET_HOST/TARGET_PORT override it
    .\scripts\check-agent-prereqs.ps1 -TargetEnv local
#>
[CmdletBinding()]
param(
    [string]$JMeterHome = $(if ($env:JMETER_HOME) { $env:JMETER_HOME } else { 'C:\tools\apache-jmeter-5.6.3' }),
    [string]$TargetUrl  = '',
    [string]$TargetEnv  = '',          # e.g. local -> read host/port from config\env\local.properties
    [string]$TargetHost = $env:TARGET_HOST,
    [string]$TargetPort = $env:TARGET_PORT,
    [int]$ExpectedJavaMajor = 21,
    [string]$ExpectedJMeter = '5.6.3'
)

$fail = 0; $warn = 0
function Ok($m)   { Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

Write-Host "Agent pre-flight on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
Write-Host "Workspace: $(Get-Location)"

# ---- Java (the one jmeter.bat will actually use: first on PATH)
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH     # same rule as run-jmeter.*
}
$java = Get-Command java.exe -ErrorAction SilentlyContinue
if (-not $java) {
    Bad 'java.exe not found on PATH. Install Java 21, then RESTART the agent service so it sees the new PATH.'
} else {
    $verLine = (cmd /c "`"$($java.Source)`" -version 2>&1" | Select-Object -First 1)
    $major = 0
    if ($verLine -match 'version "(\d+)(\.(\d+))?') { $major = [int]$Matches[1]; if ($major -eq 1) { $major = [int]$Matches[3] } }
    if ($major -lt 17) { Bad "Java too old or unreadable: $verLine ($($java.Source))" }
    elseif ($major -ne $ExpectedJavaMajor) { Warn "Java $major found ($($java.Source)); the course standard is Java $ExpectedJavaMajor." }
    else { Ok "Java $major -> $($java.Source)" }
}

# ---- JMeter
$bat  = Join-Path $JMeterHome 'bin\jmeter.bat'
$core = Join-Path $JMeterHome 'lib\ext\ApacheJMeter_core.jar'
if (-not (Test-Path $bat) -or -not (Test-Path $core)) {
    Bad "JMeter not found at JMETER_HOME='$JMeterHome'. Set JMETER_HOME (machine env var or the pipeline 'environment' block)."
} else {
    # Read the version from the jar manifest - faster and quieter than starting JMeter
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($core)
    try {
        $entry = $zip.GetEntry('META-INF/MANIFEST.MF')
        $reader = New-Object IO.StreamReader($entry.Open())
        $manifest = $reader.ReadToEnd(); $reader.Close()
    } finally { $zip.Dispose() }
    $jmVer = if ($manifest -match 'Implementation-Version:\s*([^\r\n]+)') { $Matches[1].Trim() } else { 'unknown' }
    if ($jmVer -ne $ExpectedJMeter) { Warn "JMeter $jmVer at $JMeterHome; course standard is $ExpectedJMeter." }
    else { Ok "JMeter $jmVer -> $JMeterHome" }
    if ($JMeterHome -match '\s') { Warn "JMETER_HOME contains spaces ('$JMeterHome'). Prefer C:\tools\..." }
}

# ---- Git
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($git) { Ok "$(& git.exe --version)" } else { Warn 'git.exe not on PATH (fine if Jenkins checks out with its own Git tool).' }

# ---- Disk
$drive = (Get-Location).Drive
if ($drive) {
    $freeGb = [Math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 2) { Warn "Only $freeGb GB free on $($drive.Name): - JTL files and reports can fill it." }
    else { Ok "$freeGb GB free on $($drive.Name):" }
}

# ---- Memory (JMeter default heap is 1 GB)
$os = Get-CimInstance Win32_OperatingSystem
$freeMemGb = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
if ($freeMemGb -lt 1.5) { Warn "Only $freeMemGb GB RAM free; JMeter's default heap alone is 1 GB." } else { Ok "$freeMemGb GB RAM free" }

# ---- Target
if (-not $TargetUrl -and $TargetEnv) {
    $propsFile = Join-Path (Split-Path $PSScriptRoot -Parent) "config\env\$TargetEnv.properties"
    if (-not (Test-Path $propsFile)) { Bad "No environment file $propsFile" }
    else {
        $p = @{}
        foreach ($l in Get-Content $propsFile) { if ($l -match '^\s*([^#=\s]+)\s*=\s*(.*)$') { $p[$Matches[1]] = $Matches[2].Trim() } }
        $h = if ($TargetHost) { $TargetHost } else { $p['host'] }
        $o = if ($TargetPort) { $TargetPort } else { $p['port'] }
        $proto = if ($p['protocol']) { $p['protocol'] } else { 'http' }
        $TargetUrl = "${proto}://${h}:${o}"
    }
}
if ($TargetUrl) {
    $u = $TargetUrl.TrimEnd('/') + '/health'
    try {
        $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 10
        Ok "Target answers: $u -> HTTP $($r.StatusCode)"
    } catch {
        Bad "Target does not answer: $u ($($_.Exception.Message)). Start demo-app\ShopLiteApi.java or fix TARGET_HOST/PORT."
    }
}

Write-Host "Pre-flight result: $fail failure(s), $warn warning(s)"
if ($fail -gt 0) { exit 1 }
exit 0
