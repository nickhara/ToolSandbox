#!/usr/bin/env python3
"""Automated Windows software updater using winget.

Runs `winget update --all`, logs results to a rotating log file,
and optionally sends an email report via SMTP.
"""

import argparse
import json
import logging
import logging.handlers
import os
import html as html_mod
import re
import smtplib
import subprocess
import sys
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

BANNER = r"""
 __        ___                   _   _   _           _       _
 \ \      / (_)_ __   __ _  ___| |_| | | |_ __   __| | __ _| |_ ___ _ __
  \ \ /\ / /| | '_ \ / _` |/ _ \ __| | | | '_ \ / _` |/ _` | __/ _ \ '__|
   \ V  V / | | | | | (_| |  __/ |_| |_| | |_) | (_| | (_| | ||  __/ |
    \_/\_/  |_|_| |_|\__, |\___|\__|\___/| .__/ \__,_|\__,_|\__\___|_|
                      |___/               |_|
"""


def _log_section(logger: logging.Logger, title: str, char: str = "━") -> None:
    """Log a decorated section header."""
    bar = char * 60
    logger.info("")
    logger.info("┌%s┐", char * 58)
    logger.info("│%s│", title.center(58))
    logger.info("└%s┘", char * 58)


def _log_table(logger: logging.Logger, rows: list[list[str]], headers: list[str]) -> None:
    """Log a formatted ASCII table."""
    cols = len(headers)
    widths = [len(h) for h in headers]
    for row in rows:
        for i in range(cols):
            widths[i] = max(widths[i], len(row[i]) if i < len(row) else 0)

    sep = "├" + "┼".join("─" * (w + 2) for w in widths) + "┤"
    top = "┌" + "┬".join("─" * (w + 2) for w in widths) + "┐"
    bot = "└" + "┴".join("─" * (w + 2) for w in widths) + "┘"

    hdr = "│" + "│".join(f" {headers[i]:<{widths[i]}} " for i in range(cols)) + "│"
    logger.info(top)
    logger.info(hdr)
    logger.info(sep)
    for row in rows:
        cells = "│" + "│".join(
            f" {(row[i] if i < len(row) else ''):<{widths[i]}} " for i in range(cols)
        ) + "│"
        logger.info(cells)
    logger.info(bot)


DEFAULT_CONFIG = {
    "log": {
        "file": "winget_updater.log",
        "max_bytes": 5_242_880,
        "backup_count": 5,
        "level": "INFO",
    },
    "email": {
        "enabled": False,
        "send_on": "failure",
        "smtp_server": "smtp.example.com",
        "smtp_port": 587,
        "use_tls": True,
        "username": "",
        "password": "",
        "from_address": "",
        "to_addresses": [],
        "subject_prefix": "[WingetUpdater]",
    },
    "winget": {
        "accept_source_agreements": True,
        "accept_package_agreements": True,
        "exclude_packages": [],
        "include_unknown": False,
    },
}

