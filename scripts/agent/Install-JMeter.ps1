<#
.SYNOPSIS
    Download Apache JMeter 5.6.3, verify its SHA-512, unzip to C:\tools and set JMETER_HOME.

.DESCRIPTION
    * Downloads from archive.apache.org (the permanent Apache archive - 5.6.3 stays there even
      after newer versions move the main download mirrors on).
    * Verifies the SHA-512 that Apache publishes next to the zip. Never skip this for a tool that
      will run inside your CI system.
    * Extracts to C:\tools\apache-jmeter-5.6.3 - a path WITHOUT spaces. Spaces in tool paths are
      the #1 cause of broken batch scripts.
    * Sets MACHINE-level environment variables (visible to services such as the Jenkins agent,
      after the service restarts):  JMETER_HOME, and appends %JMETER_HOME%\bin to PATH.

    Run on: JMETER-AGENT. Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\agent\Install-JMeter.ps1
#>
[CmdletBinding()]
param(
    [string]$Version   = '5.6.3',
    [string]$ToolsDir  = 'C:\tools',
    [string]$DownloadDir = 'C:\lab-downloads',
    [switch]$NoPathChange
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell (it sets machine environment variables).' }

New-Item -ItemType Directory -Force -Path $DownloadDir, $ToolsDir | Out-Null
$name = "apache-jmeter-$Version"
$url  = "https://archive.apache.org/dist/jmeter/binaries/$name.zip"
$zip  = Join-Path $DownloadDir "$name.zip"

Write-Host "[jmeter] Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Invoke-WebRequest -Uri "$url.sha512" -OutFile "$zip.sha512" -UseBasicParsing    # file, not .Content (PS 5.1 may return bytes)
$expected = ((Get-Content "$zip.sha512" -Raw) -split '\s+')[0].Trim().ToLower()
$actual   = (Get-FileHash -Algorithm SHA512 -Path $zip).Hash.ToLower()
if ($actual -ne $expected) { throw "SHA-512 mismatch: expected $expected got $actual. Do NOT use this file." }
Write-Host '[jmeter] SHA-512 verified.'

$target = Join-Path $ToolsDir $name
if (Test-Path $target) {
    Write-Host "[jmeter] $target already exists - leaving it in place (delete it first to reinstall)."
} else {
    Expand-Archive -Path $zip -DestinationPath $ToolsDir
    Write-Host "[jmeter] Extracted to $target"
}

[Environment]::SetEnvironmentVariable('JMETER_HOME', $target, 'Machine')
Write-Host "[jmeter] Machine JMETER_HOME = $target"

if (-not $NoPathChange) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $bin = Join-Path $target 'bin'
    if (($machinePath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bin", 'Machine')
        Write-Host "[jmeter] Appended $bin to the machine PATH."
    }
}

Write-Host ''
Write-Host 'Environment changes apply to NEW processes only:'
Write-Host '  * open a new SSH/PowerShell session before testing "jmeter --version"'
Write-Host '  * restart the agent service later:  Restart-Service jenkins-agent'
Write-Host ''
Write-Host 'Reminder: jmeter.bat runs the FIRST java.exe on PATH (it ignores JAVA_HOME). Check with:'
Write-Host '  where.exe java'
