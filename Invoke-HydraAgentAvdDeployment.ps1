[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,

    [string]$Uri,

    [string]$Secret,

    [string]$InstallerPath = (Join-Path $PSScriptRoot 'ITPC-DeployHydraAgent.ps1'),

    [string]$InstallerUri = 'https://raw.githubusercontent.com/MarcelMeurer/WVD-Hydra/refs/heads/main/bin/app_data/Jobs/Continuous/WorkerEngine/Scripts/ITPC-DeployHydraAgent.ps1',

    [string[]]$HostPoolName,

    [string[]]$ResourceGroupName,

    [switch]$AsJob,

    [switch]$StopOnError,

    [switch]$PowerOn,

    [int]$PowerOnTimeoutSeconds = 300,

    [switch]$RepairPerfmon
)

function Get-HydraVmPowerState {
    param(
        [Parameter(Mandatory)]
        [object]$VM
    )

    $statuses = @($VM.Statuses) + @($VM.InstanceView.Statuses)
    $powerStatus = $statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1
    if ($powerStatus) {
        if ($powerStatus.DisplayStatus) {
            return $powerStatus.DisplayStatus
        }

        return $powerStatus.Code
    }

    return 'Unknown'
}

function Save-HydraInstallerScript {
    param(
        [Parameter(Mandatory)]
        [string]$InstallerPath,

        [Parameter(Mandatory)]
        [string]$InstallerUri
    )

    $installerDirectory = Split-Path -Path $InstallerPath -Parent
    if ($installerDirectory -and -not (Test-Path -LiteralPath $installerDirectory -PathType Container)) {
        New-Item -Path $installerDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    Write-Host "Installer script was not found at '$InstallerPath'. Downloading from '$InstallerUri'..."
    Invoke-WebRequest -Uri $InstallerUri -OutFile $InstallerPath -UseBasicParsing -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Installer download completed, but the file was not found at '$InstallerPath'."
    }
}

function Test-HydraVmPowerStateRunning {
    param(
        [Parameter(Mandatory)]
        [string]$PowerState
    )

    return ($PowerState -eq 'VM running' -or $PowerState -eq 'PowerState/running')
}

function Get-HydraVmAgentState {
    param(
        [Parameter(Mandatory)]
        [object]$VM
    )

    $agentStatuses = @($VM.VMAgent.Statuses) + @($VM.InstanceView.VMAgent.Statuses)
    $readyStatus = $agentStatuses |
        Where-Object { $_.DisplayStatus -eq 'Ready' -or $_.Code -eq 'ProvisioningState/succeeded' } |
        Select-Object -First 1

    if ($readyStatus) {
        return 'Ready'
    }

    $agentStatus = $agentStatuses | Select-Object -First 1
    if ($agentStatus) {
        if ($agentStatus.DisplayStatus) {
            return $agentStatus.DisplayStatus
        }

        return $agentStatus.Code
    }

    return 'Unknown'
}

function Wait-HydraVmReadyForRunCommand {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status -ErrorAction Stop
        $powerState = Get-HydraVmPowerState -VM $vm
        $agentState = Get-HydraVmAgentState -VM $vm

        if ((Test-HydraVmPowerStateRunning -PowerState $powerState) -and $agentState -eq 'Ready') {
            return $vm
        }

        Write-Host "Waiting for '$ResourceGroupName/$Name' to be ready. Power state: $powerState; VM agent: $agentState"
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)

    throw "Timed out after $TimeoutSeconds seconds waiting for '$ResourceGroupName/$Name' to be running with the VM agent ready."
}

