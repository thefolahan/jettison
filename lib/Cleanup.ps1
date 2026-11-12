# Disk cleanup. Only files older than the catalog's minAgeHours are touched, so anything a
# running installer or app wrote recently is left alone. Deleted files are not recoverable.

function Get-JtCleanupFiles {
    param($Entry)
    $root = [Environment]::ExpandEnvironmentVariables($Entry.path)
    # Some system folders cannot even be probed without elevation; treat those as empty.
    if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) { return @() }
    $cutoff = (Get-Date).AddHours(-[double]$Entry.minAgeHours)
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })
}

# Returns one record per cleanup target. With -Apply the files are deleted and Bytes is what
# was actually freed; without it Bytes is what could be freed.
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
                catch { }   # in use or access denied: skip it
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
