# Manual Retention Scripts

These scripts provide manual control over build drop retention and cleanup for DFS-based build infrastructure. The process is split into two phases: discovery and deletion. Since we are only processing builds that are older than 90 days, you can run the discovery phase once and run the deletion phase over and over until the drops are removed. The deletion phase will save progress, so you can kill the process if needed and pick up again later.

## Overview

Retention runs in two phases:

1. **Phase 1 — Discovery (`Get-Builds.ps1` or `Get-BuildsForBranch.ps1`)**: Scans a file server's drop shares (or DFS branch paths) and writes a JSON cache file listing every build along with its creation date. This file acts as the work queue for the deletion phase.
2. **Phase 2 — Deletion (`Remove-OldBuilds.ps1`)**: Reads the JSON cache produced in Phase 1, filters out builds younger than the retention threshold and any preserved builds, then submits DSS `buildsharedeletion` operations for the remainder, throttling concurrency and persisting state back to the cache file as work completes.

This two-phase design lets you inspect (and optionally edit) the candidate build list before committing to any deletions. It also lets you avoid re-scanning the file server (the costly phase) since the newly added drops would not be considered for retention and any deleted drops would be a no-op if re-deleted.

If your discovery source is DFS backup XMLs (instead of live share scanning), use `Get-BuildsFromDfsBackup.ps1` first to generate compatible `BuildsCache_*.json` files.

Typical use cases:

- A file server is running low on disk space
- Manual intervention is required beyond automated retention policies

## Prerequisites

### 1. Elevate Access Permissions

You must elevate into the appropriate file server access silo before running the deletion phase. Without this access, DSS operations will fail.

### 2. DFSN Module (only when unlinking DFS links)

If you use `Remove-OldBuilds.ps1 -UnlinkDfsLink`, ensure the PowerShell DFSN cmdlets are available (specifically `Remove-DfsnFolder`) and you have permission to modify DFS namespace links.

---

## Phase 1: Discover Builds (`Get-Builds.ps1`)

Scans the specified file server and writes a `BuildsCache_<servername>.json` file next to the script.

### Usage

```powershell
.\Get-Builds.ps1 -FileServer "FILESERVER01"
```

```powershell
# Scan multiple shares and filter to a specific branch prefix
.\Get-Builds.ps1 -FileServer "FILESERVER01" -DropShareNames "Drops","Drops2" -BranchNameFilter "git_MyProject_*"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `FileServer` | Yes | — | The file server to scan. A short name (e.g. `FILESERVER01`) is automatically expanded to a FQDN. |
| `BranchNameFilter` | No | `git_*` | Wildcard filter applied to branch folder names. Use `*` for all branches. |
| `DropShareNames` | No | `@("Drops")` | One or more share names to scan on the file server (e.g. `"Drops"`, `"Drops2"`). |

### Output

The script writes `BuildsCache_<servername>.json` in the same directory as the script. Each entry contains:

```json
{
  "DfsFolderName": "git_myrepo_main",
  "BuildNumber":   "132.879.5057.264",
  "CreationTime":  "2025-09-01T03:14:00",
  "State":         "NotStarted"
}
```

If the cache file already exists, the script will prompt before overwriting it.

---

## Phase 1 (Alternative): Discover Builds by DFS Branch Path (`Get-BuildsForBranch.ps1`)

Scans one or more DFS branch paths and writes a `BuildsCache_<branchname>.json` file per branch. This script resolves DFS namespace paths to the actual file server drop paths using `Get-DfsnFolderTarget`, then enumerates builds from the resolved location.

Use this instead of `Get-Builds.ps1` when you have a DFS path for a specific branch rather than direct file server access.

### Usage

```powershell
# Scan a single branch
.\Get-BuildsForBranch.ps1 -BranchPaths "\\DFSSERVER01\builds\branches\git_myrepo_main"
```

```powershell
# Scan multiple branches
.\Get-BuildsForBranch.ps1 -BranchPaths @(
    "\\DFSSERVER01\builds\branches\git_myrepo_main",
    "\\DFSSERVER01\builds\branches\git_myrepo_release"
)
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `BranchPaths` | Yes | — | One or more DFS branch paths to scan. Each path should point to a branch folder containing build number subfolders. |

