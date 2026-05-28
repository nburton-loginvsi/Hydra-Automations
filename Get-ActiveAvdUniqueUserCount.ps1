#requires -Version 5.1

<#
    Counts unique Azure Virtual Desktop users by UPN.

    The script queries AVD user sessions from host pools in the current Azure
    subscription by default, filters active and disconnected sessions, de-dupes
    by UPN, and prints the count. Use -AllSubscriptions to sweep every enabled
    subscription visible to the current Az context.

    Examples:
        .\Get-ActiveAvdUniqueUserCount.ps1
        .\Get-ActiveAvdUniqueUserCount.ps1 -AllSubscriptions
        .\Get-ActiveAvdUniqueUserCount.ps1 -SubscriptionId '<subscription-id>' -ShowSessions
        .\Get-ActiveAvdUniqueUserCount.ps1 -QuietCount
#>

[CmdletBinding()]
param(
    [string[]]$SubscriptionId,

    [switch]$AllSubscriptions,

    [ValidateNotNullOrEmpty()]
    [string[]]$SessionState = @('Active', 'Disconnected'),

    [switch]$ShowSessions,

    [switch]$QuietCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-RequiredModule {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' was not found. Install it with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop
}

function Get-ResourceGroupNameFromId {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId
    )

    if ($ResourceId -match '/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    throw "Could not parse resource group from resource ID: $ResourceId"
}

function Get-HostPoolName {
    param(
        [Parameter(Mandatory)]
        [object]$HostPool
    )

    if ($HostPool.Name) {
        return $HostPool.Name
    }

    if ($HostPool.Id -match '/hostPools/([^/]+)$') {
        return $Matches[1]
    }

    throw "Could not determine host pool name from resource ID: $($HostPool.Id)"
}

function Get-SessionHostNameFromId {
    param(
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    if ($ResourceId -match '/sessionHosts/([^/]+)/userSessions/') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    return $null
}

Import-RequiredModule -Name 'Az.Accounts'
Import-RequiredModule -Name 'Az.DesktopVirtualization'

$context = Get-AzContext
if (-not $context) {
    throw "No Azure context found. Run Connect-AzAccount first."
}

if ($AllSubscriptions -and $SubscriptionId) {
    throw "Use either -AllSubscriptions or -SubscriptionId, not both."
}

if ($AllSubscriptions) {
    $targetSubscriptionIds = @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' } | Select-Object -ExpandProperty Id)
}
elseif ($SubscriptionId) {
    $targetSubscriptionIds = @($SubscriptionId)
}
else {
    $targetSubscriptionIds = @($context.Subscription.Id)
}

if (-not $targetSubscriptionIds -or $targetSubscriptionIds.Count -eq 0) {
    throw "No target subscriptions found."
}

$matchingSessions = foreach ($subId in $targetSubscriptionIds) {
    Write-Verbose "Querying host pools in subscription $subId"

    try {
        $hostPools = @(Get-AzWvdHostPool -SubscriptionId $subId)
    }
    catch {
        Write-Warning "Failed to list host pools in subscription $subId. $($_.Exception.Message)"
        continue
    }

    foreach ($hostPool in $hostPools) {
        $resourceGroupName = Get-ResourceGroupNameFromId -ResourceId $hostPool.Id
        $hostPoolName = Get-HostPoolName -HostPool $hostPool

        Write-Verbose "Querying user sessions in $subId/$resourceGroupName/$hostPoolName"

        try {
            $sessions = @(Get-AzWvdUserSession -SubscriptionId $subId -ResourceGroupName $resourceGroupName -HostPoolName $hostPoolName)
        }
        catch {
            Write-Warning "Failed to list user sessions in $subId/$resourceGroupName/$hostPoolName. $($_.Exception.Message)"
            continue
        }

        foreach ($session in $sessions) {
            $upn = [string]$session.UserPrincipalName
            $state = [string]$session.SessionState

            if ([string]::IsNullOrWhiteSpace($upn)) {
                continue
            }

            if ($SessionState -notcontains $state) {
                continue
            }

            [pscustomobject]@{
                UserPrincipalName = $upn.Trim().ToLowerInvariant()
                DisplayUpn        = $upn.Trim()
                SessionState      = $state
                SubscriptionId    = $subId
                ResourceGroupName = $resourceGroupName
                HostPoolName      = $hostPoolName
                SessionHostName   = Get-SessionHostNameFromId -ResourceId $session.Id
                SessionId         = $session.Id
            }
        }
    }
}

$uniqueUsers = @(
    $matchingSessions |
        Group-Object -Property UserPrincipalName |
        Sort-Object -Property Name |
        ForEach-Object {
            $firstSession = $_.Group | Select-Object -First 1

            [pscustomobject]@{
                UserPrincipalName = $firstSession.DisplayUpn
                MatchingSessionCount = $_.Count
            }
        }
)

if ($QuietCount) {
    $uniqueUsers.Count
    return
}

if ($ShowSessions) {
    $matchingSessions |
        Sort-Object -Property UserPrincipalName, SubscriptionId, ResourceGroupName, HostPoolName, SessionHostName |
        Format-Table -AutoSize UserPrincipalName, SessionState, SubscriptionId, ResourceGroupName, HostPoolName, SessionHostName

    Write-Host ''
}

$uniqueUsers | Format-Table -AutoSize UserPrincipalName, MatchingSessionCount
Write-Host ''
Write-Host "Unique AVD users with session state [$($SessionState -join ', ')]: $($uniqueUsers.Count)"