EXIT_SUCCESS = 0
EXIT_PARTIAL_FAILURE = 1
EXIT_CRITICAL_ERROR = 2


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge *override* into *base*, returning a new dict."""
    merged = base.copy()
    for key, value in override.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config(config_path: Path) -> dict:
    """Load configuration from a JSON file, merged with defaults."""
    if not config_path.exists():
        logging.info("No config file found at %s — using defaults.", config_path)
        config = _deep_merge(DEFAULT_CONFIG, {})
    else:
        try:
            with open(config_path, encoding="utf-8") as fh:
                user_config = json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            logging.critical("Failed to load config file %s: %s", config_path, exc)
            sys.exit(EXIT_CRITICAL_ERROR)
        config = _deep_merge(DEFAULT_CONFIG, user_config)

    # Allow env-var override for SMTP password
    env_password = os.environ.get("WINGET_UPDATER_SMTP_PASSWORD")
    if env_password:
        config["email"]["password"] = env_password

    return config


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging(config: dict, verbose: bool = False) -> logging.Logger:
    """Configure rotating file + console logging."""
    log_cfg = config["log"]
    level_name = "DEBUG" if verbose else log_cfg.get("level", "INFO")
    level = getattr(logging, level_name.upper(), logging.INFO)

    logger = logging.getLogger("winget_updater")
    logger.setLevel(level)
    logger.handlers.clear()

    formatter = logging.Formatter(
        "%(asctime)s  %(levelname)-8s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Rotating file handler
    log_file = Path(log_cfg.get("file", "winget_updater.log"))
    if not log_file.is_absolute():
        log_file = SCRIPT_DIR / log_file
    log_file.parent.mkdir(parents=True, exist_ok=True)

    file_handler = logging.handlers.RotatingFileHandler(
        log_file,
        maxBytes=log_cfg.get("max_bytes", 5_242_880),
        backupCount=log_cfg.get("backup_count", 5),
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    # Console handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    return logger


# ---------------------------------------------------------------------------
# Winget helpers
# ---------------------------------------------------------------------------

def _run_winget(args: list[str], logger: logging.Logger) -> subprocess.CompletedProcess:
    """Run a winget command and return the CompletedProcess result."""
    cmd = ["winget"] + args
    logger.debug("Running: %s", " ".join(cmd))
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=1800,  # 30 min safety timeout
        )
    except FileNotFoundError:
        logger.critical("winget is not installed or not on PATH.")
        sys.exit(EXIT_CRITICAL_ERROR)
    except subprocess.TimeoutExpired:
        logger.critical("winget command timed out after 30 minutes.")
        sys.exit(EXIT_CRITICAL_ERROR)

    if result.stdout:
        logger.debug("stdout:\n%s", result.stdout)
    if result.stderr:
        logger.debug("stderr:\n%s", result.stderr)

    return result


def _parse_upgrade_list(output: str) -> list[dict]:
    """Parse the tabular output of `winget update` into a list of dicts.

    Each dict has keys: name, id, current_version, available_version, source.
    """
    packages = []
    lines = output.splitlines()

    # Find the header separator line (dashes)
    header_idx = None
    for i, line in enumerate(lines):
        if re.match(r"^-{2,}", line.replace(" ", "")):
            header_idx = i
            break

    if header_idx is None or header_idx == 0:
        return packages

    # Use the dash-separator line to determine column boundaries
    header_line = lines[header_idx - 1]
    separator = lines[header_idx]

    # Find column start positions from the separator
    col_starts = []
    in_dash = False
    for i, ch in enumerate(separator):
        if ch == "-" and not in_dash:
            col_starts.append(i)
            in_dash = True
        elif ch != "-":
            in_dash = False

    # Parse data rows after the separator
    for line in lines[header_idx + 1:]:
        if not line.strip():
            continue
        # Stop at summary lines
        if "upgrades available" in line.lower() or line.startswith("The following"):
            continue

        # Extract fields using column positions
        fields = []
        for j, start in enumerate(col_starts):
            end = col_starts[j + 1] if j + 1 < len(col_starts) else len(line)
            fields.append(line[start:end].strip() if start < len(line) else "")

        if len(fields) >= 4:
            packages.append({
                "name": fields[0],
                "id": fields[1],
                "current_version": fields[2],
                "available_version": fields[3],
                "source": fields[4] if len(fields) > 4 else "",
            })

    return packages


def check_updates(config: dict, logger: logging.Logger) -> list[dict]:
    """Check for available updates and return the list of packages."""
    _log_section(logger, "🔍  CHECKING FOR UPDATES")
    args = ["update"]
    if config["winget"].get("accept_source_agreements"):
        args.append("--accept-source-agreements")
    if config["winget"].get("include_unknown"):
        args.append("--include-unknown")

    result = _run_winget(args, logger)

    if result.returncode != 0:
        logger.warning("winget update check exited with code %d.", result.returncode)

    packages = _parse_upgrade_list(result.stdout)

    # Filter out excluded packages
    excluded = set(config["winget"].get("exclude_packages", []))
    if excluded:
        before = len(packages)
        packages = [p for p in packages if p["id"] not in excluded]
        skipped = before - len(packages)
        if skipped:
            logger.info("Excluded %d package(s) per configuration.", skipped)

    if packages:
        logger.info("Found %d update(s) available:", len(packages))
        table_rows = [
            [pkg["id"], pkg["current_version"], pkg["available_version"]]
            for pkg in packages
        ]
        _log_table(logger, table_rows, ["Package ID", "Current", "Available"])
    else:
        logger.info("✅  All packages are up to date.")

    return packages


def apply_updates(config: dict, logger: logging.Logger) -> tuple[list[dict], list[dict]]:
    """Run `winget update --all` and return (succeeded, failed) package lists."""
    _log_section(logger, "⬆️  APPLYING UPDATES")

    args = ["update", "--all"]
    if config["winget"].get("accept_source_agreements"):
        args.append("--accept-source-agreements")
    if config["winget"].get("accept_package_agreements"):
        args.append("--accept-package-agreements")
    if config["winget"].get("include_unknown"):
        args.append("--include-unknown")

    for pkg_id in config["winget"].get("exclude_packages", []):
        args.extend(["--exclude", pkg_id])

    result = _run_winget(args, logger)

    # Log the raw output at DEBUG level for troubleshooting
    logger.debug("--- winget update --all raw output ---")
    for line in result.stdout.splitlines():
        logger.debug("  %s", line)
    if result.stderr:
        logger.debug("--- stderr ---")
        for line in result.stderr.splitlines():
            logger.debug("  %s", line)

    # Parse results from output
    succeeded = []
    failed = []

    for line in result.stdout.splitlines():
        lower = line.lower()
        if "successfully installed" in lower:
            succeeded.append({"detail": line.strip()})
        elif "failed" in lower or "error" in lower:
            # Exclude generic info lines that happen to contain these words
            if not any(skip in lower for skip in ["no applicable", "upgrade all"]):
                failed.append({"detail": line.strip()})

    # Use return code as an additional failure signal
    if result.returncode != 0 and not failed:
        failed.append({"detail": f"winget exited with code {result.returncode}"})

    _log_section(logger, "📊  UPDATE RESULTS")
    logger.info("  Succeeded: %d  |  Failed: %d", len(succeeded), len(failed))
    logger.info("")

    if succeeded:
        for s in succeeded:
            logger.info("  ✅  %s", s["detail"])
    if failed:
        for f in failed:
            logger.warning("  ❌  %s", f["detail"])

    return succeeded, failed


# ---------------------------------------------------------------------------
# Email reporting
# ---------------------------------------------------------------------------

def _build_email_body(
    available: list[dict],
    succeeded: list[dict],
    failed: list[dict],
    dry_run: bool,
) -> tuple[str, str]:
    """Return (plain_text, html) bodies for the email report."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    hostname = os.environ.get("COMPUTERNAME", "unknown")

    # ── Plain text ──────────────────────────────────────────────
    lines = [
        "╔══════════════════════════════════════════════════════════╗",
        "║              WINGET UPDATER  —  REPORT                  ║",
        "╚══════════════════════════════════════════════════════════╝",
        "",
        f"  Host:    {hostname}",
        f"  Date:    {now}",
    ]
    if dry_run:
        lines.append("  Mode:    DRY RUN (no updates applied)")
    lines.append("")

    if available:
        lines.append(f"  Updates Available: {len(available)}")
        lines.append("  " + "-" * 56)
        for pkg in available:
            lines.append(
                f"  {pkg['id']:40s}  {pkg['current_version']:>8s} → {pkg['available_version']}"
            )
        lines.append("")

    if not dry_run:
        if succeeded:
            lines.append(f"  ✅ Succeeded: {len(succeeded)}")
            for s in succeeded:
                lines.append(f"     {s['detail']}")
            lines.append("")
        if failed:
            lines.append(f"  ❌ Failed: {len(failed)}")
            for f_ in failed:
                lines.append(f"     {f_['detail']}")
            lines.append("")
        if not succeeded and not failed:
            lines.append("  No update operations were performed.")
            lines.append("")
    elif not available:
        lines.append("  ✅ All packages are up to date.")
        lines.append("")

    plain = "\n".join(lines)

    # ── HTML ────────────────────────────────────────────────────
    if failed:
        status_color = "#dc3545"
        status_icon = "❌"
        status_text = f"{len(failed)} FAILURE{'S' if len(failed) != 1 else ''}"
    elif succeeded:
        status_color = "#28a745"
        status_icon = "✅"
        status_text = f"{len(succeeded)} UPDATED"
    elif available and dry_run:
        status_color = "#0d6efd"
        status_icon = "🔍"
        status_text = f"{len(available)} AVAILABLE (DRY RUN)"
    else:
        status_color = "#28a745"
        status_icon = "✅"
        status_text = "UP TO DATE"

    html = f"""\
<html>
<head>
<style>
  body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f6f9; margin: 0; padding: 20px; color: #333; }}
  .container {{ max-width: 700px; margin: 0 auto; background: #fff; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); overflow: hidden; }}
  .header {{ background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%); color: #fff; padding: 28px 32px; }}
  .header h1 {{ margin: 0 0 4px 0; font-size: 22px; font-weight: 600; letter-spacing: 0.5px; }}
  .header .subtitle {{ color: #94a3b8; font-size: 13px; }}
  .status-banner {{ padding: 14px 32px; background: {status_color}; color: #fff; font-size: 16px; font-weight: 600; letter-spacing: 0.3px; }}
  .content {{ padding: 24px 32px; }}
  .meta-table {{ width: 100%; margin-bottom: 20px; font-size: 13px; color: #64748b; }}
  .meta-table td {{ padding: 3px 0; }}
  .meta-table td:first-child {{ font-weight: 600; width: 80px; color: #475569; }}
  h2 {{ font-size: 16px; color: #1e293b; margin: 24px 0 12px 0; padding-bottom: 6px; border-bottom: 2px solid #e2e8f0; }}
  table.pkg-table {{ width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 16px; }}
  table.pkg-table th {{ background: #f8fafc; color: #475569; text-align: left; padding: 10px 12px; border: 1px solid #e2e8f0; font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 0.5px; }}
  table.pkg-table td {{ padding: 9px 12px; border: 1px solid #e2e8f0; }}
  table.pkg-table tr:nth-child(even) {{ background: #f8fafc; }}
  table.pkg-table tr:hover {{ background: #eff6ff; }}
  .result-item {{ padding: 8px 12px; margin: 4px 0; border-radius: 4px; font-size: 13px; }}
  .result-ok {{ background: #f0fdf4; border-left: 3px solid #22c55e; color: #166534; }}
  .result-fail {{ background: #fef2f2; border-left: 3px solid #ef4444; color: #991b1b; }}
  .footer {{ padding: 16px 32px; background: #f8fafc; border-top: 1px solid #e2e8f0; text-align: center; font-size: 11px; color: #94a3b8; }}
  .version-arrow {{ color: #94a3b8; padding: 0 4px; }}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>WingetUpdater</h1>
    <div class="subtitle">Automated Software Update Report</div>
  </div>
  <div class="status-banner">{status_icon}&ensp;{status_text}</div>
  <div class="content">
    <table class="meta-table">
      <tr><td>Host</td><td>{html_mod.escape(hostname)}</td></tr>
      <tr><td>Date</td><td>{html_mod.escape(now)}</td></tr>
      <tr><td>Mode</td><td>{'DRY RUN' if dry_run else 'Live Update'}</td></tr>
    </table>
"""

    # Available updates table
    if available:
        html += f'    <h2>📦 Available Updates ({len(available)})</h2>\n'
        html += '    <table class="pkg-table">\n'
        html += "      <tr><th>Package</th><th>Current Version</th>"
        html += '<th>Available Version</th></tr>\n'
        for pkg in available:
            pid = html_mod.escape(pkg["id"])
            cur = html_mod.escape(pkg["current_version"])
            avail = html_mod.escape(pkg["available_version"])
            html += (
                f"      <tr><td><strong>{pid}</strong></td>"
                f'<td>{cur}</td><td style="color:#0d6efd;font-weight:600">{avail}</td></tr>\n'
            )
        html += "    </table>\n"
    else:
        html += "    <p>All packages are up to date. No action required.</p>\n"

    # Results
    if not dry_run:
        if succeeded:
            html += f'    <h2>✅ Succeeded ({len(succeeded)})</h2>\n'
            for s in succeeded:
                html += f'    <div class="result-item result-ok">{html_mod.escape(s["detail"])}</div>\n'

        if failed:
            html += f'    <h2>❌ Failed ({len(failed)})</h2>\n'
            for f_ in failed:
                html += f'    <div class="result-item result-fail">{html_mod.escape(f_["detail"])}</div>\n'

        if not succeeded and not failed:
            html += "    <p>No update operations were performed.</p>\n"

    html += """\
  </div>
  <div class="footer">
    Generated by WingetUpdater &bull; github.com/nickhara/ToolSandbox
  </div>
</div>
</body>
</html>
"""

    return plain, html