### DFS Resolution

The script splits each path into a DFS namespace parent path and a branch name:

- Input: `\\DFSSERVER01\builds\branches\git_myrepo_main`
- DFS namespace path: `\\DFSSERVER01\builds\branches`
- Branch name: `git_myrepo_main`

It calls `Get-DfsnFolderTarget` on the namespace path to resolve the actual file server target (e.g. `\\FILESERVER01\Drops`), then enumerates builds from `\\FILESERVER01\Drops\git_myrepo_main`. DFS resolutions are cached so multiple branches sharing the same namespace are resolved only once.

If multiple online DFS targets are found, the first one is used and a warning is displayed.

### Output

The script writes `BuildsCache_<branchname>.json` (e.g. `BuildsCache_git_myrepo_main.json`) in the same directory as the script. The JSON format is identical to `Get-Builds.ps1` output:

```json
{
  "DfsFolderName": "git_myrepo_main",
  "BuildNumber":   "132.879.5057.264",
  "CreationTime":  "2025-09-01T03:14:00",
  "State":         "NotStarted"
}
```

If a cache file already exists, the script will prompt before overwriting it.

---

## Phase 2: Delete Old Builds (`Remove-OldBuilds.ps1`)

Reads the `BuildsCache_<servername>.json` produced by Phase 1 and submits DSS deletion operations for builds that are older than the retention threshold.

When `-UnlinkDfsLink` is specified, the script also removes each build's DFS namespace link after the build deletion is marked complete. This requires `DfsLinkPath` in the cache JSON.

### Usage

```powershell
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01"
```

```powershell
# Preview what would be deleted without making any changes
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01" -WhatIf
```

```powershell
# Increase concurrency and use a named run subfolder (allows re-deleting builds if there was an existing DSS action for the same build)
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01" -MaxConcurrentDeletions 8 -UniqueSubFolderName "cleanup-2026-02"
```

```powershell
# Delete old builds and unlink DFS links (requires DfsLinkPath in cache JSON)
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01" -UnlinkDfsLink
```

