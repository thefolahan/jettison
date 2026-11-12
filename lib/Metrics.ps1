function Get-JtLastBootMs {

    try {
        $record = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' `
            -FilterXPath '*[System[EventID=100]]' -MaxEvents 1 -ErrorAction Stop
        $data = ([xml]$record.ToXml()).Event.EventData.Data
        return [int]($data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
    }
    catch { return $null }
}

function Get-JtMetrics {
    $os = Get-CimInstance Win32_OperatingSystem
    $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
    [pscustomobject]@{
        TakenAt         = (Get-Date).ToString('s')
        UptimeMinutes   = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
        Processes       = @(Get-Process).Count
        ServicesRunning = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count
        RamUsedMB       = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
        RamTotalMB      = [int]($os.TotalVisibleMemorySize / 1024)
        StartupItems    = @(Get-CimInstance Win32_StartupCommand).Count
        StoreApps       = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework }).Count
        DiskFreeBytes   = [double]$drive.FreeSpace
        LastBootMs      = Get-JtLastBootMs
    }
}

function Get-JtMetricRows {
    param($Before, $After)
    $defs = @(
        @{ Name = 'Running processes'; Prop = 'Processes'; Lower = $true; Fmt = '{0:N0}' }
        @{ Name = 'Running services'; Prop = 'ServicesRunning'; Lower = $true; Fmt = '{0:N0}' }
        @{ Name = 'Memory in use (MB)'; Prop = 'RamUsedMB'; Lower = $true; Fmt = '{0:N0}' }
        @{ Name = 'Startup items'; Prop = 'StartupItems'; Lower = $true; Fmt = '{0:N0}' }
        @{ Name = 'Store apps installed'; Prop = 'StoreApps'; Lower = $true; Fmt = '{0:N0}' }
        @{ Name = 'Free disk space (GB)'; Prop = 'DiskFreeBytes'; Lower = $false; Fmt = '{0:N2}'; Scale = 1GB }
        @{ Name = 'Last boot time (s)'; Prop = 'LastBootMs'; Lower = $true; Fmt = '{0:N1}'; Scale = 1000 }
    )
    foreach ($def in $defs) {
        $b = $Before.($def.Prop)
        $a = $After.($def.Prop)
        if ($null -eq $b -or $null -eq $a) { continue }
        $scale = 1
        if ($def.Scale) { $scale = $def.Scale }
        $b = $b / $scale
        $a = $a / $scale
        if ($b -ne 0) { $pct = [math]::Round(100.0 * ($a - $b) / $b, 1) } else { $pct = 0 }
        $better = (($def.Lower -and $a -lt $b) -or (-not $def.Lower -and $a -gt $b))
        [pscustomobject]@{
            Name = $def.Name
            Before = $def.Fmt -f $b
            After = $def.Fmt -f $a
            ChangePct = $pct
            Better = $better
            Same = ($a -eq $b)
        }
    }
}
