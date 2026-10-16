<#
.SYNOPSIS
    Download, verify and silently install Eclipse Temurin JDK 21 (x64 MSI).

.DESCRIPTION
    Used on BOTH Windows machines:
      * JENKINS-CTRL : the Jenkins 2.580.x LTS controller supports Java 21 and Java 25
      * JMETER-AGENT : JMeter 5.6.3 and the Jenkins agent run on Java 21 in this course

    Steps: ask the Adoptium API for the latest Java 21 GA MSI -> download -> verify SHA-256
    against the checksum published by Adoptium -> msiexec /quiet with a verbose log.
    Features: FeatureMain (files), FeatureEnvironment (PATH), FeatureJarFileRunWith (.jar),
    FeatureJavaHome (sets the MACHINE JAVA_HOME - off by default in the MSI, so we ask for it).

    Run on: JENKINS-CTRL or JMETER-AGENT. Shell: PowerShell, ELEVATED (admin).

.EXAMPLE
    .\scripts\admin\Install-Java21.ps1
.EXAMPLE
    .\scripts\admin\Install-Java21.ps1 -InstallDir 'C:\Program Files\Eclipse Adoptium\jdk-21'
#>
[CmdletBinding()]
param(
    [string]$InstallDir  = 'C:\Program Files\Eclipse Adoptium\jdk-21',
    [string]$DownloadDir = 'C:\lab-downloads'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # needed by PowerShell 5.1

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell.' }

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

Write-Host '[java] Asking api.adoptium.net for the latest Temurin 21 GA Windows x64 MSI...'
$api = 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse'
$asset = (Invoke-RestMethod -Uri $api -UseBasicParsing)[0]
$msiUrl   = $asset.binary.installer.link
$msiSha   = $asset.binary.installer.checksum
$msiName  = $asset.binary.installer.name
Write-Host "[java] Release : $($asset.release_name)"
Write-Host "[java] MSI     : $msiUrl"

$msiPath = Join-Path $DownloadDir $msiName
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 -Path $msiPath).Hash.ToLower()
if ($actual -ne $msiSha.ToLower()) { throw "SHA-256 mismatch! expected $msiSha got $actual - do NOT install this file." }
Write-Host '[java] SHA-256 verified.'

$log = Join-Path $DownloadDir 'temurin21-install.log'
$msiArgs = @('/i', "`"$msiPath`"",
             'ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome',
             "INSTALLDIR=`"$InstallDir`"", '/quiet', '/norestart', '/L*v', "`"$log`"")
$p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "msiexec failed with exit code $($p.ExitCode). Read $log (search for 'Return value 3')." }

Write-Host "[java] Installed. msiexec exit code $($p.ExitCode) (3010 = reboot recommended)."
Write-Host "[java] Machine JAVA_HOME = $([Environment]::GetEnvironmentVariable('JAVA_HOME','Machine'))"
Write-Host '[java] IMPORTANT: PATH/JAVA_HOME changes reach NEW processes only. Open a new SSH/PowerShell'
Write-Host '[java] session, and restart services (Jenkins / jenkins-agent) so they see the new values.'
# via cmd: Windows PowerShell 5.1 shows java's stderr output as a red NativeCommandError otherwise
cmd /c "`"$(Join-Path $InstallDir 'bin\java.exe')`" -version 2>&1"
