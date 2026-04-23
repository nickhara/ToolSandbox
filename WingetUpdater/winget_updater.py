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
    logger.info("Checking for available updates...")
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
        for pkg in packages:
            logger.info(
                "  %-40s  %s -> %s", pkg["id"], pkg["current_version"], pkg["available_version"]
            )
    else:
        logger.info("All packages are up to date.")

    return packages


def apply_updates(config: dict, logger: logging.Logger) -> tuple[list[dict], list[dict]]:
    """Run `winget update --all` and return (succeeded, failed) package lists."""
    logger.info("Applying updates...")

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

    logger.info("Update complete. Succeeded: %d, Failed: %d", len(succeeded), len(failed))

    for s in succeeded:
        logger.info("  OK: %s", s["detail"])
    for f in failed:
        logger.warning("  FAIL: %s", f["detail"])

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

    # Plain text
    lines = [
        f"WingetUpdater Report — {now}",
        f"Host: {hostname}",
        "",
    ]

    if dry_run:
        lines.append("Mode: DRY RUN (no updates applied)")
        lines.append("")

    lines.append(f"Updates available: {len(available)}")
    for pkg in available:
        lines.append(f"  {pkg['id']:40s}  {pkg['current_version']} -> {pkg['available_version']}")

    if not dry_run:
        lines.extend(["", f"Succeeded: {len(succeeded)}"])
        for s in succeeded:
            lines.append(f"  {s['detail']}")
        lines.extend([f"Failed: {len(failed)}"])
        for f in failed:
            lines.append(f"  {f['detail']}")

    plain = "\n".join(lines)

    # HTML
    html_parts = [
        "<html><body>",
        f"<h2>WingetUpdater Report &mdash; {now}</h2>",
        f"<p><strong>Host:</strong> {hostname}</p>",
    ]

    if dry_run:
        html_parts.append("<p><em>Mode: DRY RUN (no updates applied)</em></p>")

    html_parts.append(f"<h3>Updates Available ({len(available)})</h3>")
    if available:
        html_parts.append("<table border='1' cellpadding='4' cellspacing='0'>")
        html_parts.append("<tr><th>Package</th><th>Current</th><th>Available</th></tr>")
        for pkg in available:
            html_parts.append(
                f"<tr><td>{html_mod.escape(pkg['id'])}</td>"
                f"<td>{html_mod.escape(pkg['current_version'])}</td>"
                f"<td>{html_mod.escape(pkg['available_version'])}</td></tr>"
            )
        html_parts.append("</table>")
    else:
        html_parts.append("<p>All packages are up to date.</p>")

    if not dry_run:
        if succeeded:
            html_parts.append(f"<h3>Succeeded ({len(succeeded)})</h3><ul>")
            for s in succeeded:
                html_parts.append(f"<li>{html_mod.escape(s['detail'])}</li>")
            html_parts.append("</ul>")

        if failed:
            html_parts.append(f"<h3 style='color:red'>Failed ({len(failed)})</h3><ul>")
            for f_ in failed:
                html_parts.append(f"<li>{html_mod.escape(f_['detail'])}</li>")
            html_parts.append("</ul>")
        elif not succeeded:
            html_parts.append("<p>No update operations were performed.</p>")

    html_parts.append("</body></html>")
    html = "\n".join(html_parts)

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

    logger.info("=" * 60)
    logger.info("WingetUpdater started at %s", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    logger.info("=" * 60)

    # Check for updates
    available = check_updates(config, logger)

    succeeded: list[dict] = []
    failed: list[dict] = []

    if available and not args.dry_run:
        succeeded, failed = apply_updates(config, logger)
    elif args.dry_run:
        logger.info("Dry-run mode — skipping update installation.")

    # Email
    email_sent = True
    if should_send_email(config, failed, args.force_email):
        email_sent = send_email(config, available, succeeded, failed, args.dry_run, logger)

    # Summary
    logger.info("-" * 60)
    if args.dry_run:
        logger.info("DRY RUN complete. %d update(s) available.", len(available))
    elif failed:
        logger.warning("Finished with %d failure(s) and %d success(es).", len(failed), len(succeeded))
    else:
        logger.info("Finished successfully. %d package(s) updated.", len(succeeded))
    logger.info("=" * 60)

    if failed:
        return EXIT_PARTIAL_FAILURE
    if args.force_email is True and not email_sent:
        return EXIT_PARTIAL_FAILURE
    return EXIT_SUCCESS


if __name__ == "__main__":
    sys.exit(main())
