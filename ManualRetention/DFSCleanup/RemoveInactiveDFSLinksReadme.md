# Remove-InactiveDfsTargetsV2 — Usage & Design

## Purpose

`Remove-InactiveDfsTargetsV2.ps1` validates and cleans up DFS folder targets that are inactive
or unreachable. It uses `dfsutil` for fast bulk namespace export (replacing slow DFSN cmdlet
enumeration) and processes all links in parallel for maximum throughput.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell 7+** | Required for `ForEach-Object -Parallel`. The script exits with a clear error on older versions. |
| **dfsutil.exe** | Typically at `%SystemRoot%\system32\dfsutil.exe`. Used for bulk namespace XML export. |
| **DFSN module** | The DFS Namespaces PowerShell module must be installed (`Remove-DfsnFolderTarget`, `Remove-DfsnFolder`). |
| **Permissions** | The executing account must have write access to the DFS namespace being cleaned. |

---

## Quick Start

```powershell
# 1. Dry run — preview what would be removed (no changes made)
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -WhatIf

# 2. Execute the cleanup
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01")

# 3. Execute with higher parallelism and cached exports
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -ExportDirectory "C:\DfsExports" -ThrottleLimit 32

# 4. Process multiple servers, filter to specific branches
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01","DFSSERVER02") -FolderFilter "git_MyProject_*"
```

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-DfsServers` | Yes | — | One or more DFS server names to process. |
| `-Namespace` | No | `Builds` | DFS namespace to query on each server. |
| `-FolderFilter` | No | `*` | Wildcard filter applied to DFS folder link names. |
| `-ReachabilityTimeoutSeconds` | No | `30` | Timeout in seconds for each UNC path reachability check. |
| `-ThrottleLimit` | No | `16` | Maximum number of concurrent parallel link processing operations. |
| `-ExportDirectory` | No | `%TEMP%\...` | Directory for storing exported XML files. Reuses existing exports unless `-ForceExport` is set. |
| `-ForceExport` | No | `$false` | Forces re-export of namespace XML even if the file already exists. |
| `-ProgressFile` | No | `logs\progress_<Namespace>.json` (or `_whatif.json` in WhatIf mode) | JSON progress file for resumable runs. WhatIf runs use a separate file by default. |
| `-ResetProgress` | No | `$false` | Deletes the progress file before starting, forcing a full re-scan. |
| `-LogFilePath` | No | `logs\Remove-InactiveDfsTargetsV2_<timestamp>.log` | Path for the transcript log. |
| `-WhatIf` | No | `$false` | Preview mode — performs the full scan (state + reachability) and writes results to both the console and a removals CSV report (with `Status=WhatIf` entries) without making any changes. Uses a separate progress checkpoint file (suffixed with `_whatif`) so WhatIf runs do not interfere with real runs. |

---

## High-Level Design

### Processing Pipeline

The script executes in 5 sequential steps, with parallelism within steps 2, 3, and 5:

```
┌──────────────────────────────────────────────────────────────┐
│  Step 1/5: LOAD DFSN MODULE                                  │
│     Import-Module DFSN — fatal error if not available        │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  Step 2/5: PRE-FLIGHT CONNECTIVITY (parallel across servers) │
│     For each server (in parallel):                           │
│       1. Test-Connection — verify network reachability       │
│       2. Test-Path — verify namespace share is accessible    │
│       3. Get-ChildItem — verify share returns content        │
│     Unreachable servers are skipped with a warning.          │
│     If ALL servers fail, the script exits early.             │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  Step 3/5: PARALLEL NAMESPACE EXPORT                         │
│     All reachable servers export in parallel via dfsutil.    │
│     (Reuses cached exports if ExportDirectory is specified)  │
│     Servers whose exports fail are skipped with a warning.   │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  Step 4/5: PARSE & BUILD WORK-ITEM LIST                      │
│     For each exported XML (sequential):                      │
│       Load XML → extract <Link> elements → build unified     │
│       list of (DfsServer, Link) work items across all        │
│       servers.                                               │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  Step 5/5: PARALLEL LINK PROCESSING                          │
│     Single ForEach-Object -Parallel pipeline across ALL      │
│     servers (up to ThrottleLimit concurrent workers):        │
│                                                              │
│     ┌─ Apply FolderFilter ─────────────────────────┐         │
│     │  Skip links that don't match the wildcard    │         │
│     └──────────────────┬───────────────────────────┘         │
│                        │                                     │
│     ┌─ For each target in the link ────────────────┐         │
│     │                                              │         │
│     │  Check 1: DFSN State from XML                │         │
│     │    State ≠ 2 (Online) → flag as Inactive     │         │
│     │                                              │         │
│     │  Check 2: UNC Reachability (if state is OK)  │         │
│     │    Test-Path with timeout → flag as          │         │
│     │    Unreachable if not accessible             │         │
│     └──────────────────┬───────────────────────────┘         │
│                        │                                     │
│     ┌─ Remove flagged targets ─────────────────────┐         │
│     │  Remove-DfsnFolderTarget for each flagged    │         │
│     │  target; record outcome in ConcurrentBag     │         │
│     │                                              │         │
│     │  If ALL targets removed → also remove the    │         │
│     │  empty link via Remove-DfsnFolder            │         │
│     └──────────────────────────────────────────────┘         │
│                                                              │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│  POST-PROCESSING                                             │
│  Batch-save progress file                                    │
│  Write removals report CSV (batch from ConcurrentBag)        │
│  Print summary (with total elapsed time)                     │
└──────────────────────────────────────────────────────────────┘
```

### Why dfsutil Instead of DFSN Cmdlets?

The DFSN PowerShell cmdlets (`Get-DfsnRoot`, `Get-DfsnFolder`, `Get-DfsnFolderTarget`)
enumerate the namespace one link at a time over the network, which is extremely slow for large
namespaces (minutes to hours). `dfsutil /export` dumps the entire namespace to an XML file in
seconds, making the discovery phase orders of magnitude faster.

### Parallel Architecture

All links from all servers are processed in a single `ForEach-Object -Parallel` pipeline
(PS 7+), rather than per-server. This allows the throttle limit to be applied globally,
giving better utilization when servers have uneven numbers of links. Thread safety is
achieved through:

| Collection | Type | Purpose |
|---|---|---|
| `$sharedCounters` | `[hashtable]::Synchronized` | Counter updates (LinksChecked, TargetsValidated, TargetsRemoved, Errors, etc.) |
| `$newCompletedLinks` | `ConcurrentDictionary<string,string>` | Tracks newly completed links for progress file merge |
| `$removalRecords` | `ConcurrentBag<PSObject>` | Collects removal report entries for batch CSV write |

A background `Start-ThreadJob` monitors the shared counters every 2 seconds, writing an
in-place progress bar to the console via `[Console]::Write` with carriage return (because
`Write-Progress` inside a `ThreadJob` buffers to the job's progress stream and does not
render on the host console). The monitor also periodically flushes the progress file
(every 30 links).

### Target Validation Logic

Each target undergoes two checks, in order:

1. **DFSN State** (from XML, instant) — The target's `State` attribute is checked:
   - `2` = Online → passes
   - `6` = Offline (active + offline bits) → flagged
   - Other values → flagged as Inactive

2. **UNC Reachability** (network I/O, up to timeout) — Only checked if the state is Online.
   Uses `Test-Path` wrapped in a `[PowerShell]::Create()` runspace with a configurable timeout
   to prevent hangs on unresponsive servers.

A target is flagged for removal if **either** check fails. The state check is done first
as an optimization — if the target is already known inactive from the XML, the slow
reachability check is skipped entirely.

### Progress Tracking & Restartability

The script is designed to be safely interrupted and restarted:

1. **Progress file** — A JSON file tracks every completed link (keyed by `SERVER::linkName`).
2. **On restart** — The script loads the progress file, skips already-completed links, and
   processes only the remaining ones.
3. **Periodic flush** — During parallel execution, the background monitor flushes progress to
   disk every 30 links, limiting data loss if the script is killed mid-run.
4. **Final save** — After the parallel pipeline finishes, a final batch write ensures every
   completed link is persisted.
5. **`-ResetProgress`** — Deletes the progress file to force a clean re-scan.

### Export Caching

When `-ExportDirectory` is specified:
- The dfsutil XML export is saved to the directory and reused on subsequent runs
- Use `-ForceExport` to force a fresh export even if the file exists
- When omitted, a temporary directory under `%TEMP%` is used (auto-cleaned after the run)

---

## Output Files

| File | Location | Description |
|---|---|---|
| **Transcript log** | `logs\Remove-InactiveDfsTargetsV2_<timestamp>.log` | Full console transcript of the run. |
| **Removals report** | `logs\removals_<timestamp>.csv` | CSV of all targets removed (or that would be removed in WhatIf mode). Columns: `Timestamp`, `DfsServer`, `LinkPath`, `TargetPath`, `Reason`, `Status`. |
| **Progress file** | `logs\progress_<Namespace>.json` (or `progress_<Namespace>_whatif.json` in WhatIf mode) | JSON checkpoint file for resumable runs. WhatIf runs use a separate file so they do not interfere with real runs. |
| **Namespace exports** | `<ExportDirectory>\<server>\<Namespace>.xml` | dfsutil XML exports (only when `-ExportDirectory` specified). |

### Removals CSV Status Values

| Status | Meaning |
|---|---|
| `Removed` | Target or empty link was successfully removed from the DFS namespace. |
| `WhatIf` | Target or empty link would be removed (seen in `-WhatIf` mode). |
| `Failed: <message>` | Target or empty link removal was attempted but failed (see error message). |

### Removals CSV Reason Values

| Reason | Meaning |
|---|---|
| `Inactive (State: Offline)` | Target's DFSN state is Offline (bit 0x4 set). |
| `Inactive (State: Inactive)` | Target's DFSN state has the Active bit (0x2) cleared. |
| `Unreachable (path not accessible)` | Target is marked Online in DFS but the UNC path could not be reached within the timeout. |
| `All N target(s) removed — empty link cleanup` | Every target in the link was removed (or would be removed in WhatIf mode), so the empty link itself is also removed. The `TargetPath` column shows `(empty link)` for these rows. |

---

## Example Workflows

### Standard Cleanup

```powershell
# Dry run first
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01") `
    -WhatIf

