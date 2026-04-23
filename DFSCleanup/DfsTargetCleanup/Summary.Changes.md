# Summary: I/O Service Testability — Interface Extraction & Dependency Injection

## Overview

This change introduces a testability layer for the 4 I/O-heavy services that were previously untestable due to direct coupling to filesystem, network, process execution, and PowerShell runtime dependencies. The approach uses interface extraction and constructor-based dependency injection, enabling full unit test coverage via Moq mocks.

**Test count:** 60 → 96 (36 new tests across 3 test classes)
**Build:** 0 warnings, 0 errors
**All 96 tests pass**

## What Was Implemented

### Abstraction Interfaces (5 new files)

| Interface | Purpose | Key Methods |
|-----------|---------|-------------|
| `IFileSystem` | File/directory operations | `FileExists`, `DirectoryExists`, `CreateDirectory`, `DeleteFile`, `GetFileLength`, `ReadAllLines`, `WriteAllLines`, `EnumerateFileSystemEntries` |
| `IProcessRunner` | External process execution | `RunAsync` → `ProcessResult(ExitCode, Stdout, Stderr)` |
| `INetworkChecker` | Network connectivity | `PingAsync` → `PingCheckResult(Success, Address, RoundtripTime, StatusMessage)` |
| `IEnvironmentProvider` | Environment variables | `GetEnvironmentVariable` |
| `IDfsnRemovalService` | DFS removal operations | `RemoveFolderTarget`, `RemoveFolder`, `ValidateModule` |

### Default Implementations (4 new files)

| Class | Delegates To |
|-------|-------------|
| `DefaultFileSystem` | `System.IO.File`, `System.IO.Directory`, `System.IO.FileInfo` |
| `DefaultProcessRunner` | `System.Diagnostics.Process` |
| `DefaultNetworkChecker` | `System.Net.NetworkInformation.Ping` |
| `DefaultEnvironmentProvider` | `System.Environment` |

### Service Refactoring (4 files modified)

| Service | Before | After |
|---------|--------|-------|
| `DfsnRemovalService` | Class with virtual methods, `static ValidateDfsnModule()` | Implements `IDfsnRemovalService`, `ValidateModule()` is now instance method |
| `DfsExportService` | Static class, direct `File`/`Process`/`Environment` calls | Instance class, constructor-injected `IFileSystem`, `IProcessRunner`, `IEnvironmentProvider` |
| `PreflightService` | Static class, direct `Ping`/`Directory` calls | Instance class, constructor-injected `INetworkChecker`, `IFileSystem` |
| `LinkProcessorService` | Constructor takes `DfsnRemovalService` concrete type | Constructor takes `IDfsnRemovalService` + `IFileSystem` |

### Program.cs (Composition Root)

Updated to instantiate default implementations and wire them into services:
```csharp
var fileSystem = new DefaultFileSystem();
var networkChecker = new DefaultNetworkChecker();
var processRunner = new DefaultProcessRunner();
var envProvider = new DefaultEnvironmentProvider();
var removalService = new DfsnRemovalService();

var preflightService = new PreflightService(networkChecker, fileSystem);
var exportService = new DfsExportService(fileSystem, processRunner, envProvider);
var processor = new LinkProcessorService(removalService, fileSystem);
```

### New Tests (3 test classes, 36 tests)

**DfsExportServiceTests (14 tests)**
- `GetDfsUtilPath`: env var resolution, missing file, wrong filename, SystemRoot fallback
- `ExportAllAsync`: successful export, process failure, reuse existing, zero-byte file, partial failure, post-export encoding fix, empty server list, cancellation propagation

**PreflightServiceTests (10 tests)**
- All servers reachable, ping failure, ping exception, share inaccessible, share access throws, empty share (still reachable), content enumeration throws, no servers, original order preservation, cancellation propagation

**LinkProcessorServiceTests (12 tests)**
- Online+reachable (no removals), offline target, unreachable target, WhatIf mode, actual removal, removal failure, folder filter exclusion, wildcard matching, skip completed links, no targets in link, multiple targets per link, record field correctness

