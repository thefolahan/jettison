function Get-JtCleanupFiles {
    param($Entry)
    $root = [Environment]::ExpandEnvironmentVariables($Entry.path)

    if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) { return @() }
    $cutoff = (Get-Date).AddHours(-[double]$Entry.minAgeHours)
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })
}

function Invoke-JtCleanup {
    param($Catalog, [switch]$Apply)
    foreach ($entry in $Catalog.cleanup) {
        $restart = $false
        if ($Apply -and $entry.stopService) {
            $svc = Get-Service -Name $entry.stopService -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $entry.stopService -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                $restart = $true
            }
        }

        $files = Get-JtCleanupFiles -Entry $entry
        $bytes = 0
        $count = 0
        foreach ($file in $files) {
            if ($Apply) {
                try {
                    $size = $file.Length
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $bytes += $size
                    $count++
                }
                catch { }
            }
            else {
                $bytes += $file.Length
                $count++
            }
        }

        if ($restart) { Start-Service -Name $entry.stopService -ErrorAction SilentlyContinue }

        [pscustomobject]@{
            Id = $entry.id; Label = $entry.label; Tier = $entry.tier
            Files = $count; Bytes = $bytes; Applied = [bool]$Apply
        }
    }
}
