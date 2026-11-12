# Jettison

A PowerShell tool that measures a Windows 10/11 PC, removes bloatware, turns off telemetry and
background junk, and then measures again, so the improvement it reports is real rather than a
made-up number. Every change is written to a journal and can be reverted.

```powershell
# 1. See what it would do. Read-only, no admin needed.
.\jettison.ps1

# 2. Apply, from an elevated PowerShell.
.\jettison.ps1 -Mode Apply -Level Balanced

# 3. Reboot, then get the honest before/after numbers.
.\jettison.ps1 -Mode Measure

# Changed your mind?
.\jettison.ps1 -Mode Revert
```

If scripts are blocked, run it as
`powershell -ExecutionPolicy Bypass -File .\jettison.ps1`.

## What it does

| Area | Examples | Revertible |
| --- | --- | --- |
| Apps | Bing apps, Solitaire, Office hub, Candy Crush, Xbox apps | No (reinstall from the Store) |
| Tweaks | Start menu ads, advertising ID, telemetry level, Game DVR | Yes |
| Services | DiagTrack, Retail Demo, Xbox services | Yes |
| Scheduled tasks | Compatibility Appraiser, CEIP | Yes |
| Disk cleanup | Temp files, Windows Update cache | No |

## Levels

- **Safe** (default): ads, telemetry and apps almost nobody uses.
- **Balanced**: adds media apps, Xbox apps and services, Cortana, background apps.
- **Aggressive**: adds Game Bar, Mail, Camera, Search indexing, SysMain, visual effects. Read the
  list from Analyze before applying this one.

Skip whole areas with `-Skip Apps,Cleanup`. Use `-Yes` to skip the confirmation prompts and
`-OpenReport` to open the HTML report when it finishes.

## How the percentage is worked out

The **optimization score** is the share of optimizations that apply to this PC and are done.
Apps, services and tasks that were never on the machine are left out, so a clean install does not
get credit for bloat it never had. A run reports the score before and after.

Alongside that, Jettison records running processes, running services, memory in use, startup
items, installed Store apps, free disk space and the last boot time, and shows the measured change
in each. Memory, process and boot figures only settle after a reboot, which is what `Measure` is
for.

## Safety

- Analyze is the default mode and changes nothing.
- Apply asks for confirmation and requests a system restore point first.
- A protected list in `catalog.json` (Store, Calculator, Photos, Edge, runtime frameworks and
  others) can never be removed, whatever the app list says.
- Cleanup only deletes files older than 24 hours (72 for the update cache).
- Journals and reports are kept in `%LOCALAPPDATA%\Jettison`.

Per-user settings (`HKCU`) are applied to the account that runs the script. If you elevate with a
different administrator account, those tweaks land on that account, not yours.

## Customising

Everything Jettison touches is listed in [`catalog.json`](catalog.json). Add, remove or move
entries between levels there; no code changes are needed.

## Layout

```
jettison.ps1      entry point and the four modes
catalog.json      apps, tweaks, services, tasks, cleanup targets, protected list
lib/Plan.ps1      works out the state of each item and the score
lib/Actions.ps1   applies changes and reverts them from the journal
lib/Cleanup.ps1   disk cleanup
lib/Metrics.ps1   before/after measurements
lib/Report.ps1    HTML report
lib/Common.ps1    console output, catalog loading, journal storage
```

Requires Windows PowerShell 5.1 or later, which ships with Windows 10 and 11.
