<#

If running as a function app, keep these commented. If running via Cloud Shell etc, set these as appropriate:

$env:AVD_TAG_WHATIF = 'true'
$env:AVD_TAG_ALL_SUBSCRIPTIONS = 'false'
$env:AVD_TAG_SUBSCRIPTION_IDS = '<subscription-id>'
$env:AVD_AGENT_VERSION_TAG_NAME = 'AVD-AgentVersion'

#>

param($Timer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Information $line -InformationAction Continue
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$DefaultValue = ''
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    $value.Trim()
}

function Get-EnvironmentBool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [bool]$DefaultValue = $false
    )

    $value = Get-EnvironmentValue -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    switch -Regex ($value.Trim()) {
        '^(1|true|yes|y)$' { return $true }
        '^(0|false|no|n)$' { return $false }
        default { throw "App setting '$Name' must be true or false. Current value: '$value'." }
    }
}

function Get-EnvironmentList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = Get-EnvironmentValue -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        return @()
    }

    @(
        $value -split '[,;]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }

    $property.Value
}

function Get-NestedPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $currentObject = $InputObject
    foreach ($name in $Names) {
        if (-not $currentObject) {
            return $null
        }

        $currentObject = Get-ObjectPropertyValue -InputObject $currentObject -Name $name
    }

    $currentObject
}

function Get-ResourceGroupNameFromId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -match '/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    throw "Could not parse resource group from resource ID: $ResourceId"
}

function Get-ResourceNameFromId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -match '/([^/]+)$') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    throw "Could not parse resource name from resource ID: $ResourceId"
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    $response.Content | ConvertFrom-Json
}

function Convert-ArmNextLinkToPath {
    param(
        [string]$NextLink
    )

    if ([string]::IsNullOrWhiteSpace($NextLink)) {
        return $null
    }

    if ($NextLink -match '^https?://') {
        $uri = [Uri]$NextLink
        return '{0}{1}' -f $uri.AbsolutePath, $uri.Query
    }

    $NextLink
}

function Get-AvdSessionHosts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostPoolResourceId
    )

    $path = '{0}/sessionHosts?api-version=2024-04-03' -f $HostPoolResourceId
    $sessionHosts = @()

    do {
        $page = Invoke-ArmGet -Path $path
        if ($page -and $page.value) {
            $sessionHosts += @($page.value)
        }

        $path = Convert-ArmNextLinkToPath -NextLink ([string](Get-ObjectPropertyValue -InputObject $page -Name 'nextLink'))
    }
    while (-not [string]::IsNullOrWhiteSpace($path))

    $sessionHosts
}

function Get-SessionHostAgentVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SessionHost,

        [Parameter(Mandatory = $true)]
        [string]$UnknownValue
    )

    $agentVersion = [string](Get-NestedPropertyValue -InputObject $SessionHost -Names @('properties', 'agentVersion'))
    if (-not [string]::IsNullOrWhiteSpace($agentVersion)) {
        return $agentVersion
    }

    $UnknownValue
}

function Get-SessionHostVmResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SessionHost
    )

    $vmResourceId = [string](Get-NestedPropertyValue -InputObject $SessionHost -Names @('properties', 'resourceId'))
    if ($vmResourceId -match '/providers/Microsoft\.Compute/virtualMachines/') {
        return $vmResourceId
    }

    return $null
}

function Get-SessionHostDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SessionHost
    )

    $id = [string](Get-ObjectPropertyValue -InputObject $SessionHost -Name 'Id')
    if ($id -match '/sessionHosts/([^/]+)$') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    'UnknownSessionHost'
}

function Set-VmAgentVersionTag {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$AgentVersion,

        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [Parameter(Mandatory = $true)]
        [bool]$WhatIf
    )

    $tag = @{
        $TagName = $AgentVersion
    }

    if ($WhatIf) {
        Write-Log -Message "[WHATIF] Would set tag on VM ${VmResourceId}: $TagName = $AgentVersion"
        return $false
    }

    Update-AzTag -ResourceId $VmResourceId -Tag $tag -Operation Merge -ErrorAction Stop | Out-Null
    Write-Log -Message "Set tag on VM ${VmResourceId}: $TagName = $AgentVersion"
    return $true
}

