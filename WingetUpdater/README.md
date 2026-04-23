# WingetUpdater

Automated Windows software updater powered by [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/). WingetUpdater replaces the manual process of running `winget update --all` with a single Python script that can be scheduled to run automatically, keeps detailed rotating log files, and optionally sends email reports via SMTP.

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Command-Line Interface](#command-line-interface)
- [Configuration Reference](#configuration-reference)
  - [Logging Settings](#logging-settings)
  - [Email Settings](#email-settings)
  - [Winget Settings](#winget-settings)
- [Running as a Scheduled Task](#running-as-a-scheduled-task)
  - [Option A: Task Scheduler GUI](#option-a-task-scheduler-gui)
  - [Option B: PowerShell One-Liner](#option-b-powershell-one-liner)
  - [Scheduling Tips](#scheduling-tips)
- [Email Setup](#email-setup)
  - [Gmail Example](#gmail-example)
  - [Outlook / Microsoft 365 Example](#outlook--microsoft-365-example)
  - [Generic SMTP Example](#generic-smtp-example)
- [Exit Codes](#exit-codes)
- [Logging Details](#logging-details)
- [Example Output](#example-output)
  - [Console / Log File Output](#console--log-file-output)
  - [Email Report](#email-report)
- [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Description |
|---|---|
| **Automated updates** | Runs `winget update --all` to install all available software updates |
| **Dry-run mode** | Preview available updates without installing anything (`--dry-run`) |
| **Rotating log files** | Detailed timestamped logs with configurable file size and rotation count |
| **Console + file logging** | Output goes to both the terminal and the log file simultaneously |
| **Configurable log level** | Set to `DEBUG`, `INFO`, `WARNING`, or `ERROR` as needed |
| **SMTP email reports** | Optional HTML + plain-text email reports sent after each run |
| **Flexible email triggers** | Send email `always`, only on `failure`, or `never` — configurable in JSON or via CLI |
| **CLI email overrides** | Force (`--email`) or suppress (`--no-email`) email on a per-run basis |
| **Package exclusions** | Skip specific packages by ID (e.g., exclude `Microsoft.Edge` from updates) |
| **JSON configuration** | All settings in a single `config.json` file with sensible defaults |
| **Environment variable secrets** | SMTP password can be stored in the `WINGET_UPDATER_SMTP_PASSWORD` env var |
| **Graceful error handling** | Detects missing winget, malformed config, and command timeouts with clear error messages |
| **Meaningful exit codes** | Returns `0` (success), `1` (partial failure), or `2` (critical error) for automation |
| **No external dependencies** | Uses only the Python standard library — no `pip install` required |

---

## Prerequisites

- **Windows 10 or 11** with [winget](https://learn.microsoft.com/en-us/windows/package-manager/winget/) installed  
  Verify by running `winget --version` in a terminal.
- **Python 3.10 or later**  
  Verify by running `python --version`. Download from [python.org](https://www.python.org/downloads/) if needed.
- **No pip dependencies** — the script uses only the Python standard library.

---

## Quick Start

```powershell
# 1. Navigate to the WingetUpdater directory
cd E:\Code\ToolSandbox\WingetUpdater

# 2. Copy the sample config and customize it
copy config.sample.json config.json
notepad config.json    # Edit settings as needed

# 3. Preview available updates (no changes made)
python winget_updater.py --dry-run

# 4. Run a full update
python winget_updater.py

# 5. Run with verbose (DEBUG) logging to see winget raw output
python winget_updater.py --verbose

# 6. Run and force an email report
python winget_updater.py --email

# 7. Run with a custom config file location
python winget_updater.py --config C:\MyConfigs\winget_config.json
```

---

## How It Works

WingetUpdater follows a simple three-phase workflow:

1. **Check** — Runs `winget update` (list mode) to discover which packages have updates available. Parses the tabular output to extract package names, IDs, current versions, and available versions. Excludes any packages listed in `winget.exclude_packages`.

2. **Update** — Unless `--dry-run` is specified, runs `winget update --all` with configured flags (`--accept-source-agreements`, `--accept-package-agreements`, `--include-unknown`, `--exclude`). Captures stdout/stderr, parses per-package results, and checks the process return code for failures.

3. **Report** — Logs a summary to the console and log file. If email is enabled (and the trigger condition is met), builds an HTML + plain-text email with a table of available updates, succeeded installs, and failures, then sends it via SMTP.

---

## Command-Line Interface

```
usage: winget_updater.py [-h] [--config CONFIG] [--dry-run]
                         [--email | --no-email] [--verbose]
```

| Argument | Short | Description |
|---|---|---|
| `--config PATH` | | Path to the JSON configuration file. Defaults to `config.json` in the same directory as the script. If the file does not exist, built-in defaults are used. |
| `--dry-run` | | Check for available updates and log them, but **do not install** any updates. Useful for previewing what would be updated before committing. |
| `--email` | | **Force** sending an email report for this run, regardless of the `email.enabled` and `email.send_on` settings in the config file. Requires valid SMTP settings. |
| `--no-email` | | **Suppress** sending an email report for this run, even if the config would normally trigger one. |
| `--verbose` | `-v` | Set logging level to `DEBUG`. This includes the raw winget stdout/stderr output in the log, which is useful for troubleshooting parsing issues or unexpected behavior. |

> **Note:** `--email` and `--no-email` are mutually exclusive. If neither is specified, the behavior follows the `email.enabled` and `email.send_on` settings in the config file.

---

## Configuration Reference

Create a `config.json` file by copying the provided sample:

```powershell
copy config.sample.json config.json
```

All configuration keys are **optional**. If a key is missing from your `config.json`, the built-in default is used. You can start with a minimal config containing only the settings you want to override.

### Minimal config example

```json
{
    "winget": {
        "exclude_packages": ["Microsoft.Edge"]
    }
}
```

### Full config example

See [`config.sample.json`](config.sample.json) for a complete template with all available keys.

---

### Logging Settings

Settings under the `"log"` key control where and how log output is written.

| Key | Type | Default | Description |
|---|---|---|---|
| `log.file` | string | `"winget_updater.log"` | Path to the log file. Relative paths are resolved from the script directory. Absolute paths are used as-is. Parent directories are created automatically if they don't exist. |
| `log.max_bytes` | integer | `5242880` (5 MB) | Maximum size of a single log file in bytes. When this size is exceeded, the log file is rotated (renamed with a `.1`, `.2`, etc. suffix) and a fresh file is started. |
| `log.backup_count` | integer | `5` | Number of rotated (backup) log files to retain. Older files beyond this count are deleted automatically. For example, with a count of 5 you'll have at most: `winget_updater.log`, `.log.1`, `.log.2`, `.log.3`, `.log.4`, `.log.5`. |
| `log.level` | string | `"INFO"` | Minimum logging level. One of: `DEBUG`, `INFO`, `WARNING`, `ERROR`. At `DEBUG` level, the raw winget stdout/stderr output is included. At `INFO`, you see update checks, results, and summaries. |

**Example — log to a central directory with larger rotation:**

```json
{
    "log": {
        "file": "C:\\Logs\\WingetUpdater\\updates.log",
        "max_bytes": 10485760,
        "backup_count": 10,
        "level": "INFO"
    }
}
```

---

### Email Settings

Settings under the `"email"` key control optional SMTP email reports. Email is **disabled by default**.

| Key | Type | Default | Description |
|---|---|---|---|
| `email.enabled` | boolean | `false` | Master switch for email reports. Must be `true` for emails to be sent (unless overridden with `--email` on the command line). |
| `email.send_on` | string | `"failure"` | Determines when an email is sent. Options: `"always"` — send after every run; `"failure"` — send only when one or more package updates fail; `"never"` — never send (effectively the same as `enabled: false`). |
| `email.smtp_server` | string | `"smtp.example.com"` | Hostname or IP address of the SMTP server. |
| `email.smtp_port` | integer | `587` | SMTP server port. Common values: `587` (STARTTLS), `465` (SSL/TLS), `25` (unencrypted — not recommended). |
| `email.use_tls` | boolean | `true` | Whether to upgrade the connection using STARTTLS after connecting. Should be `true` for port 587. |
| `email.username` | string | `""` | Username for SMTP authentication. Leave empty if your server doesn't require auth. |
| `email.password` | string | `""` | Password for SMTP authentication. **Strongly recommended:** use the `WINGET_UPDATER_SMTP_PASSWORD` environment variable instead (see below). |
| `email.from_address` | string | `""` | The "From" address on the email. |
| `email.to_addresses` | array | `[]` | List of recipient email addresses. Emails are sent to all addresses in this list. |
| `email.subject_prefix` | string | `"[WingetUpdater]"` | Prefix prepended to the email subject line. Useful for mail filters and rules. |

#### SMTP Password Security

**Do not store your SMTP password in `config.json` if the file might be shared, backed up, or committed to version control.**

Instead, set the `WINGET_UPDATER_SMTP_PASSWORD` environment variable:

```powershell
# Set for the current user (persists across reboots)
[Environment]::SetEnvironmentVariable("WINGET_UPDATER_SMTP_PASSWORD", "your-password", "User")

# Or set for the current session only
$env:WINGET_UPDATER_SMTP_PASSWORD = "your-password"
```

The environment variable **always takes precedence** over the `email.password` config value when set.

---

### Winget Settings

Settings under the `"winget"` key control how `winget update` is invoked.

| Key | Type | Default | Description |
|---|---|---|---|
| `winget.accept_source_agreements` | boolean | `true` | Automatically accept source license agreements. Equivalent to `--accept-source-agreements`. Required for unattended/scheduled runs. |
| `winget.accept_package_agreements` | boolean | `true` | Automatically accept individual package license agreements. Equivalent to `--accept-package-agreements`. Required for unattended/scheduled runs. |
| `winget.exclude_packages` | array | `[]` | List of winget package IDs to skip. Each ID is passed as `--exclude <id>` during `winget update --all`. Use this to prevent specific packages from being updated (e.g., packages that require manual intervention or that you want pinned to a specific version). |
| `winget.include_unknown` | boolean | `false` | Include packages whose installed version is unknown. Equivalent to `--include-unknown`. Enable this if you want to update packages that winget can't determine the current version of. |

**Example — exclude specific packages:**

```json
{
    "winget": {
        "exclude_packages": [
            "Microsoft.Edge",
            "Microsoft.Teams",
            "Adobe.Acrobat.Reader.64-bit"
        ]
    }
}
```

> **Tip:** Run `winget list` to see all installed package IDs on your system.

---

## Running as a Scheduled Task

WingetUpdater is designed to be run as a Windows Scheduled Task for fully unattended operation. Below are two methods to set this up.

### Option A: Task Scheduler GUI

1. Press `Win + R`, type `taskschd.msc`, and press Enter.

2. In the right-hand Actions pane, click **Create Task** (not "Create Basic Task" — you need the full dialog).

3. **General tab:**
   - **Name:** `WingetUpdater`
   - **Description:** `Automated winget software updates`
   - Check ✅ **Run whether user is logged on or not**
   - Check ✅ **Run with highest privileges** — winget may require elevation to install certain updates
   - Configure for: **Windows 10** (or your OS version)

4. **Triggers tab → New:**
   - **Begin the task:** On a schedule
   - **Settings:** Daily (or Weekly if you prefer less frequent updates)
   - **Start:** Pick a time when the computer is likely on but idle (e.g., `3:00 AM` or `12:00 PM`)
   - Check ✅ **Enabled**

5. **Actions tab → New:**
   - **Action:** Start a program
   - **Program/script:** `python` (or full path, e.g., `C:\Python312\python.exe`)
   - **Add arguments:** `winget_updater.py`
   - **Start in:** Full path to the WingetUpdater directory (e.g., `E:\Code\ToolSandbox\WingetUpdater`)

6. **Conditions tab:**
   - Uncheck ❌ **Start the task only if the computer is on AC power** (if you want it to run on battery too)
   - Optionally check ✅ **Wake the computer to run this task**

7. **Settings tab:**
   - Check ✅ **Allow task to be run on demand**
   - Check ✅ **If the task fails, restart every:** `5 minutes`, up to `3 times`
   - Set **Stop the task if it runs longer than:** `1 hour`
   - **If the task is already running:** `Do not start a new instance`

8. Click **OK** and enter your Windows password when prompted.

### Option B: PowerShell One-Liner

Run this in an **elevated** PowerShell prompt to create the scheduled task programmatically:

```powershell
# Daily at 3:00 AM
$action = New-ScheduledTaskAction `
    -Execute "python" `
    -Argument "winget_updater.py" `
    -WorkingDirectory "E:\Code\ToolSandbox\WingetUpdater"

$trigger = New-ScheduledTaskTrigger -Daily -At 3am

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName "WingetUpdater" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Description "Automated winget software updates"
```

**To update an existing task:**

```powershell
Set-ScheduledTask -TaskName "WingetUpdater" -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 6am)
```

**To remove the task:**

```powershell
Unregister-ScheduledTask -TaskName "WingetUpdater" -Confirm:$false
```

**To run the task immediately (on demand):**

```powershell
Start-ScheduledTask -TaskName "WingetUpdater"
```

### Scheduling Tips

- **Run with highest privileges** is important because winget may need elevation to install certain updates (e.g., system-level applications).
- **Start in** (working directory) must be set to the WingetUpdater directory so the script can find `config.json` and write the log file to the expected location.
- If Python is not on your system PATH, use the full path to `python.exe` in the Action (e.g., `C:\Python312\python.exe`).
- To send email on failure, make sure `email.enabled` is `true` and `email.send_on` is `"failure"` in your config. Or append `--email` to the Arguments field to always send.
- **Check the log file** (`winget_updater.log` by default) to verify the task ran as expected after the first scheduled execution.
- If the computer might be asleep at the scheduled time, enable **Wake the computer to run this task** in the Conditions tab, or use **Start when available** (in Settings) so the task runs at the next opportunity if it was missed.

---

## Email Setup

### Gmail Example

1. Enable [2-Step Verification](https://myaccount.google.com/security) on your Google account.
2. Go to [App Passwords](https://myaccount.google.com/apppasswords) and generate a new app password for "Mail".
3. Store the password securely:
   ```powershell
   [Environment]::SetEnvironmentVariable("WINGET_UPDATER_SMTP_PASSWORD", "abcd efgh ijkl mnop", "User")
   ```
4. Add to your `config.json`:
   ```json
   {
       "email": {
           "enabled": true,
           "send_on": "always",
           "smtp_server": "smtp.gmail.com",
           "smtp_port": 587,
           "use_tls": true,
           "username": "you@gmail.com",
           "from_address": "you@gmail.com",
           "to_addresses": ["you@gmail.com"]
       }
   }
   ```

### Outlook / Microsoft 365 Example

1. If your organization uses Microsoft 365, you may need an [App Password](https://account.live.com/proofs/AppPassword) or your admin may need to allow SMTP AUTH.
2. Store the password:
   ```powershell
   [Environment]::SetEnvironmentVariable("WINGET_UPDATER_SMTP_PASSWORD", "your-password", "User")
   ```
3. Add to your `config.json`:
   ```json
   {
       "email": {
           "enabled": true,
           "send_on": "failure",
           "smtp_server": "smtp.office365.com",
           "smtp_port": 587,
           "use_tls": true,
           "username": "you@yourorg.com",
           "from_address": "you@yourorg.com",
           "to_addresses": ["you@yourorg.com", "admin@yourorg.com"]
       }
   }
   ```

### Generic SMTP Example

For any SMTP server (self-hosted, ISP-provided, etc.):

```json
{
    "email": {
        "enabled": true,
        "send_on": "always",
        "smtp_server": "mail.example.com",
        "smtp_port": 587,
        "use_tls": true,
        "username": "updates@example.com",
        "from_address": "updates@example.com",
        "to_addresses": ["admin@example.com"],
        "subject_prefix": "[Updates]"
    }
}
```

> **Testing email:** Run `python winget_updater.py --dry-run --email` to send a test report without installing any updates.

---

## Exit Codes

The script returns meaningful exit codes for use in automation and scheduled task monitoring:

| Code | Name | Description |
|---|---|---|
| `0` | Success | All available updates were installed successfully, or no updates were available. |
| `1` | Partial Failure | One or more package updates failed, or the `--email` flag was used but the email failed to send. Check the log file for details. |
| `2` | Critical Error | A fatal error prevented the script from running. Common causes: winget is not installed or not on PATH; the config file contains invalid JSON; the winget command timed out (30-minute safety limit). |

In Task Scheduler, you can see the **Last Run Result** column for these codes. A result of `0x0` means success; `0x1` means partial failure.

---

## Logging Details

WingetUpdater writes logs to both the **console** (stdout) and a **rotating log file** simultaneously.

### Log format

```
YYYY-MM-DD HH:MM:SS  LEVEL     Message
```

Each line includes a timestamp, log level (padded to 8 characters), and the message.

### Log rotation

When the log file reaches `log.max_bytes` (default: 5 MB), the current file is renamed:

```
winget_updater.log    → winget_updater.log.1
winget_updater.log.1  → winget_updater.log.2
...
```

Files beyond `log.backup_count` (default: 5) are deleted. With defaults, you'll retain up to ~30 MB of log history.

### Log levels

| Level | What's logged |
|---|---|
| `DEBUG` | Everything, including the raw winget stdout/stderr output and the exact commands being run. Useful for troubleshooting. |
| `INFO` | Update checks, available package lists, update results (succeeded/failed), email status, and run summaries. **Recommended for normal use.** |
| `WARNING` | Package update failures, non-zero winget return codes, missing email recipients. |
| `ERROR` | Email send failures (with full tracebacks at this level). |

---

## Example Output

### Console / Log File Output

A typical run with 3 available updates:

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
2026-04-23 03:01:30  INFO        OK: Successfully installed 7zip.7zip
2026-04-23 03:01:30  INFO        OK: Successfully installed Git.Git
2026-04-23 03:01:30  INFO        OK: Successfully installed Mozilla.Firefox
2026-04-23 03:01:30  INFO      ------------------------------------------------------------
2026-04-23 03:01:30  INFO      Finished successfully. 3 package(s) updated.
2026-04-23 03:01:30  INFO      ============================================================
```

A dry-run with no updates available:

```
2026-04-23 12:00:00  INFO      ============================================================
2026-04-23 12:00:00  INFO      WingetUpdater started at 2026-04-23 12:00:00
2026-04-23 12:00:00  INFO      ============================================================
2026-04-23 12:00:00  INFO      Checking for available updates...
2026-04-23 12:00:03  INFO      All packages are up to date.
2026-04-23 12:00:03  INFO      Dry-run mode — skipping update installation.
2026-04-23 12:00:03  INFO      ------------------------------------------------------------
2026-04-23 12:00:03  INFO      DRY RUN complete. 0 update(s) available.
2026-04-23 12:00:03  INFO      ============================================================
```

A run with a failure:

```
2026-04-23 03:00:00  INFO      Applying updates...
2026-04-23 03:01:00  INFO      Update complete. Succeeded: 2, Failed: 1
2026-04-23 03:01:00  INFO        OK: Successfully installed 7zip.7zip
2026-04-23 03:01:00  INFO        OK: Successfully installed Git.Git
2026-04-23 03:01:00  WARNING     FAIL: An unexpected error occurred while installing Mozilla.Firefox
2026-04-23 03:01:00  INFO      Sending email report to admin@example.com ...
2026-04-23 03:01:02  INFO      Email sent successfully.
2026-04-23 03:01:02  WARNING   Finished with 1 failure(s) and 2 success(es).
```

### Email Report

When email is enabled, the report includes:

- **Subject line:** `[WingetUpdater] HOSTNAME: OK — 3 updated` (or `FAILURES (1)` on failure)
- **HTML body:** A formatted table of available updates, a list of succeeded installs, and a highlighted section for any failures
- **Plain-text body:** The same information in a plain-text format for email clients that don't render HTML

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `winget is not installed or not on PATH` | Install winget via the [Microsoft Store](https://apps.microsoft.com/detail/9nblggh4nns1) or [GitHub releases](https://github.com/microsoft/winget-cli/releases). Ensure it's accessible from the account running the scheduled task. |
| Script runs manually but not via Task Scheduler | Ensure **Start in** is set to the WingetUpdater directory. Use the full path to `python.exe`. Check **Run with highest privileges** is enabled. |
| No updates detected but `winget update` shows updates manually | Run with `--verbose` and check the log for raw winget output. The parser expects standard English winget output. If winget is localized, output format may differ. |
| Email not sending | Test with `python winget_updater.py --dry-run --email --verbose`. Check that SMTP server, port, and credentials are correct. Verify the `WINGET_UPDATER_SMTP_PASSWORD` env var is set. Some providers require app passwords or have SMTP AUTH disabled by default. |
| `config.json` errors | Validate your JSON at [jsonlint.com](https://jsonlint.com/). Common mistakes: trailing commas, missing quotes, wrong value types. The script will exit with code 2 and log the parse error. |
| Log file not created | Check that the user account has write permissions to the log directory. If using a relative path, it's resolved from the script directory. |
| Updates require elevation | Enable **Run with highest privileges** in Task Scheduler. Some packages (e.g., system-level tools) require admin rights to update. |
