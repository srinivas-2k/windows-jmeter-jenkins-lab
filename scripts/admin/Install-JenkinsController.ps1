<#
.SYNOPSIS
    Download, verify and silently install a Jenkins LTS MSI as a Windows service.

.DESCRIPTION
    The scripted equivalent of the installer wizard, for when you administer JENKINS-CTRL over
    SSH (PuTTY) and have no desktop. Every wizard page maps to an MSI property:

        Wizard page               MSI property         This script
        ------------------------  -------------------  --------------------------------
        Destination folder        INSTALLDIR           -InstallDir
        Service logon credentials SERVICE_LOGON_TYPE=  -ServiceUser (password prompted)
                                  ServiceAccount,
                                  SERVICE_USERNAME /
                                  SERVICE_PASSWORD
        Port selection            PORT                 -Port
        Java home directory       JAVA_HOME            -JavaHome

    Facts taken from the Jenkins MSI source (jenkinsci/packaging, msi/build/jenkins.wxs):
      * jenkins.xml (in the install folder) gets <executable>[JAVA_HOME]\bin\java.exe - the
        service uses THIS Java, not whatever java.exe is first on PATH.
      * JENKINS_HOME = %LocalAppData%\Jenkins\.jenkins of the SERVICE ACCOUNT. With no service
        user (LocalSystem) on a silent install that is
        C:\Windows\System32\config\systemprofile\AppData\Local\Jenkins\.jenkins
      * SERVICE_PASSWORD is a hidden MSI property (not written to the /L*v log) and is stored
        DPAPI-encrypted in HKLM\Software\Jenkins\InstalledProducts\Jenkins.
      * The "Firewall Exception" feature is NOT installed by default - use Open-JenkinsFirewall.ps1.

    Run on: JENKINS-CTRL (192.168.0.11). Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\admin\Install-JenkinsController.ps1 -Version 2.580.1 -ServiceUser '.\svc-jenkins'
.EXAMPLE
    # LocalSystem (NOT recommended - quick single-machine demo only)
    .\scripts\admin\Install-JenkinsController.ps1 -Version 2.580.1 -UseLocalSystem
#>
[CmdletBinding(DefaultParameterSetName = 'User')]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,   # an LTS version, e.g. 2.580.1
    [int]$Port = 8080,
    [string]$JavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'),
    [string]$InstallDir = 'C:\Program Files\Jenkins',
    [Parameter(ParameterSetName = 'User')][string]$ServiceUser = '.\svc-jenkins',
    [Parameter(ParameterSetName = 'System')][switch]$UseLocalSystem,
    [string]$DownloadDir = 'C:\lab-downloads',
    [Security.SecureString]$ServicePassword   # optional; prompted for when omitted
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell.' }

