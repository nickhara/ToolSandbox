# WingetUpdater — Architecture Review Report

> **Date:** 2026-04-23  
> **File reviewed:** `WingetUpdater/winget_updater.py` (692 lines)  
> **Focus:** Design architecture, modern Python best practices, maintainability

---

## Executive Summary

The script is well-organized for a utility script, but it has outgrown the single-file monolith stage. The biggest architectural issues are: **raw `dict` used everywhere for config and domain data**, **business logic coupled to presentation**, and **`sys.exit()` called inside helper functions**. Three high-impact changes would modernize the design substantially.

---

## Findings

### 1. 🔴 HIGH — Raw `dict` config → validated config model

**Current:** `DEFAULT_CONFIG` is a nested dict. `_deep_merge()` merges user JSON into it. All consumers index with string keys like `config["email"]["send_on"]`.

**Problem:** No type safety, no validation, unknown keys silently accepted, typos are runtime errors, IDE autocomplete doesn't work.

**Recommendation:** Create dataclasses (stdlib) or Pydantic models:

```python
@dataclass
class LogConfig:
    file: str = "winget_updater.log"
    max_bytes: int = 5_242_880
    backup_count: int = 5
    level: str = "INFO"

@dataclass
class EmailConfig:
    enabled: bool = False
    send_on: str = "failure"  # or use a StrEnum
    smtp_server: str = ""
    # ...

@dataclass
class WingetConfig:
    accept_source_agreements: bool = True
    accept_package_agreements: bool = True
    exclude_packages: list[str] = field(default_factory=list)
    include_unknown: bool = False

@dataclass
class AppConfig:
    log: LogConfig = field(default_factory=LogConfig)
    email: EmailConfig = field(default_factory=EmailConfig)
    winget: WingetConfig = field(default_factory=WingetConfig)
```

Then `load_config()` returns `AppConfig`, not `dict`.

---

### 2. 🔴 HIGH — Package/result data should be dataclasses, not ad-hoc dicts

**Current:** Available packages are `list[dict]` with keys like `name`, `id`, `current_version`. Results are `list[dict]` with only a `detail` key.

**Problem:** `list[dict]` is effectively `list[Any]`. No IDE support, no static checking, easy to misspell keys.

**Recommendation:**

```python
@dataclass(frozen=True, slots=True)
class PackageUpdate:
    name: str
    id: str
    current_version: str
    available_version: str
    source: str = ""

@dataclass(frozen=True, slots=True)
class UpdateResult:
    detail: str
    success: bool
```

---

### 3. 🔴 HIGH — Separate winget logic from logging/presentation

**Current:** `check_updates()` and `apply_updates()` do everything — invoke winget, parse output, log formatted tables, and return results.

**Problem:** Business logic is tangled with presentation. Can't reuse the winget interaction without also triggering log output. Hard to test.

**Recommendation:** Split into layers:
- **`WingetClient`** — runs subprocess, parses output, returns typed data
- **Orchestrator / service** — calls client, decides what to do
- **Reporter** — formats log output, renders email

```
CLI → Orchestrator → WingetClient (returns PackageUpdate[])
                   → Reporter (logs tables, builds email)
```

---

### 4. 🔴 HIGH — Replace `sys.exit()` in helpers with custom exceptions

**Current:** `load_config()` and `_run_winget()` call `sys.exit()` directly on failure.

**Problem:** Makes functions non-composable and untestable. A caller can't catch the error and recover.

**Recommendation:** Define custom exceptions:

```python
class WingetUpdaterError(Exception): ...
class ConfigLoadError(WingetUpdaterError): ...
class WingetNotFoundError(WingetUpdaterError): ...
class WingetTimeoutError(WingetUpdaterError): ...
```

Only `main()` should catch these and map to exit codes.

---

### 5. 🔴 HIGH — Testability limited by hard-coded side effects

**Current:** Direct calls to `subprocess.run()`, `smtplib.SMTP()`, `datetime.now()`, `os.environ.get()` are scattered throughout.

**Problem:** Unit testing requires mocking at the module level, which is fragile.

**Recommendation:** Encapsulate side effects behind injectable interfaces:
- `WingetClient(runner=subprocess.run)` — swap with a fake in tests
- `EmailSender(smtp_factory=smtplib.SMTP)` — swap with a mock
- Pass `clock` and `hostname` as parameters or via a context object

---