def send_email(
    config: dict,
    available: list[dict],
    succeeded: list[dict],
    failed: list[dict],
    dry_run: bool,
    logger: logging.Logger,
) -> bool:
    """Send the update report via SMTP. Returns True on success."""
    email_cfg = config["email"]

    if not email_cfg.get("to_addresses"):
        logger.warning("No email recipients configured — skipping email.")
        return False

    plain, html = _build_email_body(available, succeeded, failed, dry_run)

    # Build subject
    prefix = email_cfg.get("subject_prefix", "[WingetUpdater]")
    if failed:
        status = f"FAILURES ({len(failed)})"
    elif succeeded:
        status = f"OK — {len(succeeded)} updated"
    elif available:
        status = f"{len(available)} available (dry run)" if dry_run else "No changes"
    else:
        status = "Up to date"

    hostname = os.environ.get("COMPUTERNAME", "unknown")
    subject = f"{prefix} {hostname}: {status}"

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = email_cfg["from_address"]
    msg["To"] = ", ".join(email_cfg["to_addresses"])
    msg.attach(MIMEText(plain, "plain"))
    msg.attach(MIMEText(html, "html"))

    try:
        logger.info("Sending email report to %s ...", msg["To"])
        server = smtplib.SMTP(email_cfg["smtp_server"], email_cfg["smtp_port"], timeout=30)
        if email_cfg.get("use_tls", True):
            server.starttls()
        if email_cfg.get("username") and email_cfg.get("password"):
            server.login(email_cfg["username"], email_cfg["password"])
        server.sendmail(email_cfg["from_address"], email_cfg["to_addresses"], msg.as_string())
        server.quit()
        logger.info("Email sent successfully.")
        return True
    except Exception:
        logger.exception("Failed to send email report.")
        return False


