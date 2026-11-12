# Applies plan items and records what was changed so Revert can put it back.
# Every Invoke-Jt* function returns the change records for the journal and throws on failure.

function Invoke-JtApp {
    param($Item, $Provisioned)
    $changes = @()
    foreach ($pkg in $Item.Data.Packages) {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        $changes += @{ Kind = 'App'; Name = $pkg.Name; PackageFullName = $pkg.PackageFullName }
    }
    # Also drop the provisioned copy, otherwise Windows reinstalls it for every new user.
    foreach ($prov in @($Provisioned | Where-Object { $_.DisplayName -like $Item.Data.Pattern })) {
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
    }
    return $changes
}

function Set-JtRegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type)
    # New-Item -Force would wipe an existing key, so only create it when it is missing.
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    if ($Type -eq 'Binary') { $Value = [byte[]]$Value }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Invoke-JtTweak {
    param($Item)
    $entry = $Item.Data
    $old = Get-JtRegistryValue -Path $entry.path -Name $entry.name
    Set-JtRegistryValue -Path $entry.path -Name $entry.name -Value $entry.value -Type $entry.type
    return @{
        Kind = 'Registry'; Path = $entry.path; Name = $entry.name
        Existed = $old.Exists; OldValue = $old.Value; OldType = $old.Type
    }
}

function Invoke-JtService {
    param($Item)
    $name = $Item.Data.Name
    $svc = Get-Service -Name $name -ErrorAction Stop
    $delayed = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction SilentlyContinue).DelayedAutostart
    $change = @{
        Kind = 'Service'; Name = $name
        OldStartType = [string]$svc.StartType
        WasRunning = ($svc.Status -eq 'Running')
        WasDelayed = ($delayed -eq 1)
    }
    Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
    # A service that refuses to stop is still disabled from the next boot, so that is not a failure.
    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    return $change
}

function Invoke-JtTask {
    param($Item)
    Disable-ScheduledTask -TaskPath $Item.Data.TaskPath -TaskName $Item.Data.TaskName -ErrorAction Stop | Out-Null
    return @{ Kind = 'Task'; TaskPath = $Item.Data.TaskPath; TaskName = $Item.Data.TaskName }
}

# Runs every Pending item. Sets Result/Error on each item and returns the journal change records.
function Invoke-JtPlan {
    param($Plan)
    $changes = @()
    $pending = @($Plan | Where-Object { $_.State -eq 'Pending' })

    $provisioned = @()
    if ($pending | Where-Object { $_.Kind -eq 'App' }) {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    }

    foreach ($item in $pending) {
        try {
            switch ($item.Kind) {
                'App' { $changes += @(Invoke-JtApp -Item $item -Provisioned $provisioned) }
                'Tweak' { $changes += @(Invoke-JtTweak -Item $item) }
                'Service' { $changes += @(Invoke-JtService -Item $item) }
                'Task' { $changes += @(Invoke-JtTask -Item $item) }
            }
            $item.Result = 'Applied'
            Write-JtLine 'done' ('{0}: {1}' -f $item.Kind, $item.Label) 'Green'
        }
        catch {
            $item.Result = 'Failed'
            $item.Error = $_.Exception.Message
            Write-JtLine 'failed' ('{0}: {1} - {2}' -f $item.Kind, $item.Label, $item.Error) 'Red'
        }
    }
    return $changes
}

# Undoes the registry, service and task changes in a journal, newest first.
# Removed apps cannot be restored offline; they are listed so they can be reinstalled.
function Undo-JtChanges {
    param($Changes)
    $failed = 0
    $apps = @()
    $ordered = @($Changes)
    [array]::Reverse($ordered)

    foreach ($change in $ordered) {
        try {
            switch ($change.Kind) {
                'Registry' {
                    if ($change.Existed) {
                        Set-JtRegistryValue -Path $change.Path -Name $change.Name -Value $change.OldValue -Type $change.OldType
                    }
                    elseif (Test-Path -LiteralPath $change.Path) {
                        Remove-ItemProperty -LiteralPath $change.Path -Name $change.Name -ErrorAction SilentlyContinue
                    }
                    Write-JtLine 'undone' ('Registry: {0}\{1}' -f $change.Path, $change.Name) 'Green'
                }
                'Service' {
                    if ($change.OldStartType -eq 'Automatic' -and $change.WasDelayed) {
                        & sc.exe config $change.Name start= delayed-auto | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed with exit code $LASTEXITCODE" }
                    }
                    else {
                        Set-Service -Name $change.Name -StartupType $change.OldStartType -ErrorAction Stop
                    }
                    if ($change.WasRunning) {
                        Start-Service -Name $change.Name -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    }
                    Write-JtLine 'undone' ('Service: {0} -> {1}' -f $change.Name, $change.OldStartType) 'Green'
                }
                'Task' {
                    Enable-ScheduledTask -TaskPath $change.TaskPath -TaskName $change.TaskName -ErrorAction Stop | Out-Null
                    Write-JtLine 'undone' ('Task: {0}{1}' -f $change.TaskPath, $change.TaskName) 'Green'
                }
                'App' { $apps += $change.Name }
            }
        }
        catch {
            $failed++
            Write-JtLine 'failed' ('{0}: {1}' -f $change.Kind, $_.Exception.Message) 'Red'
        }
    }
    return @{ Failed = $failed; Apps = @($apps | Sort-Object -Unique) }
}
