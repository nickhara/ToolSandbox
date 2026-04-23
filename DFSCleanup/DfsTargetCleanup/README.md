# DfsTargetCleanup

A .NET 10 console application that validates and removes inactive or unreachable DFS folder targets. This is a port of the PowerShell script `Remove-InactiveDfsTargetsV2.ps1` to a structured, testable C# application.

## High-Level Design

### Architecture

The application follows a **service-oriented pipeline architecture** with five sequential steps, each encapsulated in a dedicated service class. Shared state is managed through thread-safe collections and atomic counters to support parallel processing.

```
Program.cs (CLI parsing + orchestration + composition root)
    │
    ├── Abstractions (IFileSystem, IProcessRunner, INetworkChecker, IEnvironmentProvider, IDfsnRemovalService)
    │   └── Defaults (DefaultFileSystem, DefaultProcessRunner, DefaultNetworkChecker, DefaultEnvironmentProvider)
    │
    ├── Step 1: DfsnRemovalService.ValidateModule()
    ├── Step 2: PreflightService.RunAsync()          ← INetworkChecker, IFileSystem
    ├── Step 3: DfsExportService.ExportAllAsync()    ← IFileSystem, IProcessRunner, IEnvironmentProvider
    ├── Step 4: XmlParserService.ParseExports()
    └── Step 5: LinkProcessorService.ProcessAsync()  ← IDfsnRemovalService, IFileSystem
                    ├── DfsStateHelper (state validation)
                    ├── ProgressTracker (resume checkpoints)
                    └── ReportWriter (CSV output)
```

### Project Structure

```
DfsTargetCleanup/
├── DfsTargetCleanup.csproj
├── Program.cs                        # Entry point, CLI parsing, composition root
├── README.md
├── Abstractions/
│   ├── IFileSystem.cs                # File/directory operations abstraction
│   ├── IProcessRunner.cs             # External process execution abstraction
│   ├── INetworkChecker.cs            # Network connectivity abstraction
│   ├── IEnvironmentProvider.cs       # Environment variable abstraction
│   ├── IDfsnRemovalService.cs        # DFS removal operations abstraction
│   └── Defaults/
│       ├── DefaultFileSystem.cs      # System.IO delegation
│       ├── DefaultProcessRunner.cs   # System.Diagnostics.Process delegation
│       ├── DefaultNetworkChecker.cs  # System.Net.NetworkInformation.Ping delegation
│       └── DefaultEnvironmentProvider.cs  # System.Environment delegation
├── Models/
│   ├── AppOptions.cs                 # CLI options model
│   ├── DfsWorkItem.cs                # Server + XML link element pair
│   ├── RemovalRecord.cs              # CSV report record
│   ├── ProgressData.cs               # JSON progress file model
│   └── SharedCounters.cs             # Thread-safe atomic counters
├── Services/
│   ├── PreflightService.cs           # Network connectivity & share checks
│   ├── DfsExportService.cs           # dfsutil namespace export
│   ├── XmlParserService.cs           # XML parsing into work items
│   ├── LinkProcessorService.cs       # Parallel link validation & removal
│   ├── DfsnRemovalService.cs         # PowerShell DFSN cmdlet wrapper
│   ├── ProgressTracker.cs            # JSON checkpoint read/write
│   └── ReportWriter.cs               # CSV report generation
└── Helpers/
    ├── RetryHelper.cs                # Configurable retry logic
    ├── ConsoleHelper.cs              # Thread-safe colored console output
    └── DfsStateHelper.cs             # DFS target state mapping

DfsTargetCleanup.Tests/
├── DfsTargetCleanup.Tests.csproj
├── Helpers/
│   ├── DfsStateHelperTests.cs
│   ├── RetryHelperTests.cs
│   └── ConsoleHelperTests.cs
├── Services/
│   ├── XmlParserServiceTests.cs
│   ├── ProgressTrackerTests.cs
│   ├── ReportWriterTests.cs
│   ├── DfsExportServiceTests.cs      # Mocked I/O tests
│   ├── PreflightServiceTests.cs      # Mocked I/O tests
│   └── LinkProcessorServiceTests.cs  # Mocked I/O tests
└── Models/
    └── ModelsTests.cs
```

## Functionality

### 5-Step Pipeline

