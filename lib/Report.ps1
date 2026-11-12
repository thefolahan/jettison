# Writes a self-contained HTML report (no external assets) and returns its path.

function ConvertTo-JtHtml {
    param($Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Get-JtRingHtml {
    param([string]$Caption, $Score)
    $deg = [math]::Round(3.6 * $Score)
    return ('<div class="ring-wrap"><div class="ring" style="background:conic-gradient(var(--accent) {0}deg, var(--track) 0)">' +
        '<div class="ring-in">{1}%</div></div><div class="cap">{2}</div></div>') -f $deg, $Score, (ConvertTo-JtHtml $Caption)
}

function Write-JtReport {
    param(
        [string]$StateDir, [string]$Mode, [string]$Level,
        $ScoreBefore, $ScoreAfter, $MetricRows, $Plan, $Cleanup, [string[]]$Notes
    )

    $css = @'
:root{--bg:#0e1116;--card:#171b22;--line:#262c36;--text:#e6e9ee;--dim:#8b94a3;--accent:#3ddc97;--track:#262c36;--bad:#ff6b6b;--warn:#f4b942}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:960px;margin:0 auto;padding:32px 16px 64px}
h1{margin:0 0 4px;font-size:28px}h2{margin:36px 0 12px;font-size:18px}
.sub{color:var(--dim)}.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px}
.rings{display:flex;gap:40px;align-items:center;flex-wrap:wrap;margin-top:20px}
.ring-wrap{text-align:center}.ring{width:132px;height:132px;border-radius:50%;display:grid;place-items:center}
.ring-in{width:104px;height:104px;border-radius:50%;background:var(--card);display:grid;place-items:center;font-size:26px;font-weight:600}
.cap{margin-top:8px;color:var(--dim)}.arrow{font-size:28px;color:var(--dim)}
.tablebox{overflow-x:auto}table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:500;font-size:13px}td.num{font-variant-numeric:tabular-nums}
.good{color:var(--accent)}.bad{color:var(--bad)}.dim{color:var(--dim)}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);color:var(--dim)}
.pill.Applied,.pill.Optimized{color:var(--accent);border-color:var(--accent)}
.pill.Failed{color:var(--bad);border-color:var(--bad)}.pill.Pending{color:var(--warn);border-color:var(--warn)}
ul{margin:8px 0 0;padding-left:20px;color:var(--dim)}
'@

    $html = New-Object System.Text.StringBuilder
    [void]$html.Append('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    [void]$html.Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$html.Append("<title>Jettison report</title><style>$css</style></head><body><main>")
    [void]$html.Append('<h1>Jettison report</h1>')
    [void]$html.Append(('<div class="sub">{0} &middot; {1} mode &middot; {2} level &middot; {3}</div>' -f
            (ConvertTo-JtHtml $env:COMPUTERNAME), $Mode, $Level, (Get-Date).ToString('yyyy-MM-dd HH:mm')))

    [void]$html.Append('<div class="card rings">')
    if ($null -ne $ScoreAfter) {
        [void]$html.Append((Get-JtRingHtml 'Before' $ScoreBefore))
        [void]$html.Append('<div class="arrow">&rarr;</div>')
        [void]$html.Append((Get-JtRingHtml 'After' $ScoreAfter))
    }
    else {
        [void]$html.Append((Get-JtRingHtml 'Current score' $ScoreBefore))
    }
    [void]$html.Append('<div class="sub" style="max-width:380px">The score is the share of optimizations that apply to this PC and are done. Items that were never present are not counted.</div></div>')

    if ($Notes) {
        [void]$html.Append('<ul>')
        foreach ($note in $Notes) { [void]$html.Append('<li>' + (ConvertTo-JtHtml $note) + '</li>') }
        [void]$html.Append('</ul>')
    }

    if ($MetricRows) {
        [void]$html.Append('<h2>Measured before and after</h2><div class="card tablebox"><table><tr><th>Metric</th><th>Before</th><th>After</th><th>Change</th></tr>')
        foreach ($row in $MetricRows) {
            if ($row.Same) { $class = 'dim' } elseif ($row.Better) { $class = 'good' } else { $class = 'bad' }
            [void]$html.Append(('<tr><td>{0}</td><td class="num">{1}</td><td class="num">{2}</td><td class="num {3}">{4:+0.0;-0.0;0.0}%</td></tr>' -f
                    (ConvertTo-JtHtml $row.Name), $row.Before, $row.After, $class, $row.ChangePct))
        }
        [void]$html.Append('</table></div>')
    }

    if ($Cleanup) {
        if (@($Cleanup)[0].Applied) { $verb = 'Freed' } else { $verb = 'Reclaimable' }
        $total = ($Cleanup | Measure-Object Bytes -Sum).Sum
        [void]$html.Append(('<h2>Disk cleanup &middot; {0} {1}</h2><div class="card tablebox"><table><tr><th>Target</th><th>Files</th><th>{0}</th></tr>' -f $verb, (Format-JtBytes $total)))
        foreach ($row in $Cleanup) {
            [void]$html.Append(('<tr><td>{0}</td><td class="num">{1:N0}</td><td class="num">{2}</td></tr>' -f
                    (ConvertTo-JtHtml $row.Label), $row.Files, (Format-JtBytes $row.Bytes)))
        }
        [void]$html.Append('</table></div>')
    }

    foreach ($kind in 'App', 'Tweak', 'Service', 'Task') {
        $rows = @($Plan | Where-Object { $_.Kind -eq $kind -and $_.State -ne 'Absent' })
        if ($rows.Count -eq 0) { continue }
        [void]$html.Append(('<h2>{0}s</h2><div class="card tablebox"><table><tr><th>Item</th><th>Level</th><th>Status</th><th>Detail</th></tr>' -f $kind))
        foreach ($row in $rows) {
            if ($row.Result) { $status = $row.Result } else { $status = $row.State }
            if ($row.Error) { $detail = $row.Error } else { $detail = $row.Detail }
            [void]$html.Append(('<tr><td>{0}</td><td class="dim">{1}</td><td><span class="pill {2}">{2}</span></td><td class="dim">{3}</td></tr>' -f
                    (ConvertTo-JtHtml $row.Label), $row.Tier, $status, (ConvertTo-JtHtml $detail)))
        }
        [void]$html.Append('</table></div>')
    }

    [void]$html.Append('</main></body></html>')

    $dir = Join-Path $StateDir 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('jettison-{0}-{1}.html' -f $Mode.ToLower(), (Get-Date).ToString('yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $path -Value $html.ToString() -Encoding UTF8
    return $path
}
