# InfrastructureTooling

A collection of infrastructure management and automation tools.

## Tools

### [DFSCleanup](DFSCleanup/)

Validates and removes inactive or unreachable DFS folder targets using `dfsutil` for fast namespace enumeration, with parallel link processing.

- **DfsTargetCleanup** — .NET 10 console application for automated DFS target cleanup
- **ManualRetention** — Original PowerShell scripts for DFS management and build retention

See [DFSCleanup/DfsTargetCleanup/README.md](DFSCleanup/DfsTargetCleanup/README.md) for detailed usage and documentation.

### [WingetUpdater](WingetUpdater/)

Automated Windows software updater using winget. Runs `winget update --all` on a schedule, logs detailed results to a rotating log file, and optionally sends an email report via SMTP.

- **Python 3.10+** — no external dependencies
- **Configurable** via JSON config file
- **Email reports** — SMTP-based, send always / on failure / never

See [WingetUpdater/README.md](WingetUpdater/README.md) for setup and configuration.

## Repository Structure

```
InfrastructureTooling/
├── README.md
├── .gitignore
├── DFSCleanup/
│   ├── DFSCleanup.sln
│   ├── DfsTargetCleanup/          # .NET 10 console app
│   ├── DfsTargetCleanup.Tests/    # xUnit test project (60 tests)
│   └── ManualRetention/           # Original PowerShell scripts
└── WingetUpdater/
    ├── README.md                  # Usage docs & config reference
    ├── winget_updater.py          # Main Python script
    └── config.sample.json         # Sample configuration
```

## Getting Started

### Prerequisites

- .NET 10 SDK
- Windows (DFS tooling is Windows-specific)

### Build & Test

```bash
cd DFSCleanup
dotnet build
dotnet test
```