| Step | Service | Description |
|------|---------|-------------|
| **1** | `DfsnRemovalService` | Validates the DFSN PowerShell module is available (required for target removal) |
| **2** | `PreflightService` | Parallel connectivity checks: ping, share access, content enumeration |
| **3** | `DfsExportService` | Exports DFS namespaces to XML via `dfsutil.exe` (parallel per server) |
| **4** | `XmlParserService` | Parses exported XMLs, builds unified work-item list across all servers |
| **5** | `LinkProcessorService` | Validates targets in parallel, removes inactive/unreachable ones |

### Target Validation

Each DFS folder target is validated with two checks:

1. **DFSN State Check** — Examines the numeric state value from the dfsutil XML export. State `2` (0x2) = Online. Targets with Offline (0x4 bit set) or Inactive (no 0x2 bit) states are flagged for removal.

2. **UNC Path Reachability Check** — For targets that pass the state check, verifies the UNC path is accessible within a configurable timeout. Unreachable targets are flagged for removal.

### Key Features

- **`--what-if` Mode** — Performs full scan and generates removal reports without making any changes. Uses a separate progress file (suffixed `_whatif`) to avoid interfering with real runs.

- **Resumable Runs** — Progress is checkpointed to a JSON file. On restart, previously completed links are skipped. The progress file format is compatible with the original PowerShell script.

- **Parallel Processing** — Uses `Parallel.ForEachAsync` with configurable `--throttle-limit` for concurrent link processing. Pre-flight and export steps also run in parallel across servers.

- **Live Progress Bar** — Background task displays a real-time progress bar with completion percentage, checked/skipped/removed/error counts.

- **Retry Logic** — `RetryHelper` provides configurable retry with transient failure detection for async and sync operations.

- **Transcript Logging** — All console output is tee'd to a timestamped log file via a `TeeTextWriter`.

- **CSV Removals Report** — Every removal action is recorded with timestamp, server, link path, target path, reason, and status.

## Usage

### Prerequisites

- .NET 10 SDK
- `dfsutil.exe` (typically at `%SystemRoot%\system32\dfsutil.exe`)
- DFSN PowerShell module (DFS Namespaces feature)
- Appropriate permissions to modify the DFS namespace

### Build

```bash
dotnet build
```

### Run Tests

```bash
dotnet test
```

### CLI Options

```
Usage:
  DfsTargetCleanup [options]

Options:
  -s, --dfs-servers <dfs-servers> (REQUIRED)  One or more DFS server names to process
  -n, --namespace <namespace>                 DFS namespace to query [default: Builds]
  -f, --folder-filter <folder-filter>         Wildcard filter for link names [default: *]
  -t, --reachability-timeout <timeout>        UNC reachability timeout in seconds [default: 30]
  -e, --export-directory <dir>                Directory for DFS namespace XML exports
      --force-export                          Force re-export even if XML exists
      --progress-file <file>                  JSON progress file for resumable runs
      --reset-progress                        Delete progress file before starting
      --log-file <file>                       Transcript log file path
  -p, --throttle-limit <limit>                Max concurrent parallel operations [default: 16]
      --what-if                               Preview removals without making changes
```

### Examples

**Preview removals (no changes):**
```bash
dotnet run -- --dfs-servers DFSSERVER01 --what-if
```

**Process multiple servers:**
```bash
dotnet run -- --dfs-servers DFSSERVER01 DFSSERVER02 --namespace Builds
```

**Use cached XML exports:**
```bash
dotnet run -- --dfs-servers DFSSERVER01 --export-directory C:\DfsExports
```

**Force re-export and reset progress:**
```bash
dotnet run -- --dfs-servers DFSSERVER01 --export-directory C:\DfsExports --force-export --reset-progress
```

**Filter specific folders with higher parallelism:**
```bash
dotnet run -- --dfs-servers DFSSERVER01 --folder-filter "git_MyProject_*" --throttle-limit 32
```

**Custom namespace and timeout:**
```bash
dotnet run -- --dfs-servers DFSSERVER01 --namespace Drops --reachability-timeout 10
```

### Output Files

All output files are written to a `logs/` directory alongside the executable (or to custom paths via CLI options):

| File | Description |
|------|-------------|
| `DfsTargetCleanup_YYYYMMDD_HHmmss.log` | Full transcript log |
| `removals_YYYYMMDD_HHmmss.csv` | CSV report of all removal actions |
| `progress_<Namespace>.json` | Progress checkpoint for resumable runs |
| `progress_<Namespace>_whatif.json` | Separate progress file for WhatIf runs |
