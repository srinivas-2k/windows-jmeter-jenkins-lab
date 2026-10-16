<#
.SYNOPSIS
    "Where am I, who am I, and what can I do here?" - run this FIRST on every lab machine.

.DESCRIPTION
    Prints the facts you must know before running any install command:
      * computer name, Windows edition/build, IPv4 addresses, default gateway
      * which shell this is (Windows PowerShell 5.1 or PowerShell 7) and whether it came in over SSH
      * whether this session is ELEVATED (administrator token) - many steps need it
      * whether the host looks like WSL/Linux instead of Windows (it should not, if this script runs)
      * Java / JMeter / Git / Jenkins presence

    Run on: MGMT, JENKINS-CTRL and JMETER-AGENT. Shell: PowerShell (local or via SSH/PuTTY).
    Read-only: it changes nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\admin\Get-LabMachineInfo.ps1
#>
[CmdletBinding()]
param([string[]]$ExpectIp = @())

function Line([string]$k, $v) { Write-Host ("{0,-28} {1}" -f $k, $v) }

$isWindows = ($env:OS -eq 'Windows_NT')
if (-not $isWindows) {
    Write-Host 'This is NOT a Windows host (probably Linux/WSL/macOS). Windows service, firewall and' -ForegroundColor Red
    Write-Host 'environment-variable commands from this course will not affect any Windows machine from here.' -ForegroundColor Red
    exit 1
}

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os        = Get-CimInstance Win32_OperatingSystem
$viaSsh    = [bool]($env:SSH_CLIENT -or $env:SSH_CONNECTION)

Write-Host '==================== machine ====================='
Line 'Computer name'      $env:COMPUTERNAME
Line 'OS'                 "$($os.Caption) build $($os.BuildNumber)"
Line 'User'               $identity.Name
Line 'Elevated (admin)?'  $elevated
Line 'Shell'              "$($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion)"
Line 'Came in over SSH?'  $(if ($viaSsh) { "yes ($env:SSH_CLIENT)" } else { 'no (local console / RDP)' })

Write-Host '==================== network ====================='
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
foreach ($ip in $ips) { Line "IPv4 ($($ip.InterfaceAlias))" "$($ip.IPAddress)/$($ip.PrefixLength)" }
$gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gw) {
    Line 'Default gateway' $gw.NextHop
    if ($ips.IPAddress -contains $gw.NextHop) { Write-Host '  NOTE: this machine IS the default gateway.' -ForegroundColor Yellow }
}
foreach ($want in $ExpectIp) {
    if ($ips.IPAddress -contains $want) { Line "Owns $want ?" 'YES' }
    else { Write-Host ("{0,-28} {1}" -f "Owns $want ?", 'NO - you are on a different machine than you think!') -ForegroundColor Red }
}

Write-Host '==================== tools ======================='
$java = Get-Command java.exe -ErrorAction SilentlyContinue
Line 'java on PATH' $(if ($java) { $java.Source } else { 'not found' })
if ($java) { Line '  version' (cmd /c "`"$($java.Source)`" -version 2>&1" | Select-Object -First 1) }
Line 'JAVA_HOME (machine)'  ([Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'))
Line 'JMETER_HOME (machine)' ([Environment]::GetEnvironmentVariable('JMETER_HOME', 'Machine'))
$git = Get-Command git.exe -ErrorAction SilentlyContinue
Line 'git' $(if ($git) { (& git.exe --version) } else { 'not found' })
$svc = Get-Service -Name jenkins -ErrorAction SilentlyContinue
Line 'Jenkins service' $(if ($svc) { "$($svc.Status) (StartType $($svc.StartType))" } else { 'not installed' })
$agent = Get-Service -Name jenkins-agent -ErrorAction SilentlyContinue
Line 'Jenkins agent service' $(if ($agent) { "$($agent.Status)" } else { 'not installed' })
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
Line 'OpenSSH Server (sshd)' $(if ($sshd) { "$($sshd.Status)" } else { 'not installed' })

if (-not $elevated) {
    Write-Host ''
    Write-Host 'This session is NOT elevated. Installs, services and firewall changes will fail with' -ForegroundColor Yellow
    Write-Host '"Access is denied". Use an administrator account (over SSH an admin account is elevated' -ForegroundColor Yellow
    Write-Host 'automatically) or "Run as administrator" locally.' -ForegroundColor Yellow
}
