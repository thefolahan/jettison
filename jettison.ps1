[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Apply', 'Measure', 'Revert')]
    [string]$Mode = 'Analyze',

    [ValidateSet('Safe', 'Balanced', 'Aggressive')]
    [string]$Level = 'Safe',

    [string[]]$Skip = @(),

    [switch]$Yes,
    [switch]$NoRestorePoint,
    [switch]$OpenReport,

    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'Jettison')
)

foreach ($file in 'Common', 'Plan', 'Actions', 'Cleanup', 'Metrics', 'Report') {
    . (Join-Path $PSScriptRoot "lib\$file.ps1")
}

$areas = 'Apps', 'Tweaks', 'Services', 'Tasks', 'Cleanup'
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($area in $Skip) {
    if ($areas -notcontains $area) {
        Write-Host "Unknown -Skip value '$area'. Use any of: $($areas -join ', ')." -ForegroundColor Red
        exit 1
    }
}

$catalogPath = Join-Path $PSScriptRoot 'catalog.json'
$isAdmin = Test-JtAdmin

function Confirm-Jt {
    param([string]$Question)
    if ($Yes) { return $true }
    return ((Read-Host "$Question Type YES to continue") -ceq 'YES')
}

function Show-JtPlan {
    param($Plan)
    foreach ($kind in 'App', 'Tweak', 'Service', 'Task') {
        $rows = @($Plan | Where-Object { $_.Kind -eq $kind -and $_.State -ne 'Absent' })
        if ($rows.Count -eq 0) { continue }
        Write-JtHead "${kind}s"
        foreach ($row in $rows) {
            if ($row.State -eq 'Pending') { Write-JtLine 'pending' "$($row.Label)  ($($row.Tier))" 'Yellow' }
            else { Write-JtLine 'ok' $row.Label 'DarkGray' }
        }
    }
}

function Show-JtCleanup {
    param($Cleanup)
    if (-not $Cleanup) { return }
    if (@($Cleanup)[0].Applied) { $verb = 'freed' } else { $verb = 'found' }
    Write-JtHead 'Disk cleanup'
    foreach ($row in $Cleanup) {
        Write-JtLine $verb ('{0}: {1} in {2:N0} files' -f $row.Label, (Format-JtBytes $row.Bytes), $row.Files) 'Gray'
    }
}

function Show-JtMetricRows {
    param($Rows)
    Write-JtHead 'Measured before and after'
    foreach ($row in $Rows) {
        if ($row.Same) { $color = 'DarkGray' } elseif ($row.Better) { $color = 'Green' } else { $color = 'Red' }
        Write-Host ('  {0,-24} {1,10} -> {2,-10} ' -f $row.Name, $row.Before, $row.After) -NoNewline
        Write-Host ('{0:+0.0;-0.0;0.0}%' -f $row.ChangePct) -ForegroundColor $color
    }
}

function Complete-JtReport {
    param([string]$Path)
    Write-JtHead 'Report'
    Write-Host "  $Path"
    if ($OpenReport) { Start-Process $Path }
}

Write-Host ''
Write-Host "Jettison  |  $Mode  |  level: $Level" -ForegroundColor White