# Review removals report
Import-Csv ".\logs\removals_20260328_100000.csv" |
    Group-Object Reason | Select-Object Name, Count

# Execute
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01")
```

### Targeted Branch Cleanup

```powershell
# Only process links matching a specific branch pattern
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01") `
    -FolderFilter "git_MyProject_*" `
    -WhatIf
```

### Multi-Server with Cached Exports

```powershell
# First run: exports saved to C:\DfsExports
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01","DFSSERVER02") `
    -ExportDirectory "C:\DfsExports" `
    -WhatIf

# Second run: reuses exports (fast), only re-checks links
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01","DFSSERVER02") `
    -ExportDirectory "C:\DfsExports"

# Force fresh exports
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01","DFSSERVER02") `
    -ExportDirectory "C:\DfsExports" `
    -ForceExport
```

### Resume After Interruption

```powershell
# Simply re-run — completed links are skipped automatically
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01")

# Force full re-scan (discard all progress)
.\Remove-InactiveDfsTargetsV2.ps1 `
    -DfsServers @("DFSSERVER01") `
    -ResetProgress
```

---

## Tuning Guide

| Scenario | Recommendation |
|---|---|
| Large namespace (10,000+ links) | Increase `-ThrottleLimit` to 32–64; use `-ExportDirectory` to cache exports |
| Slow or congested network | Decrease `-ThrottleLimit` to 8; increase `-ReachabilityTimeoutSeconds` to 60 |
| Quick re-check after partial run | Don't set `-ResetProgress`; the script skips already-processed links |
| Auditing before cleanup | Always run with `-WhatIf` first, then review the removals CSV |
| Different namespace | Pass `-Namespace "Drops"` (default is `Builds`) |

---

## Relationship to Other Scripts

| Script | Role |
|---|---|
| `Remove-InactiveDfsTargetsV2.ps1` | **This script** — validates and removes inactive/unreachable DFS targets |
| `Remove-InactiveDfsTargets.ps1` | Original (V1) — same logic but uses slow DFSN cmdlet enumeration instead of dfsutil |
| `Repair-DfsTargetsFromCsv.ps1` | **Recovery** — reads the removals CSV from this script and restores targets that are actually reachable (see `RepairRecoveryReadme.md`) |
| `Get-BuildsFromDfsLive.ps1` | Discovery — enumerates builds from DFS namespace using the same dfsutil export approach |
