<#
.SYNOPSIS
    Install the Jenkins inbound (WebSocket) agent on the JMeter machine as a Windows service (WinSW).

.DESCRIPTION
    Before running this, create the node in Jenkins (Episode 17):
      Manage Jenkins > Nodes > New Node > "win-jmeter-01", Permanent Agent
        Remote root directory : C:\jenkins-agent
        Labels                : windows jmeter
        Usage                 : Only build jobs with label expressions matching this node
        Launch method         : Launch agent by connecting it to the controller
        [x] Use WebSocket
    Save, open the node page, and copy the SECRET shown in the connection command.

    This script then:
      1. creates C:\jenkins-agent
      2. downloads agent.jar FROM YOUR CONTROLLER (so Remoting matches the controller version)
      3. downloads WinSW v2.12.0, checks its SHA-256, renames it jenkins-agent.exe
      4. writes the secret to secret.txt and locks the file down to Administrators/SYSTEM/service account
      5. writes jenkins-agent.xml from the template
      6. installs + starts the service, optionally switching it to a dedicated account

    Why a service and not a console window? A console agent dies when you log off or close the
    window. A service starts at boot, restarts on failure and needs no logged-on user.
    Limitation: services have no desktop - never run the JMeter GUI from a Jenkins job.

    Run on: JMETER-AGENT. Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\agent\Install-JenkinsAgentService.ps1 -JenkinsUrl http://192.168.0.11:8080/ -AgentName win-jmeter-01
.EXAMPLE
    .\scripts\agent\Install-JenkinsAgentService.ps1 -JenkinsUrl http://192.168.0.11:8080/ -AgentName win-jmeter-01 -ServiceUser '.\svc-jmeter'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JenkinsUrl,          # e.g. http://192.168.0.11:8080/
    [string]$AgentName  = 'win-jmeter-01',
    [string]$AgentDir   = 'C:\jenkins-agent',
    [string]$JavaHome   = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'),
    [string]$ServiceUser = '',                                   # e.g. .\svc-jmeter ; empty = LocalSystem
    [string]$WinSWUrl    = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe',
    [string]$WinSWSha256 = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell.' }
if (-not $JenkinsUrl.EndsWith('/')) { $JenkinsUrl += '/' }
if ($AgentDir -match '\s') { throw 'Use an agent directory without spaces (batch scripts and Remoting both prefer it).' }

$javaExe = Join-Path $JavaHome 'bin\java.exe'
if (-not (Test-Path $javaExe)) { throw "No java.exe under JAVA_HOME '$JavaHome'. Install Java 21 or pass -JavaHome." }

# ---- 1. folder
New-Item -ItemType Directory -Force -Path $AgentDir | Out-Null

# ---- 2. agent.jar from the controller (proves HTTP reachability at the same time)
$jar = Join-Path $AgentDir 'agent.jar'
Write-Host "[agent] Downloading ${JenkinsUrl}jnlpJars/agent.jar"
try { Invoke-WebRequest -Uri "${JenkinsUrl}jnlpJars/agent.jar" -OutFile $jar -UseBasicParsing }
catch { throw "Cannot download agent.jar from $JenkinsUrl - check the URL, the controller firewall and Test-LabConnectivity.ps1. $_" }

# ---- 3. WinSW
$exe = Join-Path $AgentDir 'jenkins-agent.exe'
$svc = Get-Service -Name 'jenkins-agent' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host '[agent] Existing jenkins-agent service found - stopping and uninstalling it first.'
    if ($svc.Status -ne 'Stopped') { & $exe stop | Out-Null }
    & $exe uninstall | Out-Null
}
Invoke-WebRequest -Uri $WinSWUrl -OutFile $exe -UseBasicParsing
$hash = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
if ($hash -ne $WinSWSha256.ToLower()) { throw "WinSW SHA-256 mismatch ($hash). Do not run this file." }
Write-Host '[agent] WinSW downloaded and SHA-256 verified.'

# ---- 4. secret file, readable only by Administrators, SYSTEM and the service account
$secretFile = Join-Path $AgentDir 'secret.txt'
$secure = Read-Host -AsSecureString "Paste the agent secret for '$AgentName' (from the node page in Jenkins)"
$secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
if ($secret -notmatch '^[0-9a-f]{64}$') { Write-Warning 'That does not look like a 64-character hex Jenkins agent secret.' }
[IO.File]::WriteAllText($secretFile, $secret.Trim())
$secret = $null
icacls $secretFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' | Out-Null
if ($ServiceUser) { icacls $secretFile /grant:r "$($ServiceUser -replace '^\.\\', "$env:COMPUTERNAME\"):R" | Out-Null }

# ---- 5. service XML from the template
$template = Join-Path $PSScriptRoot 'jenkins-agent.xml.template'
(Get-Content $template -Raw).
    Replace('__AGENT_NAME__', $AgentName).
    Replace('__JENKINS_URL__', $JenkinsUrl).
    Replace('__JAVA_EXE__', $javaExe).
    Replace('__SECRET_FILE__', $secretFile).
    Replace('__WORK_DIR__', $AgentDir) |
    Set-Content -Path (Join-Path $AgentDir 'jenkins-agent.xml') -Encoding UTF8

# ---- 6. install, optionally switch account, start
& $exe install
if ($LASTEXITCODE -ne 0) { throw "WinSW install failed ($LASTEXITCODE)." }

if ($ServiceUser) {
    # The account needs "Log on as a service": run ..\admin\New-JenkinsServiceAccount.ps1 -UserName <name> first.
    $acct = $ServiceUser -replace '^\.\\', "$env:COMPUTERNAME\"
    icacls $AgentDir /grant "${acct}:(OI)(CI)M" | Out-Null      # Modify on the agent folder (workspaces live here)
    $pw = Read-Host -AsSecureString "Password for $ServiceUser"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
    $wmi = Get-CimInstance Win32_Service -Filter "Name='jenkins-agent'"
    $r = Invoke-CimMethod -InputObject $wmi -MethodName Change -Arguments @{ StartName = $ServiceUser; StartPassword = $plain }
    $plain = $null
    if ($r.ReturnValue -ne 0) { throw "Could not set the service account (Win32_Service.Change returned $($r.ReturnValue))." }
    Write-Host "[agent] Service will run as $ServiceUser."
}

& $exe start
Start-Sleep -Seconds 8
& $exe status
Write-Host ''
Write-Host "Service logs : $AgentDir\jenkins-agent.out.log and jenkins-agent.err.log (WinSW writes them next to the XML)"
Write-Host "Remoting logs: $AgentDir\remoting\logs"
Write-Host "In Jenkins, the node page for '$AgentName' should now say: Agent is connected."