### 6. 🟡 MEDIUM — Logger threaded manually through every function

**Current:** `logger` is passed as a parameter to most functions.

**Problem:** Verbose signatures, easy to forget, doesn't scale to module splits.

**Recommendation:** Two options:
- **Module-level loggers:** `logger = logging.getLogger(__name__)` in each module
- **Class-based:** `self.logger` on service classes

Either approach eliminates the manual threading.

---

### 7. 🟡 MEDIUM — Type hints are structurally incomplete

**Current:** Annotations exist but use bare `dict`, `list[dict]`, `subprocess.CompletedProcess`.

**Problem:** Bare `dict` is effectively `Any`. Static type checkers can't help.

**Recommendation:**
- Replace `dict` → typed config/data models (fixes itself with findings 1 & 2)
- Use `subprocess.CompletedProcess[str]`
- Use `Sequence[str]` where mutation isn't needed
- Use `Literal["always", "failure", "never"]` or `StrEnum` for policy values

---

### 8. 🟡 MEDIUM — Deep-merge config pattern is fragile

**Current:** `_deep_merge()` recursively merges dicts with no validation.

**Problem:** Wrong types, unknown keys, and structural mismatches are all silently accepted.

**Recommendation:** Replace with config model construction. Load JSON, then construct the model with explicit field mapping. Invalid fields raise immediately.

---

### 9. 🟡 MEDIUM — Inline HTML template is too large for string concatenation

**Current:** `_build_email_body()` contains a ~80-line f-string plus loop-based string concatenation.

**Problem:** Hard to read, hard to modify, mixes logic with markup, no syntax highlighting.

**Recommendation:**
- **Preferred:** Move template to a separate `.html` file + use `string.Template` or Jinja2
- **Minimal:** Extract to a separate `email_renderer.py` module with a dedicated class
- Keep the template as a standalone constant if staying single-file

---

### 10. 🟢 LOW — Magic strings and policy values should be enums/constants

**Current:** `"failure"`, `"always"`, `"never"` as raw strings; env var name `"WINGET_UPDATER_SMTP_PASSWORD"` repeated; timeout `1800` as a magic number.

**Recommendation:**

```python
class SendPolicy(StrEnum):
    ALWAYS = "always"
    FAILURE = "failure"
    NEVER = "never"

class ExitCode(IntEnum):
    SUCCESS = 0
    PARTIAL_FAILURE = 1
    CRITICAL_ERROR = 2

SMTP_PASSWORD_ENV_VAR = "WINGET_UPDATER_SMTP_PASSWORD"
WINGET_TIMEOUT_SECONDS = 1800
```

---

## Recommended Module Structure

### Current (monolith)
```
WingetUpdater/
└── winget_updater.py       # 692 lines, 5+ responsibilities
```

### Proposed (modular)
```
WingetUpdater/
├── winget_updater/
│   ├── __init__.py
│   ├── __main__.py          # Entry point (thin)
│   ├── cli.py               # Argument parsing
│   ├── config.py            # Config dataclasses + loading/validation
│   ├── models.py            # PackageUpdate, UpdateResult, enums
│   ├── winget_client.py     # Subprocess interaction + output parsing
│   ├── reporting.py         # ASCII log formatting (banner, tables, sections)
│   ├── email_report.py      # Email rendering (HTML + plain text) + SMTP sending
│   └── templates/
│       └── report.html      # Email HTML template (optional, if using Jinja2)
├── config.sample.json
└── README.md
```

### Minimal split (if full modularization feels heavy)
```
WingetUpdater/
├── winget_updater/
│   ├── __init__.py
│   ├── __main__.py          # CLI + orchestration
│   ├── config.py            # Config models + loading
│   ├── models.py            # Data models + enums
│   ├── winget.py            # Winget subprocess + parsing
│   └── reporting.py         # Log formatting + email rendering/sending
├── config.sample.json
└── README.md
```

---

## Top 3 Changes (If You Only Do Three)

| # | Change | Impact |
|---|---|---|
| 1 | **Typed models** for config and domain data (dataclasses) | Eliminates implicit `Any`, enables IDE support, catches config errors early |
| 2 | **Separate winget client** from reporting/logging | Clean layer boundaries, testable business logic |
| 3 | **Custom exceptions** instead of `sys.exit()` in helpers | Composable, testable, reusable code |

---

*This report is a set of recommendations for review. No changes have been made to the code.*