```powershell
# Write all console output to a specific transcript log file
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01" -LogFilePath "C:\temp\Remove-OldBuilds.log"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `FileServer` | Yes | — | The file server to delete builds from. Must match the name used in Phase 1. |
| `MaxConcurrentDeletions` | No | `5` | Maximum number of in-flight DSS deletions at one time. |
| `DeleteOperationName` | No | `manualRetention` | The DSS operation name written into `action.json`. |
| `UniqueSubFolderName` | No | — | Subfolder appended to the DSS operation path (`\\server\DSS\deleteOperation\branch\build\<here>`). Allows safe re-runs of previously failed operations. |
| `PathToBuildsToPreserveCsv` | No | `\\FILESERVER01\Backups\PreservedBuilds.csv` | Path to the CSV file listing builds that must not be deleted. |
| `SkipStatusCheck` | No | `$false` | Skip the DSS status check before submitting a new deletion. Speeds up submissions but may cause errors if a deletion was already requested. |
| `UnlinkDfsLink` | No | `$false` | After DSS deletion completes, also remove the DFS namespace link from `DfsLinkPath` in the cache JSON. |
| `LogFilePath` | No | `logs\Remove-OldBuilds_<timestamp>.log` | Transcript output path. If omitted, a timestamped log is created under a `logs` folder next to `Remove-OldBuilds.ps1`. |
| `RetentionPolicyAgeInDays` | No | `90` | Builds younger than this threshold (in days) are skipped. |
| `SleepBetweenStatusChecksInSeconds` | No | `15` | How long to wait between polling DSS for status updates. |
| `WhatIf` | No | — | Standard PowerShell common parameter. Shows what would be submitted without writing any DSS action files. |

### How It Works

1. Loads the `BuildsCache_<servername>.json` from the same directory as the script.
2. Loads the preserved builds CSV and filters out any matching entries.
3. Filters out builds younger than `RetentionPolicyAgeInDays`.
4. Enters a processing loop:
   - Starts new DSS deletions up to `MaxConcurrentDeletions` at a time.
   - Polls the status of in-progress deletions via DSS sentinel files (presence of .lock, .success, etc.).
  - Optionally removes DFS links using `Remove-DfsnFolder` when `-UnlinkDfsLink` is enabled and `DfsLinkPath` is present.
  - Updates each build's `State` field in the cache file as work completes, and when unlink mode is enabled, also persists `DfsUnlinkState`.
5. Exits when all builds have been processed (or skipped).

State is persisted back to the JSON cache after each iteration, so the script can be safely interrupted and restarted. The last batch might have stale states, but the script should detect based on the DSS folder contents what the state should be.

When `-UnlinkDfsLink` is used, `DfsUnlinkState` enables resumable unlink tracking:

- `NotStarted`: unlink not yet attempted.
- `Completed`: unlink succeeded.
- `Failed`: unlink failed and will be retried on next run with `-UnlinkDfsLink`.
- `MissingPath`: `DfsLinkPath` was missing in cache JSON, so unlink was skipped.

### WhatIf Mode

Pass `-WhatIf` to preview all operations without writing any DSS `action.json` files or modifying the cache. If `-UnlinkDfsLink` is also set, DFS unlink operations are also previewed (logged as "would remove") and not executed:

```powershell
.\Remove-OldBuilds.ps1 -FileServer "FILESERVER01" -WhatIf
```

---

## Build Preservation

`Remove-OldBuilds.ps1` checks each build against a preservation CSV before submitting a deletion. Builds that appear in the CSV and whose preservation window has not expired are silently skipped.

The CSV is expected to have the following columns: `QueueDateTime`, `BranchName`, `BuildNumber`, `PreserveForDays`.

---

## DSS Integration

Deletions are submitted via the Drops Sync Service (DSS) `buildsharedeletion` action. The scripts interact with DSS purely through UNC share sentinel files — no DSS client binary is required.

**DSS sentinel file protocol:**

| File present | Status |
|---|---|
| `action.json` | Queued — submitted, not yet picked up |
| `action.json.processed` (no result file) | Stalled — picked up but no result written |
| `.lock` | InProgress |
| `.success` | Completed / Succeeded |
| `.failure` | Completed / Failed |
| None of the above | NotSubmitted |

Supporting modules:

- `DSSHelpers.psm1` — DSS status queries (`Get-DSSOperationStatus`), deletion submission (`Remove-DSSBuild`), file server hold management
- `Retry-Helper.psm1` — resilient `Get-Content` and `Get-ChildItem` wrappers for transient network failures

---

## Error Handling

The deletion script continues processing remaining builds if individual operations fail. A warning is printed for any build that ends up in an unexpected or stalled state.

### Exit Codes

Exist codes are not used in this script.

---

## Troubleshooting

### "Access Denied" Errors

- Ensure you have elevated your access to the appropriate file server silo before running Phase 2.
- Verify you have read access to the drop shares for Phase 1.

### DSS Operations Not Progressing

- Check that DSS services are running on the target server.
- Verify the file server's `\\<server>\DSS\status.json` is being updated (must be < 30 seconds old).
- Look for builds in the cache with `State: Stalled` — these had their `action.json` picked up but no result was written.

### Cache File Not Found

- Ensure Phase 1 (`Get-Builds.ps1`) was run with the same `-FileServer` value used in Phase 2.
- The cache file is placed next to the scripts as `BuildsCache_<servername>.json`. The name is normalized, so using FQDN or not is ok.

### No Builds Deleted (All Skipped)

- Confirm that builds are older than `RetentionPolicyAgeInDays` (default: 90 days).
- Check the preserved builds CSV to ensure the builds are not protected.
- Run with `-WhatIf` to see which builds would be selected.

### DFS Unlink Not Happening

- Ensure `-UnlinkDfsLink` was provided to `Remove-OldBuilds.ps1`.
- Ensure each JSON entry includes `DfsLinkPath` (for example from `Get-BuildsFromDfsBackup.ps1`).
- Ensure DFSN cmdlets are available (`Remove-DfsnFolder`) and your account has namespace modification rights.
- Re-run `Remove-OldBuilds.ps1 -UnlinkDfsLink` to retry entries with `DfsUnlinkState: Failed`.

### Logs

- `Remove-OldBuilds.ps1` writes a transcript log for each run.
- Default location: `logs\Remove-OldBuilds_<timestamp>.log` next to `Remove-OldBuilds.ps1`.
- Override location with `-LogFilePath` (for example: `-LogFilePath "C:\temp\Remove-OldBuilds.log"`).
- If no log file is created, verify write access to the target folder and that the script reached startup (before any early exit).

---

## Advanced Topics

### File Server Load Management

`Remove-OldBuilds.ps1` throttles concurrent DSS operations to protect file servers, but only from its own script. It will not check for other scripts triggering deletes on the same file server. Avoid having multiple users cleaning file servers at the same time.

### Retry Logic

All network I/O uses `Retry-Helper.psm1`:

- `Get-ContentWithRetry` and `Get-ChildItemWithRetry` retry on transient failures without using `Test-Path`.
- Default: 5 retries with 2-second delays.
- Critical operations use up to 8 retries with 15-second delays.

### Resuming an Interrupted Run

Because `Remove-OldBuilds.ps1` persists state to the JSON cache after each iteration, you can safely stop and restart it. Builds already in `Completed` state will not be resubmitted (unless `-SkipStatusCheck` is set).

---

## Remove Inactive DFS Targets (`Remove-InactiveDfsTargets.ps1`)

Validates and removes inactive or unreachable DFS folder targets from one or more DFS servers. After removing dead targets, if a DFS folder link has zero remaining targets, the empty link is also removed.

### Usage

```powershell
# Preview what would be removed (dry run)
.\Remove-InactiveDfsTargets.ps1 -DfsServers @("DFSSERVER01") -WhatIf
```

```powershell
# Remove inactive/unreachable targets from multiple servers
.\Remove-InactiveDfsTargets.ps1 -DfsServers @("DFSSERVER01", "DFSSERVER02")
```

```powershell
# Filter to a specific namespace and folder pattern
.\Remove-InactiveDfsTargets.ps1 -DfsServers @("DFSSERVER01") -NamespaceFilter "Builds" -FolderFilter "git_MyProject_*"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `DfsServers` | Yes | — | One or more DFS server names to process. |
| `NamespaceFilter` | No | `*` | Wildcard filter applied to namespace names. |
| `FolderFilter` | No | `*` | Wildcard filter applied to DFS folder link names. |
| `ReachabilityTimeoutSeconds` | No | `5` | Timeout in seconds for UNC path reachability checks. |
| `LogFilePath` | No | `logs\Remove-InactiveDfsTargets_<timestamp>.log` | Transcript output path. |
| `WhatIf` | No | — | Standard PowerShell common parameter. Previews all removals without making changes. |

