# InfrastructureTooling

A collection of infrastructure management and automation tools.

## Tools

### [DFSCleanup](DFSCleanup/)

Validates and removes inactive or unreachable DFS folder targets using `dfsutil` for fast namespace enumeration, with parallel link processing.

- **DfsTargetCleanup** — .NET 10 console application for automated DFS target cleanup
- **ManualRetention** — Original PowerShell scripts for DFS management and build retention

See [DFSCleanup/DfsTargetCleanup/README.md](DFSCleanup/DfsTargetCleanup/README.md) for detailed usage and documentation.

## Repository Structure

```
InfrastructureTooling/
├── README.md
├── .gitignore
└── DFSCleanup/
    ├── DFSCleanup.sln
    ├── DfsTargetCleanup/          # .NET 10 console app
    ├── DfsTargetCleanup.Tests/    # xUnit test project (60 tests)
    └── ManualRetention/           # Original PowerShell scripts
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
