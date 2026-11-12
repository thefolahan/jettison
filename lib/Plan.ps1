# Turns the catalog into a list of plan items, each with the state it is in on this machine:
#   Pending   - the optimization applies and has not been done
#   Optimized - already in the target state
#   Absent    - the app / service / task does not exist here, so there is nothing to do

function New-JtItem {
    param($Kind, $Id, $Label, $Tier, $State, $Detail, $Data, [int]$Weight = 1)
    [pscustomobject]@{
        Kind   = $Kind
        Key    = "${Kind}:$Id"
        Label  = $Label
        Tier   = $Tier
        State  = $State
        Detail = $Detail
        Weight = $Weight
        Data   = $Data
        Result = $null
        Error  = $null
    }
}

function Test-JtProtected {
    param([string]$Name, [string[]]$Protected)
    foreach ($pattern in $Protected) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-JtAppItems {
    param($Catalog, [bool]$IsAdmin)

    # -AllUsers needs elevation; without it we only see the current user's packages.
    if ($IsAdmin) { $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) }
    else { $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue) }

    $removable = $installed | Where-Object {
        -not $_.IsFramework -and -not $_.NonRemovable -and
        -not (Test-JtProtected -Name $_.Name -Protected $Catalog.protected)
    }

    foreach ($entry in $Catalog.apps) {
        $matches_ = @($removable | Where-Object { $_.Name -like $entry.id } |
            Sort-Object PackageFullName -Unique)
        if ($matches_.Count -gt 0) {
            $detail = ($matches_ | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            New-JtItem App $entry.id $entry.label $entry.tier 'Pending' $detail @{ Pattern = $entry.id; Packages = $matches_ }
        }
        else {
            New-JtItem App $entry.id $entry.label $entry.tier 'Absent' 'not installed' $null
        }
    }
}

function Get-JtRegistryValue {
    param([string]$Path, [string]$Name)
    $result = @{ Exists = $false; Value = $null; Type = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -contains $Name) {
        $result.Exists = $true
        $result.Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        $result.Type = [string]$key.GetValueKind($Name)
    }
    return $result
}

function Get-JtTweakItems {
    param($Catalog)
    foreach ($entry in $Catalog.tweaks) {
        $current = Get-JtRegistryValue -Path $entry.path -Name $entry.name
        if ($current.Exists -and ([string]$current.Value -eq [string]$entry.value)) {
            $state = 'Optimized'
        }
        else { $state = 'Pending' }
        if ($current.Exists) { $shown = [string]$current.Value } else { $shown = '(not set)' }
        $detail = '{0} = {1}, target {2}' -f $entry.name, $shown, $entry.value
        New-JtItem Tweak $entry.id $entry.label $entry.tier $state $detail $entry
    }
}

function Get-JtServiceItems {
    param($Catalog)
    foreach ($entry in $Catalog.services) {
        $svc = Get-Service -Name $entry.id -ErrorAction SilentlyContinue
        if (-not $svc) {
            New-JtItem Service $entry.id $entry.label $entry.tier 'Absent' 'not present' $null 2
            continue
        }
        if ($svc.StartType -eq 'Disabled') { $state = 'Optimized' } else { $state = 'Pending' }
        $detail = '{0}, {1}' -f $svc.StartType, $svc.Status
        New-JtItem Service $entry.id $entry.label $entry.tier $state $detail @{ Name = $entry.id } 2
    }
}

function Get-JtTaskItems {
    param($Catalog)
    foreach ($entry in $Catalog.tasks) {
        $cut = $entry.id.LastIndexOf('\')
        $taskPath = $entry.id.Substring(0, $cut + 1)
        $taskName = $entry.id.Substring($cut + 1)
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            New-JtItem Task $entry.id $entry.label $entry.tier 'Absent' 'not present' $null
            continue
        }
        if ($task.State -eq 'Disabled') { $state = 'Optimized' } else { $state = 'Pending' }
        New-JtItem Task $entry.id $entry.label $entry.tier $state ([string]$task.State) @{ TaskPath = $taskPath; TaskName = $taskName }
    }
}

function Get-JtPlan {
    param($Catalog, [string[]]$Skip, [bool]$IsAdmin)
    $items = @()
    if ($Skip -notcontains 'Apps') { $items += @(Get-JtAppItems -Catalog $Catalog -IsAdmin $IsAdmin) }
    if ($Skip -notcontains 'Tweaks') { $items += @(Get-JtTweakItems -Catalog $Catalog) }
    if ($Skip -notcontains 'Services') { $items += @(Get-JtServiceItems -Catalog $Catalog) }
    if ($Skip -notcontains 'Tasks') { $items += @(Get-JtTaskItems -Catalog $Catalog) }
    return $items
}

# Score = share (by weight) of the optimizations that applied to this machine at baseline
# and are now done. Things that were never here (Absent at baseline) are left out of both
# sides, so a clean machine is not rewarded for bloat it never had.
function Get-JtScore {
    param($Baseline, $Current)
    $now = @{}
    foreach ($item in $Current) { $now[$item.Key] = $item.State }

    $total = 0
    $done = 0
    foreach ($item in $Baseline) {
        if ($item.State -eq 'Absent') { continue }
        $total += $item.Weight
        if ($now.ContainsKey($item.Key)) { $state = $now[$item.Key] } else { $state = $item.State }
        if ($state -eq 'Optimized' -or $state -eq 'Absent') { $done += $item.Weight }
    }
    if ($total -eq 0) { return 100.0 }
    return [math]::Round(100.0 * $done / $total, 1)
}

# The slice of a plan that is safe to write to the journal (no live package objects).
function ConvertTo-JtPlanRecord {
    param($Plan)
    @($Plan | Select-Object Kind, Key, Label, Tier, State, Detail, Weight, Result, Error)
}