### How It Works

1. For each DFS server, auto-discovers all hosted namespaces via `Get-DfsnRoot` (filtered by `NamespaceFilter`).
2. Enumerates DFS folder links in each namespace via `Get-DfsnFolder` (filtered by `FolderFilter`).
3. For each folder link, retrieves all targets via `Get-DfsnFolderTarget` and validates each:
   - **DFSN state check** — targets with State other than `Online` are flagged as inactive.
   - **UNC path reachability** — targets whose UNC path is not accessible within the timeout are flagged as unreachable.
4. Removes flagged targets via `Remove-DfsnFolderTarget`.
5. If a folder link has zero remaining targets after removal, the empty link is removed via `Remove-DfsnFolder`.
6. Prints a summary of servers processed, namespaces scanned, links checked, targets validated, targets removed, and links removed.

### Prerequisites

- The DFSN PowerShell module must be available (`Get-DfsnRoot`, `Get-DfsnFolder`, `Get-DfsnFolderTarget`, `Remove-DfsnFolderTarget`, `Remove-DfsnFolder`).
- Your account must have permission to modify DFS namespace links and targets.

---

## Remove Inactive DFS Targets V2 — dfsutil-based (`Remove-InactiveDfsTargetsV2.ps1`)

A faster alternative to `Remove-InactiveDfsTargets.ps1` that uses `dfsutil /export` for bulk namespace enumeration instead of the slow DFSN PowerShell cmdlets (`Get-DfsnRoot`, `Get-DfsnFolder`, `Get-DfsnFolderTarget`). The validation and removal logic is identical.