def should_send_email(config: dict, failed: list[dict], force: bool | None) -> bool:
    """Determine whether to send the email based on config and overrides."""
    if force is True:
        return True
    if force is False:
        return False

    email_cfg = config["email"]
    if not email_cfg.get("enabled", False):
        return False

    send_on = email_cfg.get("send_on", "failure")
    if send_on == "always":
        return True
    if send_on == "failure" and failed:
        return True
    return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Automated Windows software updater using winget.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=SCRIPT_DIR / "config.json",
        help="Path to JSON config file (default: config.json in script directory).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List available updates without applying them.",
    )
    email_group = parser.add_mutually_exclusive_group()
    email_group.add_argument(
        "--email",
        action="store_true",
        default=None,
        dest="force_email",
        help="Force sending an email report.",
    )
    email_group.add_argument(
        "--no-email",
        action="store_false",
        dest="force_email",
        help="Suppress email report.",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable DEBUG-level logging.",
    )
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    config = load_config(args.config)
    logger = setup_logging(config, verbose=args.verbose)

    for line in BANNER.strip().splitlines():
        logger.info(line)
    logger.info("")
    logger.info("  Started: %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    logger.info("  Host:    %s", os.environ.get("COMPUTERNAME", "unknown"))
    logger.info("  Config:  %s", args.config)
    logger.info("  Mode:    %s", "DRY RUN" if args.dry_run else "LIVE")

    # Check for updates
    available = check_updates(config, logger)

    succeeded: list[dict] = []
    failed: list[dict] = []

    if available and not args.dry_run:
        succeeded, failed = apply_updates(config, logger)
    elif args.dry_run:
        logger.info("")
        logger.info("  ℹ️  Dry-run mode — skipping update installation.")

    # Email
    email_sent = True
    if should_send_email(config, failed, args.force_email):
        _log_section(logger, "📧  EMAIL REPORT")
        email_sent = send_email(config, available, succeeded, failed, args.dry_run, logger)

    # Summary
    _log_section(logger, "📋  SUMMARY", "━")
    if args.dry_run:
        logger.info("  DRY RUN complete. %d update(s) available.", len(available))
    elif failed:
        logger.warning("  Finished with %d failure(s) and %d success(es).", len(failed), len(succeeded))
    else:
        logger.info("  Finished successfully. %d package(s) updated.", len(succeeded))
    logger.info("")

    if failed:
        return EXIT_PARTIAL_FAILURE
    if args.force_email is True and not email_sent:
        return EXIT_PARTIAL_FAILURE
    return EXIT_SUCCESS


if __name__ == "__main__":
    sys.exit(main())
