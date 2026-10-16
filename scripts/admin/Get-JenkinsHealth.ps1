<#
.SYNOPSIS
    One-screen health check of the Jenkins controller on Windows.

.DESCRIPTION
    Answers the questions you ask every time Jenkins "doesn't work":
      * Is the service installed, running, set to Automatic, and which account runs it?
      * Which java.exe does the service use, and which version is it?
      * Where are JENKINS_HOME, jenkins.xml and the logs?
      * Is anything listening on the port, and is there a firewall rule for it?
      * Does http://localhost:<port>/login answer?
      * The last lines of the service error log.

    Run on: JENKINS-CTRL. Shell: PowerShell (ELEVATED to read the service account's profile).

.EXAMPLE
    .\scripts\admin\Get-JenkinsHealth.ps1
.EXAMPLE
    .\scripts\admin\Get-JenkinsHealth.ps1 -ShowInitialPassword
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Jenkins',
    [int]$LogLines = 25,
    [switch]$ShowInitialPassword
)

function Line([string]$k, $v, [string]$color = 'Gray') { Write-Host ("{0,-22} {1}" -f $k, $v) -ForegroundColor $color }

$svc = Get-CimInstance Win32_Service -Filter "Name='jenkins'" -ErrorAction SilentlyContinue
if (-not $svc) { Write-Host 'Jenkins service is not installed.' -ForegroundColor Red; exit 1 }
Line 'Service state' $svc.State $(if ($svc.State -eq 'Running') { 'Green' } else { 'Red' })
Line 'Start mode'    $svc.StartMode $(if ($svc.StartMode -eq 'Auto') { 'Green' } else { 'Yellow' })
Line 'Runs as'       $svc.StartName $(if ($svc.StartName -eq 'LocalSystem') { 'Yellow' } else { 'Green' })
Line 'Wrapper'       $svc.PathName

$xmlPath = Join-Path $InstallDir 'jenkins.xml'
if (-not (Test-Path $xmlPath)) { Write-Host "No $xmlPath - pass -InstallDir." -ForegroundColor Red; exit 1 }
[xml]$cfg = Get-Content $xmlPath
$exe  = $cfg.service.executable
$svcArgs = $cfg.service.arguments
$homeRaw = ($cfg.service.env | Where-Object { $_.name -eq 'JENKINS_HOME' }).value
$port = if ($svcArgs -match '--httpPort=(\d+)') { [int]$Matches[1] } else { 8080 }

# Resolve %LocalAppData% for the SERVICE account, not for the user running this script
$jHome = $homeRaw
if ($homeRaw -match '%LocalAppData%') {
    if ($svc.StartName -eq 'LocalSystem') {
        $profileDir = 'C:\Windows\System32\config\systemprofile'
    } else {
        $acct = $svc.StartName -replace '^\.\\', "$env:COMPUTERNAME\"
        $sid  = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
    }
    $jHome = $homeRaw -replace '%LocalAppData%', (Join-Path $profileDir 'AppData\Local')
}

Line 'jenkins.xml'   $xmlPath
Line 'Java (service)' $exe
if (Test-Path $exe) { Line '  version' (cmd /c "`"$exe`" -version 2>&1" | Select-Object -First 1) }
else { Line '  version' 'java.exe NOT FOUND - service cannot start' 'Red' }
Line 'Arguments'     $svcArgs
Line 'JENKINS_HOME'  "$jHome  (raw: $homeRaw)"
Line 'Port'          $port

$listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
Line 'Listening?' $(if ($listen) { "yes, PID $($listen[0].OwningProcess) on $($listen.LocalAddress -join ',')" } else { 'NO' }) $(if ($listen) { 'Green' } else { 'Red' })

$rules = Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
         Where-Object { $_.LocalPort -eq "$port" } | Get-NetFirewallRule -ErrorAction SilentlyContinue |
         Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }
Line 'Firewall rules' $(if ($rules) { ($rules.DisplayName -join '; ') } else { "none for TCP $port - other machines cannot connect" }) $(if ($rules) { 'Green' } else { 'Yellow' })

try {
    $r = Invoke-WebRequest -Uri "http://localhost:$port/login" -UseBasicParsing -TimeoutSec 10
    Line 'HTTP /login' "$($r.StatusCode), X-Jenkins=$($r.Headers['X-Jenkins'])" 'Green'
} catch { Line 'HTTP /login' "FAILED: $($_.Exception.Message)" 'Red' }

if ($ShowInitialPassword) {
    $pwFile = Join-Path $jHome 'secrets\initialAdminPassword'
    if (Test-Path $pwFile) { Line 'Initial admin pw' (Get-Content $pwFile) 'Cyan' }
    else { Line 'Initial admin pw' "not found at $pwFile (already used and deleted, or different home)" 'Yellow' }
}

Write-Host ''
Write-Host "---- last $LogLines lines of the service error log ----"
$errLog = @((Join-Path $InstallDir 'jenkins.err.log'), (Join-Path $jHome 'jenkins.err.log')) |
          Where-Object { Test-Path $_ } | Select-Object -First 1
if ($errLog) { Write-Host "($errLog)"; Get-Content $errLog -Tail $LogLines }
else { Write-Host 'jenkins.err.log not found next to jenkins.xml or in JENKINS_HOME.' }