### When to Use V2 Over the Original

Use V2 when processing large namespaces with thousands of folder links. The original script calls `Get-DfsnFolder` and `Get-DfsnFolderTarget` for each link individually, which can take hours on large namespaces. V2 exports the entire namespace to XML in a single dfsutil call and parses it locally, which is significantly faster.

### Usage

```powershell
# Preview what would be removed (dry run)
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -WhatIf
```

```powershell
# Remove inactive/unreachable targets from the "Builds" namespace (default)
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01", "DFSSERVER02")
```

```powershell
# Target a specific namespace and folder pattern
.\Remove-InactiveDfsTargetsV2.ps1 -DfsServers @("DFSSERVER01") -Namespace "Drops" -FolderFilter "git_MyProject_*"
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `DfsServers` | Yes | — | One or more DFS server names to process. |
| `Namespace` | No | `Builds` | DFS namespace to query on each server (replaces `NamespaceFilter`). |
| `FolderFilter` | No | `*` | Wildcard filter applied to DFS folder link names. |
| `ReachabilityTimeoutSeconds` | No | `5` | Timeout in seconds for UNC path reachability checks. |
| `LogFilePath` | No | `logs\Remove-InactiveDfsTargetsV2_<timestamp>.log` | Transcript output path. |
| `WhatIf` | No | — | Standard PowerShell common parameter. Previews all removals without making changes. |

### How It Works

1. For each DFS server, exports the namespace to XML via `dfsutil /root:"\\Server\Namespace" /export:file.xml`.
2. Parses the exported XML to extract all folder links and their targets in one pass (filtered by `FolderFilter`).
3. Validates each target:
   - **State check** — the dfsutil XML `State` attribute is mapped to Online/Offline. Targets not in Online state (State ≠ 2) are flagged.
   - **UNC path reachability** — targets whose UNC path is not accessible within the timeout are flagged as unreachable.
4. Removes flagged targets via `Remove-DfsnFolderTarget`.
5. If a folder link has zero remaining targets after removal, the empty link is removed via `Remove-DfsnFolder`.
6. Cleans up temporary XML files and prints a summary.

### Prerequisites

- `dfsutil.exe` must be available (typically at `%SystemRoot%\system32\dfsutil.exe`). Override with the `DFS_UTIL` environment variable.
- The DFSN PowerShell module must be available for removal cmdlets (`Remove-DfsnFolderTarget`, `Remove-DfsnFolder`).
- Your account must have permission to modify DFS namespace links and targets.

### Differences from the Original

| Aspect | Original (`Remove-InactiveDfsTargets.ps1`) | V2 (`Remove-InactiveDfsTargetsV2.ps1`) |
|---|---|---|
| Namespace discovery | Auto-discovers via `Get-DfsnRoot` + `NamespaceFilter` | Explicit `Namespace` parameter |
| Link/target enumeration | Per-link DFSN cmdlets (slow) | Bulk dfsutil XML export (fast) |
| State source | DFSN cmdlet `State` property (string) | dfsutil XML `State` attribute (numeric, mapped) |
| Additional dependency | DFSN module only | DFSN module + `dfsutil.exe` |

---

## Notes

- Builds younger than `RetentionPolicyAgeInDays` are always skipped; there is no override for this in normal usage.
- The JSON cache produced by Phase 1 can be reviewed and manually edited before running Phase 2. You can also provide a branch name filter in `Get-Builds.ps1` to target specific branches for cleanup.
- All network operations use retry logic to handle transient failures.