function Get-TargetSubscriptionIds {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$AllSubscriptions,

        [Parameter(Mandatory = $true)]
        [string[]]$ConfiguredSubscriptionIds
    )

    $context = Get-AzContext
    if (-not $context) {
        Write-Log -Message 'No Az context found. Connecting with managed identity.'
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }

    if (-not $context) {
        throw 'No Azure context found after managed identity login.'
    }

    if ($AllSubscriptions -and $ConfiguredSubscriptionIds.Count -gt 0) {
        throw 'Use either AVD_TAG_ALL_SUBSCRIPTIONS=true or AVD_TAG_SUBSCRIPTION_IDS, not both.'
    }

    if ($AllSubscriptions) {
        Write-Log -Message 'Finding all enabled subscriptions visible to the function managed identity.'
        return @(
            Get-AzSubscription -ErrorAction Stop |
                Where-Object { [string](Get-ObjectPropertyValue -InputObject $_ -Name 'State') -eq 'Enabled' } |
                ForEach-Object { [string](Get-ObjectPropertyValue -InputObject $_ -Name 'Id') }
        )
    }

    if ($ConfiguredSubscriptionIds.Count -gt 0) {
        return @($ConfiguredSubscriptionIds)
    }

    @($context.Subscription.Id)
}

$allSubscriptions = Get-EnvironmentBool -Name 'AVD_TAG_ALL_SUBSCRIPTIONS' -DefaultValue $false
$configuredSubscriptionIds = @(Get-EnvironmentList -Name 'AVD_TAG_SUBSCRIPTION_IDS')
$tagName = Get-EnvironmentValue -Name 'AVD_AGENT_VERSION_TAG_NAME' -DefaultValue 'AVD-AgentVersion'
$unknownAgentVersion = Get-EnvironmentValue -Name 'AVD_UNKNOWN_AGENT_VERSION_TAG_VALUE' -DefaultValue 'Unknown'
$whatIf = Get-EnvironmentBool -Name 'AVD_TAG_WHATIF' -DefaultValue $true

$isPastDue = $false
if ($Timer -and $Timer.PSObject.Properties['IsPastDue']) {
    $isPastDue = [bool]$Timer.IsPastDue
}

Write-Log -Message 'Starting AVD Agent version tag sync.'
Write-Log -Message "Past due timer invocation: $isPastDue"
Write-Log -Message "Tag name: $tagName"
Write-Log -Message "All subscriptions: $allSubscriptions"
Write-Log -Message "Configured subscription count: $($configuredSubscriptionIds.Count)"
Write-Log -Message "WhatIf mode: $whatIf"

$subscriptionIds = @(Get-TargetSubscriptionIds -AllSubscriptions $allSubscriptions -ConfiguredSubscriptionIds $configuredSubscriptionIds)
if ($subscriptionIds.Count -eq 0) {
    throw 'No target subscriptions found.'
}

Write-Log -Message "Target subscription count: $($subscriptionIds.Count)"

$processedHosts = 0
$taggedVms = 0
$wouldTagVms = 0
$skippedHosts = 0

foreach ($subscriptionId in $subscriptionIds) {
    Write-Log -Message "Switching to subscription: $subscriptionId"
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

    Write-Log -Message "Listing AVD host pools in subscription: $subscriptionId"
    $hostPools = @(Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostPools' -ErrorAction Stop)
    Write-Log -Message "Found $($hostPools.Count) host pool(s) in subscription: $subscriptionId"

    foreach ($hostPool in $hostPools) {
        $hostPoolId = [string](Get-ObjectPropertyValue -InputObject $hostPool -Name 'Id')
        $resourceGroupName = Get-ResourceGroupNameFromId -ResourceId $hostPoolId
        $hostPoolName = Get-ResourceNameFromId -ResourceId $hostPoolId

        Write-Log -Message "Listing session hosts in host pool: $resourceGroupName/$hostPoolName"
        $sessionHosts = @(Get-AvdSessionHosts -HostPoolResourceId $hostPoolId)
        Write-Log -Message "Found $($sessionHosts.Count) session host(s) in host pool: $resourceGroupName/$hostPoolName"

        foreach ($sessionHost in $sessionHosts) {
            $processedHosts++

            $sessionHostName = Get-SessionHostDisplayName -SessionHost $sessionHost
            $agentVersion = Get-SessionHostAgentVersion -SessionHost $sessionHost -UnknownValue $unknownAgentVersion
            $vmResourceId = Get-SessionHostVmResourceId -SessionHost $sessionHost

            Write-Log -Message "Session host $sessionHostName reports AVD Agent version: $agentVersion"

            if ([string]::IsNullOrWhiteSpace($vmResourceId)) {
                $skippedHosts++
                Write-Log -Level 'WARN' -Message "Skipping $sessionHostName because AVD did not report a VM resource ID."
                continue
            }

            $tagWritten = Set-VmAgentVersionTag -VmResourceId $vmResourceId -AgentVersion $agentVersion -TagName $tagName -WhatIf $whatIf
            if ($tagWritten) {
                $taggedVms++
            }
            else {
                $wouldTagVms++
            }
        }
    }
}

Write-Log -Message "AVD Agent version tag sync completed. Processed hosts: $processedHosts. Tagged VMs: $taggedVms. Would tag VMs: $wouldTagVms. Skipped hosts: $skippedHosts."