function Invoke-HydraAgentAvdDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Secret,

        [string]$InstallerPath = (Join-Path $PSScriptRoot 'ITPC-DeployHydraAgent.ps1'),

        [string]$InstallerUri = 'https://raw.githubusercontent.com/MarcelMeurer/WVD-Hydra/refs/heads/main/bin/app_data/Jobs/Continuous/WorkerEngine/Scripts/ITPC-DeployHydraAgent.ps1',

        [string[]]$HostPoolName,

        [string[]]$ResourceGroupName,

        [switch]$AsJob,

        [switch]$StopOnError,

        [switch]$PowerOn,

        [int]$PowerOnTimeoutSeconds = 300,

        [switch]$RepairPerfmon
    )

    $requiredCommands = @(
        'Set-AzContext',
        'Get-AzResourceGroup',
        'Get-AzWvdHostPool',
        'Get-AzWvdSessionHost',
        'Get-AzVM',
        'Invoke-WebRequest',
        'Start-AzVM',
        'Invoke-AzVMRunCommand'
    )

    foreach ($command in $requiredCommands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required Azure PowerShell command '$command' was not found. Install/import the Az.Accounts, Az.Compute, and Az.DesktopVirtualization modules."
        }
    }

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        Save-HydraInstallerScript -InstallerPath $InstallerPath -InstallerUri $InstallerUri
    }

    Write-Host "Setting Azure context to subscription '$SubscriptionId'..."
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

    $hostPools = if ($ResourceGroupName) {
        foreach ($rg in $ResourceGroupName) {
            Write-Host "Finding host pools in resource group '$rg'..."
            Get-AzWvdHostPool -ResourceGroupName $rg -ErrorAction Stop
        }
    }
    else {
        Write-Host "Finding resource groups in subscription '$SubscriptionId'..."
        foreach ($rg in Get-AzResourceGroup -ErrorAction Stop) {
            Write-Host "Finding host pools in resource group '$($rg.ResourceGroupName)'..."
            Get-AzWvdHostPool -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
        }
    }

    $hostPools = @($hostPools)

    if ($HostPoolName) {
        $hostPools = $hostPools | Where-Object { $_.Name -in $HostPoolName }
    }

    if (-not $hostPools) {
        throw "No AVD host pools matched the supplied filters in subscription '$SubscriptionId'."
    }

    Write-Host "Found $($hostPools.Count) matching host pool(s)."

    $sessionHosts = foreach ($pool in $hostPools) {
        Write-Host "Finding session hosts in host pool '$($pool.Name)'..."
        Get-AzWvdSessionHost -ResourceGroupName $pool.ResourceGroupName -HostPoolName $pool.Name -ErrorAction Stop |
            Select-Object @{ Name = 'HostPoolName'; Expression = { $pool.Name } },
                          @{ Name = 'HostPoolResourceGroupName'; Expression = { $pool.ResourceGroupName } },
                          Name,
                          AllowNewSession,
                          Status
    }

    if (-not $sessionHosts) {
        throw "No AVD session hosts were found in the matched host pools."
    }

    $sessionHosts = @($sessionHosts)
    Write-Host "Found $($sessionHosts.Count) session host(s)."
    Write-Host "Finding VMs in subscription '$SubscriptionId'..."
    $vmsByName = Get-AzVM -Status -ErrorAction Stop | Group-Object -Property Name -AsHashTable -AsString
    $runCommandParameters = @{
        uri    = $Uri
        secret = $Secret
    }

    $repairPerfmonScriptPath = $null
    if ($RepairPerfmon) {
        $repairPerfmonScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "Repair-Perfmon-$(New-Guid).ps1"
        Set-Content -LiteralPath $repairPerfmonScriptPath -Value 'lodctr /R' -Encoding UTF8 -ErrorAction Stop
    }

    try {
        $results = foreach ($sessionHost in $sessionHosts) {
        $sessionHostName = ($sessionHost.Name -split '/', 2)[-1]
        $vmName = ($sessionHostName -split '\.', 2)[0]
        $matches = @($vmsByName[$vmName])

        if ($matches.Count -eq 0) {
            Write-Warning "Skipping '$sessionHostName' from host pool '$($sessionHost.HostPoolName)': no VM named '$vmName' was found in subscription '$SubscriptionId'."
            [pscustomobject]@{
                SessionHost   = $sessionHostName
                ResourceGroup = $null
                VMName        = $vmName
                Status        = 'Skipped'
                Message       = "No VM named '$vmName' was found."
            }
            continue
        }

        if ($matches.Count -gt 1) {
            Write-Warning "Skipping '$sessionHostName' from host pool '$($sessionHost.HostPoolName)': multiple VMs named '$vmName' were found. Use ResourceGroupName or rename duplicates to make this unambiguous."
            [pscustomobject]@{
                SessionHost   = $sessionHostName
                ResourceGroup = $null
                VMName        = $vmName
                Status        = 'Skipped'
                Message       = "Multiple VMs named '$vmName' were found."
            }
            continue
        }

        $vm = $matches[0]
        $target = "$($vm.ResourceGroupName)/$($vm.Name)"

        if ($PowerOn) {
            try {
                $vm = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status -ErrorAction Stop
                $powerState = Get-HydraVmPowerState -VM $vm
                $agentState = Get-HydraVmAgentState -VM $vm

                if (-not (Test-HydraVmPowerStateRunning -PowerState $powerState)) {
                    if ($PSCmdlet.ShouldProcess($target, "Start VM and wait up to $PowerOnTimeoutSeconds seconds")) {
                        Write-Host "Starting '$target'. Current state: $powerState"
                        Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait -ErrorAction Stop | Out-Null
                        $vm = Wait-HydraVmReadyForRunCommand -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -TimeoutSeconds $PowerOnTimeoutSeconds
                    }
                }
                else {
                    Write-Host "'$target' is already running. VM agent: $agentState"
                    if ($agentState -ne 'Ready') {
                        $vm = Wait-HydraVmReadyForRunCommand -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -TimeoutSeconds $PowerOnTimeoutSeconds
                    }
                }
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "Power-on check/start failed on '$target': $message"

                if ($StopOnError) {
                    throw
                }

                [pscustomobject]@{
                    SessionHost   = $sessionHostName
                    ResourceGroup = $vm.ResourceGroupName
                    VMName        = $vm.Name
                    Status        = 'Failed'
                    Message       = "Power-on failed: $message"
                }
                continue
            }
        }

        if ($RepairPerfmon -and $PSCmdlet.ShouldProcess($target, 'Repair performance counters by Azure Run Command')) {
            Write-Host "Repairing performance counters on '$target'..."

            try {
                Invoke-AzVMRunCommand `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -Name $vm.Name `
                    -CommandId 'RunPowerShellScript' `
                    -ScriptPath $repairPerfmonScriptPath `
                    -ErrorAction Stop | Out-Null

                [pscustomobject]@{
                    SessionHost   = $sessionHostName
                    ResourceGroup = $vm.ResourceGroupName
                    VMName        = $vm.Name
                    Status        = 'PerfmonRepaired'
                    Message       = 'lodctr /R completed.'
                }
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "Perfmon repair failed on '$target': $message"

                if ($StopOnError) {
                    throw
                }

                [pscustomobject]@{
                    SessionHost   = $sessionHostName
                    ResourceGroup = $vm.ResourceGroupName
                    VMName        = $vm.Name
                    Status        = 'PerfmonRepairFailed'
                    Message       = $message
                }
            }
        }

        if ($PSCmdlet.ShouldProcess($target, 'Install or update Hydra agent by Azure Run Command')) {
            Write-Host "Invoking Hydra installer on '$target'..."
            $invokeArgs = @{
                ResourceGroupName = $vm.ResourceGroupName
                Name              = $vm.Name
                CommandId         = 'RunPowerShellScript'
                ScriptPath        = $InstallerPath
                Parameter         = $runCommandParameters
                ErrorAction       = 'Stop'
            }

            try {
                if ($AsJob) {
                    $runCommandResult = Invoke-AzVMRunCommand @invokeArgs -AsJob
                }
                else {
                    $runCommandResult = Invoke-AzVMRunCommand @invokeArgs
                }

                [pscustomobject]@{
                    SessionHost   = $sessionHostName
                    ResourceGroup = $vm.ResourceGroupName
                    VMName        = $vm.Name
                    Status        = if ($AsJob) { 'Started' } else { 'Succeeded' }
                    Message       = if ($AsJob) { "Job '$($runCommandResult.Id)' was started." } else { 'Run Command completed.' }
                }
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "Run Command failed on '$target': $message"

                if ($StopOnError) {
                    throw
                }

                [pscustomobject]@{
                    SessionHost   = $sessionHostName
                    ResourceGroup = $vm.ResourceGroupName
                    VMName        = $vm.Name
                    Status        = 'Failed'
                    Message       = $message
                }
            }
        }
    }

        if ($results) {
            $results | Format-Table -AutoSize
        }
    }
    finally {
        if ($repairPerfmonScriptPath -and (Test-Path -LiteralPath $repairPerfmonScriptPath)) {
            Remove-Item -LiteralPath $repairPerfmonScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-HydraAgentAvdDeployment @PSBoundParameters
}