## Design Choices

### Why thin interfaces (not a full abstraction library)?

We defined only the methods actually called by our services, avoiding unnecessary abstraction surface. For example, `IFileSystem` has 8 methods — not the 40+ a complete filesystem abstraction would have. This keeps the interfaces focused and easy to mock.

### Why not Microsoft.Extensions.DependencyInjection?

The application is a CLI tool with a simple composition graph (no request scoping, no lifetime management needed). Manual constructor injection in `Program.cs` is clearer and avoids adding a DI container dependency for 5 registrations.

### Why ConsoleHelper stays static?

`ConsoleHelper` is write-only output. Mocking it adds testing noise (verify console colors?) without catching real bugs. Tests verify behavior through returned data structures (e.g., `RemovalRecord` lists, reachable server lists).

### Why `GetDfsUtilPath` is `internal` (not private)?

Exposing it as `internal` (visible to tests via `InternalsVisibleTo`) allows direct unit testing of path resolution logic without needing to go through `ExportAllAsync`.

## Code Review Process

### Review 1 — Found 2 issues

| Severity | Issue | Fix |
|----------|-------|-----|
| **High** | `DefaultNetworkChecker.PingAsync` accepted `CancellationToken` but didn't pass it to `Ping.SendPingAsync`. Ctrl+C wouldn't cancel in-flight pings. | Changed to `SendPingAsync(host, TimeSpan.FromMilliseconds(timeoutMs), null, null, ct)` overload that accepts `CancellationToken`. |
| **Medium** | `DfsExportService.ExportAllAsync` set `MaxDegreeOfParallelism = servers.Count` which throws `ArgumentOutOfRangeException` if servers list is empty (0 is invalid). | Added `Math.Max(1, servers.Count)` guard, matching the fix already in `PreflightService`. |

### Review 2 — Found 3 issues

| Severity | Issue | Fix |
|----------|-------|-----|
| **Medium** | No tests for `CancellationToken` propagation — regressions like Review 1's High issue could reoccur undetected. | Added `Cancellation_PropagatesToken` tests to both `DfsExportServiceTests` and `PreflightServiceTests`. |
| **Low** | No tests for empty server list edge case in `ExportAllAsync`. | Added `ExportAllAsync_EmptyServerList_ReturnsEmpty` test. |
| **Low** | `DefaultFileSystem.GetFileLength` could throw `FileNotFoundException` if called without prior `FileExists` check. Current call sites are safe. | Added XML doc comment documenting the precondition. |

## Files Changed

### New Files (9)
- `Abstractions/IFileSystem.cs`
- `Abstractions/IProcessRunner.cs`
- `Abstractions/INetworkChecker.cs`
- `Abstractions/IEnvironmentProvider.cs`
- `Abstractions/IDfsnRemovalService.cs`
- `Abstractions/Defaults/DefaultFileSystem.cs`
- `Abstractions/Defaults/DefaultProcessRunner.cs`
- `Abstractions/Defaults/DefaultNetworkChecker.cs`
- `Abstractions/Defaults/DefaultEnvironmentProvider.cs`

### New Test Files (3)
- `DfsTargetCleanup.Tests/Services/DfsExportServiceTests.cs`
- `DfsTargetCleanup.Tests/Services/PreflightServiceTests.cs`
- `DfsTargetCleanup.Tests/Services/LinkProcessorServiceTests.cs`

### Modified Files (5)
- `Services/DfsnRemovalService.cs` — implements `IDfsnRemovalService`, instance `ValidateModule()`
- `Services/DfsExportService.cs` — static → instance, constructor DI
- `Services/PreflightService.cs` — static → instance, constructor DI
- `Services/LinkProcessorService.cs` — uses `IDfsnRemovalService` + `IFileSystem`
- `Program.cs` — composition root wiring

### Updated Documentation (1)
- `README.md` — architecture diagram, project structure updated