# ---- 1. Pre-flight checks: Java and port
if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome 'bin\java.exe'))) {
    throw "JAVA_HOME '$JavaHome' has no bin\java.exe. Install Java 21 first (Install-Java21.ps1) or pass -JavaHome."
}
$javaVer = (cmd /c "`"$JavaHome\bin\java.exe`" -version 2>&1" | Select-Object -First 1)
Write-Host "[jenkins] Java for the service: $JavaHome -> $javaVer"
if ($javaVer -notmatch '"(21|25)[\."]') {
    Write-Warning 'Jenkins 2.580.x LTS supports Java 21 and Java 25 only. Check the Java support policy page.'
}
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
    $owner = (Get-Process -Id $busy[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
    throw "Port $Port is already in use by '$owner' (PID $($busy[0].OwningProcess)). Choose another -Port."
}

# ---- 2. Download from the official mirror and verify the published SHA-256
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$base = "https://get.jenkins.io/windows-stable/$Version"
$msi  = Join-Path $DownloadDir "jenkins-$Version.msi"
Write-Host "[jenkins] Downloading $base/jenkins.msi"
Invoke-WebRequest -Uri "$base/jenkins.msi" -OutFile $msi -UseBasicParsing
# Download the checksum to a FILE and read it as text: get.jenkins.io serves it as binary, and
# Windows PowerShell 5.1 would hand back a byte[] from .Content instead of the hash string.
Invoke-WebRequest -Uri "$base/jenkins.msi.sha256" -OutFile "$msi.sha256" -UseBasicParsing
$expected = ((Get-Content "$msi.sha256" -Raw) -split '\s+')[0].Trim().ToLower()
$actual   = (Get-FileHash -Algorithm SHA256 $msi).Hash.ToLower()
if ($actual -ne $expected) { throw "SHA-256 mismatch: expected $expected, got $actual. Do NOT install." }
Write-Host "[jenkins] SHA-256 verified ($actual)."

# ---- 3. Silent install
$log = Join-Path $DownloadDir "jenkins-$Version-install.log"
$msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart', '/L*v', "`"$log`"",
             "INSTALLDIR=`"$InstallDir`"", "PORT=$Port", "JAVA_HOME=`"$JavaHome`"")
$plain = $null
if (-not $UseLocalSystem) {
    $sec = if ($ServicePassword) { $ServicePassword } else { Read-Host -AsSecureString "Password for service account $ServiceUser" }
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    # Two silent-install traps, both found while building the lab (docs/guides/lab-build-log.md):
    #  1. SERVICE_LOGON_TYPE defaults to ServiceLocalSystem unless the wizard changes it. The MSI
    #     then locks the install folder to SYSTEM / LocalService / Administrators only, and the
    #     service account gets "Access is denied" starting jenkins.exe. Pass ServiceAccount.
    #  2. The MSI hands SERVICE_USERNAME to icacls - use COMPUTERNAME\user rather than .\user.
    $acct = $ServiceUser -replace '^\.\\', "$env:COMPUTERNAME\"
    $msiArgs += 'SERVICE_LOGON_TYPE=ServiceAccount'
    $msiArgs += "SERVICE_USERNAME=`"$acct`""
    $msiArgs += "SERVICE_PASSWORD=`"$plain`""
}
Write-Host "[jenkins] Installing (log: $log)..."
$p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
$plain = $null; $msiArgs = $null
if ($p.ExitCode -notin 0, 3010) {
    throw "msiexec exit code $($p.ExitCode). Open $log and search for 'Return value 3' - the lines above it explain the failure. Error 1920 (service failed to start) usually means a wrong password or a missing 'Log on as a service' right."
}

# ---- 4. Wait for Jenkins to answer HTTP (first start unpacks the WAR: 30-90 s is normal)
Write-Host "[jenkins] Waiting for http://localhost:$Port/login ..."
$deadline = (Get-Date).AddMinutes(4)
$up = $false
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/login" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) { $up = $true; break }
    } catch { Start-Sleep -Seconds 5 }
}

# ---- 5. Report where everything is (read it from jenkins.xml - never guess)
[xml]$cfg = Get-Content (Join-Path $InstallDir 'jenkins.xml')
$homeRaw = ($cfg.service.env | Where-Object { $_.name -eq 'JENKINS_HOME' }).value
$svc = Get-CimInstance Win32_Service -Filter "Name='jenkins'"
Write-Host ''
Write-Host "Service        : $($svc.Name) state=$($svc.State) startMode=$($svc.StartMode) account=$($svc.StartName)"
Write-Host "jenkins.xml    : $(Join-Path $InstallDir 'jenkins.xml')"
Write-Host "Executable     : $($cfg.service.executable)"
Write-Host "JENKINS_HOME   : $homeRaw   (%LocalAppData% = the SERVICE ACCOUNT's profile)"
Write-Host "HTTP answering : $up"
Write-Host ''
Write-Host 'Initial admin password: it is in <JENKINS_HOME>\secrets\initialAdminPassword and is also printed'
Write-Host "in the service log. Find it with:  .\scripts\admin\Get-JenkinsHealth.ps1 -ShowInitialPassword"
Write-Host "Then open the firewall:            .\scripts\admin\Open-JenkinsFirewall.ps1 -Port $Port"