switch ($Mode) {

    'Analyze' {
        if (-not $isAdmin) {
            Write-JtLine 'note' 'Not elevated: only your own Store apps are visible and boot time cannot be read.' 'DarkYellow'
        }
        $catalog = Get-JtCatalog -Path $catalogPath -Level $Level
        $plan = Get-JtPlan -Catalog $catalog -Skip $Skip -IsAdmin $isAdmin
        $score = Get-JtScore -Baseline $plan -Current $plan
        $cleanup = $null
        if ($Skip -notcontains 'Cleanup') { $cleanup = @(Invoke-JtCleanup -Catalog $catalog) }

        Show-JtPlan $plan
        Show-JtCleanup $cleanup

        $pending = @($plan | Where-Object { $_.State -eq 'Pending' }).Count
        Write-JtHead 'Summary'
        Write-Host "  Optimization score: $score%   ($pending changes pending at the $Level level)"
        Write-Host '  Nothing was changed. To apply, run from an elevated PowerShell:'
        Write-Host "    .\jettison.ps1 -Mode Apply -Level $Level" -ForegroundColor Cyan

        $report = Write-JtReport -StateDir $StateDir -Mode $Mode -Level $Level -ScoreBefore $score `
            -Plan (ConvertTo-JtPlanRecord $plan) -Cleanup $cleanup `
            -Notes @('Read-only analysis. Nothing on this PC was changed.')
        Complete-JtReport $report
    }

    'Apply' {
        if (-not $isAdmin) {
            Write-JtLine 'error' 'Apply needs an elevated PowerShell (Run as administrator).' 'Red'
            exit 1
        }
        $catalog = Get-JtCatalog -Path $catalogPath -Level $Level
        $plan = Get-JtPlan -Catalog $catalog -Skip $Skip -IsAdmin $true
        $baseline = ConvertTo-JtPlanRecord $plan
        $scoreBefore = Get-JtScore -Baseline $baseline -Current $baseline

        Show-JtPlan $plan
        $pending = @($plan | Where-Object { $_.State -eq 'Pending' })
        $apps = @($pending | Where-Object { $_.Kind -eq 'App' }).Count
        Write-JtHead 'About to apply'
        Write-Host "  $($pending.Count) changes, including $apps app removals. Registry, service and task changes can be"
        Write-Host '  undone with -Mode Revert. Removed apps and cleaned files cannot.'
        if (-not (Confirm-Jt 'Apply these changes?')) {
            Write-Host '  Cancelled. Nothing was changed.'
            exit 0
        }

        $notes = @()
        if (-not $NoRestorePoint) {
            try {
                Checkpoint-Computer -Description 'Jettison' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
                Write-JtLine 'done' 'System restore point requested' 'Green'
            }
            catch {
                Write-JtLine 'warn' "No restore point: $($_.Exception.Message)" 'Yellow'
                $notes += 'A system restore point could not be created before this run.'
                if (-not (Confirm-Jt 'Continue without a restore point?')) {
                    Write-Host '  Cancelled. Nothing was changed.'
                    exit 0
                }
            }
        }

        $metricsBefore = Get-JtMetrics
        Write-JtHead 'Applying'
        $changes = @(Invoke-JtPlan -Plan $plan)

        $cleanup = $null
        if ($Skip -notcontains 'Cleanup') { $cleanup = @(Invoke-JtCleanup -Catalog $catalog -Apply) }
        Show-JtCleanup $cleanup

        $after = Get-JtPlan -Catalog $catalog -Skip $Skip -IsAdmin $true
        $scoreAfter = Get-JtScore -Baseline $baseline -Current $after
        $metricsAfter = Get-JtMetrics
        $rows = @(Get-JtMetricRows -Before $metricsBefore -After $metricsAfter)
        Show-JtMetricRows $rows

        $journal = @{
            Id            = (Get-Date).ToString('yyyyMMdd-HHmmss')
            Level         = $Level
            Skip          = @($Skip)
            Baseline      = $baseline
            ScoreBefore   = $scoreBefore
            MetricsBefore = $metricsBefore
            Changes       = @($changes)
        }
        $journalPath = Save-JtJournal -StateDir $StateDir -Journal $journal

        $failed = @($plan | Where-Object { $_.Result -eq 'Failed' }).Count
        Write-JtHead 'Summary'
        Write-Host "  Optimization score: $scoreBefore% -> $scoreAfter%"
        if ($failed -gt 0) { Write-Host "  $failed changes failed; see the report." -ForegroundColor Red }
        Write-Host "  Journal: $journalPath"
        Write-Host '  Reboot, then run  .\jettison.ps1 -Mode Measure  for memory, process and boot-time numbers.'

        $notes += 'Memory, process and boot-time figures only settle after a reboot. Run Measure afterwards.'
        $report = Write-JtReport -StateDir $StateDir -Mode $Mode -Level $Level -ScoreBefore $scoreBefore -ScoreAfter $scoreAfter `
            -MetricRows $rows -Plan (ConvertTo-JtPlanRecord $plan) -Cleanup $cleanup -Notes $notes
        Complete-JtReport $report
        if ($failed -gt 0) { exit 1 }
    }

    'Measure' {
        $journal = Get-JtLatestJournal -StateDir $StateDir
        if (-not $journal) {
            Write-JtLine 'error' "No Apply journal found in $StateDir. Run -Mode Apply first." 'Red'
            exit 1
        }
        $catalog = Get-JtCatalog -Path $catalogPath -Level $journal.Level
        $current = Get-JtPlan -Catalog $catalog -Skip @($journal.Skip) -IsAdmin $isAdmin
        $scoreAfter = Get-JtScore -Baseline $journal.Baseline -Current $current
        $rows = @(Get-JtMetricRows -Before $journal.MetricsBefore -After (Get-JtMetrics))

        Show-JtMetricRows $rows
        Write-JtHead 'Summary'
        Write-Host "  Compared with the Apply run $($journal.Id) ($($journal.Level) level)"
        Write-Host "  Optimization score: $($journal.ScoreBefore)% -> $scoreAfter%"

        $report = Write-JtReport -StateDir $StateDir -Mode $Mode -Level $journal.Level -ScoreBefore $journal.ScoreBefore `
            -ScoreAfter $scoreAfter -MetricRows $rows -Plan (ConvertTo-JtPlanRecord $current) `
            -Notes @("Compared with the state recorded before Apply run $($journal.Id).")
        Complete-JtReport $report
    }

    'Revert' {
        if (-not $isAdmin) {
            Write-JtLine 'error' 'Revert needs an elevated PowerShell (Run as administrator).' 'Red'
            exit 1
        }
        $journal = Get-JtLatestJournal -StateDir $StateDir
        if (-not $journal) {
            Write-JtLine 'error' "No Apply journal found in $StateDir. Nothing to revert." 'Red'
            exit 1
        }
        $count = @($journal.Changes | Where-Object { $_.Kind -ne 'App' }).Count
        Write-Host "  Apply run $($journal.Id): $count registry, service and task changes to undo."
        if (-not (Confirm-Jt 'Revert them?')) {
            Write-Host '  Cancelled. Nothing was changed.'
            exit 0
        }

        Write-JtHead 'Reverting'
        $result = Undo-JtChanges -Changes $journal.Changes

        if ($result.Apps.Count -gt 0) {
            Write-JtHead 'Removed apps (reinstall from the Microsoft Store if wanted)'
            foreach ($name in $result.Apps) { Write-Host "  $name" }
        }
        if ($result.Failed -gt 0) {
            Write-Host "  $($result.Failed) changes could not be reverted. The journal was kept: $($journal.File)" -ForegroundColor Red
            exit 1
        }

        Rename-Item -LiteralPath $journal.File -NewName ((Split-Path $journal.File -Leaf) -replace '^journal-', 'reverted-')
        Write-Host '  Done. Reboot for service changes to take full effect.'
    }
}
