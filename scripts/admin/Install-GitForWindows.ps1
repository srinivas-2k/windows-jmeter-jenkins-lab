<#
.SYNOPSIS
    Download, verify and silently install the latest Git for Windows (64-bit).

.DESCRIPTION
    Needed on BOTH Windows machines:
      * JENKINS-CTRL : the Git plugin uses git.exe on the controller to read the Jenkinsfile
                       ("Pipeline script from SCM") and to poll the repository
      * JMETER-AGENT : the agent clones the repository into its workspace for every build

    The installer's SHA-256 is taken from the release notes that Git for Windows publishes on
    GitHub (a table of "file | sha256") and compared before anything runs.

    Run on: JENKINS-CTRL or JMETER-AGENT. Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\admin\Install-GitForWindows.ps1
#>
[CmdletBinding()]
param([string]$DownloadDir = 'C:\lab-downloads')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell.' }
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

$rel   = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing
$asset = $rel.assets | Where-Object { $_.name -match '^Git-[\d\.]+-64-bit\.exe$' } | Select-Object -First 1
$line  = ($rel.body -split "`n") | Where-Object { $_ -like "*$($asset.name)*|*" } | Select-Object -First 1
if (-not $line -or $line -notmatch '([0-9a-f]{64})') { throw "No SHA-256 for $($asset.name) in the release notes - stop." }
$expected = $Matches[1]

$exe = Join-Path $DownloadDir $asset.name
Write-Host "[git] $($rel.tag_name): downloading $($asset.browser_download_url)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe -UseBasicParsing
$actual = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
if ($actual -ne $expected) { throw "SHA-256 mismatch: expected $expected got $actual" }
Write-Host '[git] SHA-256 verified.'

# Inno Setup switches: no UI, no restart, no message boxes. Default components put git.exe on the
# machine PATH ("Git from the command line and also from 3rd-party software").
$log = Join-Path $DownloadDir 'git-install.log'
$p = Start-Process $exe -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', "/LOG=`"$log`"" -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Git installer exit code $($p.ExitCode) - see $log" }
& 'C:\Program Files\Git\cmd\git.exe' --version
Write-Host '[git] Installed. Open a NEW session (and restart Jenkins / agent services) to pick up PATH.'
