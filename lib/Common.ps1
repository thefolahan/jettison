$script:JtTierRank = @{ Safe = 1; Balanced = 2; Aggressive = 3 }

function Write-JtHead {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-JtLine {
    param([string]$Tag, [string]$Text, [string]$Color = 'Gray')
    Write-Host ('  [{0,-7}] ' -f $Tag) -ForegroundColor $Color -NoNewline
    Write-Host $Text
}

function Test-JtAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-JtBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-JtCatalog {
    param([string]$Path, [string]$Level)

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $maxRank = $script:JtTierRank[$Level]
    $catalog = @{ protected = @($raw.protected) }

    foreach ($section in 'apps', 'tweaks', 'services', 'tasks', 'cleanup') {
        $seen = @{}
        $kept = @()
        foreach ($entry in @($raw.$section)) {
            if (-not $entry.id -or -not $script:JtTierRank.ContainsKey([string]$entry.tier)) {
                throw "catalog.json: '$section' entry '$($entry.id)' needs an id and a tier of Safe, Balanced or Aggressive."
            }
            if ($seen.ContainsKey($entry.id)) {
                throw "catalog.json: duplicate id '$($entry.id)' in '$section'."
            }
            $seen[$entry.id] = $true
            if ($script:JtTierRank[[string]$entry.tier] -le $maxRank) { $kept += $entry }
        }
        $catalog[$section] = $kept
    }
    return $catalog
}

function Save-JtJournal {
    param([string]$StateDir, $Journal)
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir | Out-Null
    }
    $path = Join-Path $StateDir ('journal-{0}.json' -f $Journal.Id)
    $Journal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-JtLatestJournal {
    param([string]$StateDir)
    if (-not (Test-Path -LiteralPath $StateDir)) { return $null }
    $file = Get-ChildItem -LiteralPath $StateDir -Filter 'journal-*.json' |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    $journal = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $journal | Add-Member -NotePropertyName File -NotePropertyValue $file.FullName -Force
    return $journal
}
