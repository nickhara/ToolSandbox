# WingetUpdater

Automated Windows software updater using [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/). Checks for updates, applies them, logs detailed results to a rotating log file, and optionally sends an email report via SMTP.

## Prerequisites

- **Windows 10/11** with winget installed
- **Python 3.10+** (standard library only — no pip dependencies)

## Quick Start

```powershell
# 1. Copy the sample config and edit it
cd WingetUpdater
copy config.sample.json config.json
# Edit config.json with your preferred settings

# 2. Run an update check (dry run)
python winget_updater.py --dry-run

# 3. Run a full update
python winget_updater.py

# 4. Run with verbose logging
python winget_updater.py --verbose
```

## CLI Arguments

| Argument | Description |
|---|---|
| `--config PATH` | Path to JSON config file (default: `config.json` in script directory) |
| `--dry-run` | List available updates without installing them |
| `--email` | Force sending an email report regardless of config |
| `--no-email` | Suppress email report regardless of config |
| `--verbose`, `-v` | Enable DEBUG-level logging |

## Configuration Reference

Create a `config.json` file (see `config.sample.json` for a template). All fields are optional — defaults are used for any missing keys.

### Logging

| Key | Default | Description |
|---|---|---|
| `log.file` | `winget_updater.log` | Log file path (relative to script directory or absolute) |
| `log.max_bytes` | `5242880` (5 MB) | Maximum log file size before rotation |
| `log.backup_count` | `5` | Number of rotated log files to keep |
| `log.level` | `INFO` | Logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

### Email

| Key | Default | Description |
|---|---|---|
| `email.enabled` | `false` | Enable email reports |
| `email.send_on` | `failure` | When to send: `always`, `failure`, or `never` |
| `email.smtp_server` | — | SMTP server hostname |
| `email.smtp_port` | `587` | SMTP server port |
| `email.use_tls` | `true` | Use STARTTLS |
| `email.username` | — | SMTP authentication username |
| `email.password` | — | SMTP password (prefer `WINGET_UPDATER_SMTP_PASSWORD` env var) |
| `email.from_address` | — | Sender email address |
| `email.to_addresses` | `[]` | List of recipient email addresses |
| `email.subject_prefix` | `[WingetUpdater]` | Prefix for email subject line |

> **Security note:** Use the `WINGET_UPDATER_SMTP_PASSWORD` environment variable instead of storing your password in the config file. The env var takes precedence when set.

### Winget

| Key | Default | Description |
|---|---|---|
| `winget.accept_source_agreements` | `true` | Auto-accept source agreements |
| `winget.accept_package_agreements` | `true` | Auto-accept package agreements |
| `winget.exclude_packages` | `[]` | List of package IDs to skip (e.g., `["Microsoft.Edge"]`) |
| `winget.include_unknown` | `false` | Include packages with unknown versions |

## Scheduling with Task Scheduler

To run automatically, create a Windows Task Scheduler task:

1. Open **Task Scheduler** → **Create Task**
2. **General** tab:
   - Name: `WingetUpdater`
   - Check "Run whether user is logged on or not"
   - Check "Run with highest privileges" (winget may need elevation)
3. **Triggers** tab → **New**:
   - Set your preferred schedule (e.g., daily at 3:00 AM)
4. **Actions** tab → **New**:
   - Program: `python` (or full path to `python.exe`)
   - Arguments: `winget_updater.py`
   - Start in: `C:\path\to\WingetUpdater`
5. **Settings** tab:
   - Check "Allow task to be run on demand"
   - Set "Stop the task if it runs longer than" to `1 hour`

Alternatively, use PowerShell:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "python" `
    -Argument "winget_updater.py" `
    -WorkingDirectory "C:\path\to\WingetUpdater"

$trigger = New-ScheduledTaskTrigger -Daily -At 3am

Register-ScheduledTask `
    -TaskName "WingetUpdater" `
    -Action $action `
    -Trigger $trigger `
    -RunLevel Highest `
    -Description "Automated winget software updates"
```

## Email Setup (Gmail Example)

1. Enable [App Passwords](https://support.google.com/accounts/answer/185833) on your Google account
2. Generate an app password for "Mail"
3. Set the environment variable:
   ```powershell
   [Environment]::SetEnvironmentVariable("WINGET_UPDATER_SMTP_PASSWORD", "your-app-password", "User")
   ```
4. Configure `config.json`:
   ```json
   {
       "email": {
           "enabled": true,
           "send_on": "always",
           "smtp_server": "smtp.gmail.com",
           "smtp_port": 587,
           "use_tls": true,
           "username": "your.email@gmail.com",
           "from_address": "your.email@gmail.com",
           "to_addresses": ["your.email@gmail.com"]
       }
   }
   ```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All updates succeeded (or no updates available) |
| `1` | Partial failure — some updates failed, or forced email failed to send |
| `2` | Critical error — winget not found, config error, timeout |

## Example Log Output

```
2026-04-23 03:00:00  INFO      ============================================================
2026-04-23 03:00:00  INFO      WingetUpdater started at 2026-04-23 03:00:00
2026-04-23 03:00:00  INFO      ============================================================
2026-04-23 03:00:00  INFO      Checking for available updates...
2026-04-23 03:00:05  INFO      Found 3 update(s) available:
2026-04-23 03:00:05  INFO        7zip.7zip                                 24.08 -> 24.09
2026-04-23 03:00:05  INFO        Git.Git                                   2.47.0 -> 2.47.1
2026-04-23 03:00:05  INFO        Mozilla.Firefox                           133.0 -> 133.0.1
2026-04-23 03:00:05  INFO      Applying updates...
2026-04-23 03:01:30  INFO      Update complete. Succeeded: 3, Failed: 0
2026-04-23 03:01:30  INFO      ------------------------------------------------------------
2026-04-23 03:01:30  INFO      Finished successfully. 3 package(s) updated.
2026-04-23 03:01:30  INFO      ============================================================
```
