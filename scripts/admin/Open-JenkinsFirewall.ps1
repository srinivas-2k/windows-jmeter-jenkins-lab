<#
.SYNOPSIS
    Allow the lab LAN (and only the lab LAN) to reach the Jenkins web UI through Windows Firewall.

.DESCRIPTION
    The Jenkins MSI's "Firewall Exception" feature is not installed by default, so after a default
    install other machines time out on http://192.168.0.11:8080 while http://localhost:8080 works.

    This rule is deliberately narrow:
      * inbound TCP on ONE port
      * RemoteAddress = LocalSubnet by default (your 192.168.0.x LAN), not "Any"
      * Profile Domain,Private - NOT Public. If the network is marked Public, fix the network
        profile (Set-NetConnectionProfile -NetworkCategory Private) instead of opening Public.
    We never expose Jenkins to the internet - not even to receive GitHub webhooks (Episode 11).

    Inbound agents in this course connect with -webSocket over this same HTTP port, so no extra
    TCP port (like 50000) has to be opened.

    Run on: JENKINS-CTRL. Shell: PowerShell, ELEVATED.

.EXAMPLE
    .\scripts\admin\Open-JenkinsFirewall.ps1
.EXAMPLE
    .\scripts\admin\Open-JenkinsFirewall.ps1 -Port 8080 -RemoteAddress 192.168.0.1,192.168.0.12
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string[]]$RemoteAddress = @('LocalSubnet'),
    [string]$RuleName = 'Jenkins HTTP (lab LAN)'
)
$ErrorActionPreference = 'Stop'

Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $RuleName `
    -Description 'Course lab: Jenkins web UI and WebSocket agents. LAN only.' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
    -RemoteAddress $RemoteAddress -Profile Domain, Private | Out-Null

Write-Host "Firewall rule '$RuleName' allows TCP $Port from $($RemoteAddress -join ', ') (Domain/Private profiles)."
Write-Host ''
Write-Host 'Current network profile(s):'
Get-NetConnectionProfile | Format-Table InterfaceAlias, NetworkCategory, IPv4Connectivity -AutoSize
if (Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public') {
    Write-Warning 'A network is marked Public - this rule does NOT apply there. For a trusted lab LAN run:'
    Write-Warning '  Set-NetConnectionProfile -InterfaceAlias "<alias>" -NetworkCategory Private'
}
