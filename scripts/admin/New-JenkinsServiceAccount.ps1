<#
.SYNOPSIS
    Create a local, non-administrator Windows account for the Jenkins controller service and
    grant it the "Log on as a service" right (SeServiceLogonRight).

.DESCRIPTION
    Why not LocalSystem? LocalSystem is more powerful than an administrator on this machine.
    Anything a Jenkins job runs on the controller would run with that power. The Jenkins Windows
    installer documentation recommends a dedicated local or domain user instead.

    Why "Log on as a service"? Windows refuses to start a service as an account that lacks this
    right (error 1069 "The service did not start due to a logon failure"). The installer GUI's
    "Test Credentials" button checks it; a silent install does not, so we grant it first.

    The right is granted with secedit (built into Windows): export the user-rights policy, add the
    account's SID to SeServiceLogonRight, import it back. Equivalent GUI path:
    secpol.msc > Local Policies > User Rights Assignment > Log on as a service.

    Run on: JENKINS-CTRL (or JMETER-AGENT for the agent account). Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\admin\New-JenkinsServiceAccount.ps1 -UserName svc-jenkins
    (you are prompted for the password - it is never echoed or written to disk)
#>
[CmdletBinding()]
param(
    [string]$UserName = 'svc-jenkins',
    [string]$Description = 'Runs the Jenkins Windows service (course lab)',
    [Security.SecureString]$Password      # optional; prompted for when omitted (interactive use)
)
$ErrorActionPreference = 'Stop'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this in an elevated (administrator) PowerShell.' }

# ---- 1. Create the local user (if missing). Password never expires: a service account whose
#         password silently expires stops Jenkins on the next restart.
$existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "[account] Local user '$UserName' already exists - leaving password unchanged."
} else {
    $pw = if ($Password) { $Password } else { Read-Host -AsSecureString "Password for new local user '$UserName'" }
    New-LocalUser -Name $UserName -Password $pw -Description $Description `
                  -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Write-Host "[account] Created local user '$UserName' (member of 'Users' only, NOT Administrators)."
}

# ---- 2. Grant SeServiceLogonRight via secedit
$sid = (New-Object Security.Principal.NTAccount($env:COMPUTERNAME, $UserName)).Translate(
        [Security.Principal.SecurityIdentifier]).Value
$tmp = Join-Path $env:TEMP ("secpol-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $inf = Join-Path $tmp 'export.inf'
    $db  = Join-Path $tmp 'secedit.sdb'
    secedit.exe /export /cfg $inf /areas USER_RIGHTS | Out-Null
    $lines = Get-Content $inf
    $line  = $lines | Where-Object { $_ -like 'SeServiceLogonRight*' }
    # secedit exports resolvable accounts by NAME and the rest as *SID - accept either form
    $names = @()
    if ($line) { $names = ($line -split '=', 2)[1].Split(',') | ForEach-Object { $_.Trim() } }
    if ($names -contains "*$sid" -or $names -contains $UserName -or $names -contains "$env:COMPUTERNAME\$UserName") {
        Write-Host "[account] '$UserName' already has 'Log on as a service'."
    } else {
        $newLine = if ($line) { "$line,*$sid" } else { "SeServiceLogonRight = *$sid" }
        $import = Join-Path $tmp 'import.inf'
        @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
          '[Privilege Rights]', $newLine) | Set-Content -Path $import -Encoding Unicode
        secedit.exe /configure /db $db /cfg $import /areas USER_RIGHTS | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit failed ($LASTEXITCODE). Grant the right in secpol.msc instead." }
        Write-Host "[account] Granted 'Log on as a service' to '$UserName' ($sid)."
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Next: install Jenkins with SERVICE_USERNAME=.\$UserName (see Install-JenkinsController.ps1)."
Write-Host "JENKINS_HOME will then be: C:\Users\$UserName\AppData\Local\Jenkins\.jenkins"
