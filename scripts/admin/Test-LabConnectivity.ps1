<#
.SYNOPSIS
    Check that the lab machines can reach each other on the ports this course uses.

.DESCRIPTION
    TCP checks are what matter: Jenkins and agents talk over TCP, and many networks block ping
    (ICMP) while TCP works - or the reverse. So a failed ping alone proves nothing.

    Run on: any lab machine (MGMT, JENKINS-CTRL, JMETER-AGENT). Shell: PowerShell. Read-only.

.EXAMPLE
    # From the JMeter agent machine: can I reach Jenkins?
    .\scripts\admin\Test-LabConnectivity.ps1 -JenkinsHost 192.168.0.11
.EXAMPLE
    # From MGMT: can I reach SSH on both Windows machines and Jenkins web?
    .\scripts\admin\Test-LabConnectivity.ps1 -JenkinsHost 192.168.0.11 -AgentHost 192.168.0.12
#>
[CmdletBinding()]
param(
    [string]$JenkinsHost = '192.168.0.11',
    [int]$JenkinsPort    = 8080,
    [string]$AgentHost   = '',
    [string]$SutHost     = '',
    [int]$SutPort        = 8081
)

$checks = @(
    @{ Name = 'Jenkins web UI';            Host = $JenkinsHost; Port = $JenkinsPort },
    @{ Name = 'Jenkins host SSH (OpenSSH)'; Host = $JenkinsHost; Port = 22 }
)
if ($AgentHost) { $checks += @{ Name = 'Agent host SSH (OpenSSH)'; Host = $AgentHost; Port = 22 } }
if ($SutHost)   { $checks += @{ Name = 'ShopLite API (SUT)';       Host = $SutHost;   Port = $SutPort } }

$failed = 0
foreach ($c in $checks) {
    $ping = Test-Connection -ComputerName $c.Host -Count 1 -Quiet -ErrorAction SilentlyContinue
    $tcp  = Test-NetConnection -ComputerName $c.Host -Port $c.Port -WarningAction SilentlyContinue
    $ok   = $tcp.TcpTestSucceeded
    if (-not $ok) { $failed++ }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("{0,-30} {1,-15}:{2,-5} ping={3,-5} tcp={4}" -f $c.Name, $c.Host, $c.Port, $ping, $ok) -ForegroundColor $color
}

if ($failed -gt 0) {
    Write-Host ''
    Write-Host 'At least one TCP check failed. Work through, in order:' -ForegroundColor Yellow
    Write-Host '  1. Is the service running on the target?   Get-Service jenkins / sshd'
    Write-Host '  2. Is it listening on that port?            Get-NetTCPConnection -LocalPort <port> -State Listen'
    Write-Host '  3. Does the target firewall allow it?       Get-NetFirewallRule -DisplayName "Jenkins*"'
    Write-Host '  4. Is the network profile Public?           Get-NetConnectionProfile  (Public blocks more)'
    Write-Host '  5. Are you even on the same subnet?         ipconfig'
    exit 1
}
exit 0
