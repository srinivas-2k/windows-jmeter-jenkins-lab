<#
.SYNOPSIS
    Delete local JMeter result folders older than N days (agent housekeeping).

.DESCRIPTION
    Jenkins keeps the ARCHIVED copy of each build's results (controlled by buildDiscarder in the
    Jenkinsfile). Folders left on the agent are just disk usage. JTL files grow quickly:
    roughly 150-250 bytes per sample, so 1 million samples is ~200 MB.

    Default is a dry run (-WhatIf style). Add -Force to actually delete.

    Run on: JMETER-AGENT (manually, from a scheduled task, or from a Jenkins maintenance job).

.EXAMPLE
    .\scripts\clean-old-results.ps1 -Path C:\jenkins-agent\workspace -Days 7
.EXAMPLE
    .\scripts\clean-old-results.ps1 -Path C:\jenkins-agent\workspace -Days 7 -Force
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'results'),
    [int]$Days = 7,
    [switch]$Force
)
if (-not (Test-Path $Path)) { Write-Host "Nothing to clean: $Path does not exist."; exit 0 }
$cutoff = (Get-Date).AddDays(-$Days)

# Result folders are the ones that contain a results.jtl
$targets = Get-ChildItem -Path $Path -Recurse -Filter 'results.jtl' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt $cutoff } |
           ForEach-Object { $_.Directory }

$total = 0
foreach ($d in $targets) {
    $size = (Get-ChildItem $d.FullName -Recurse -File | Measure-Object Length -Sum).Sum
    $total += $size
    if ($Force) { Remove-Item $d.FullName -Recurse -Force; Write-Host "deleted  $($d.FullName)" }
    else { Write-Host "would delete  $($d.FullName)  ($([Math]::Round($size/1MB,1)) MB)" }
}
$verb = if ($Force) { 'Freed' } else { 'Would free' }
Write-Host "$verb $([Math]::Round($total/1MB,1)) MB from $(@($targets).Count) result folder(s) older than $Days day(s)."
