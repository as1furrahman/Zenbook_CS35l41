# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Note**: Git release tags (`v1.2.0`, `v1.2.1`, `v1.3.0`, `v1.3.1`, `v1.4.0`) map directly to releases in this changelog. Releases v1.0.0 through v1.1.0 document historical development prior to the repository's initial git commit.

## [1.4.0] - 2026-09-23

### Added
- **Hardware detection**: Added a dedicated `Hardware` row to `speakers.sh --status` diagnostics table to explicitly check and report CSC3551 presence.
- **CLI test flag**: Added `--test` / `--selftest` flags to `speakers.sh` with `SCRIPT_DIR` path resolution to dispatch the self-test suite directly.
- **Automated CI**: Added GitHub Actions workflow (`.github/workflows/selftest.yml`) running syntax validation, CLI flag checks, and the full hermetic test suite on Ubuntu.
- **Developer tooling**: Added `Makefile` (`lint`, `test`, `ci`, `status`, `install`, `reinstall`, `uninstall`, `clean`) and `.gitignore`.
- **Clock skew test**: Added test coverage validating that future timestamps (e.g. backward NTP clock sync across suspend) do not block watchdog escalation.
- **Lock recovery test**: Added test coverage validating that lock timeouts with bound amplifiers exit `0`.

### Changed
- **Lock timeout contract**: Fixed false-positive initial lock timeout in `cs35l41-reload`. If the 30-second lock wait expires and amplifiers remain unbound, the helper now exits `1` (failure) so systemd accurately registers unit failure, rather than falsely claiming success. If another instance resolved the amplifiers during the wait, it exits `0`.
- **Clock skew protection**: In `--escalate`, guarded the interval check with `(( age >= 0 && age < ESCALATE_INTERVAL ))` to prevent negative timestamps from locking out the watchdog safety net.
- **Process isolation in tests**: Replaced background `flock -c` commands in `tests/helper-selftest.sh` with subshell file descriptor locks (`exec 8>...; flock 8`) to eliminate orphaned background `sleep` processes.
- **Status diagnostics**: Added detection and warnings for failed resume service reloads (`systemctl is-failed cs35l41-resume`).
- **Defensive cell padding**: Hardened `cell()` badge rendering with non-negative padding guards.
- **README documentation**: Updated troubleshooting recommendations to use `systemctl restart cs35l41-fix` (avoiding no-ops on `RemainAfterExit=yes` units) and aligned root-cause notes with ACPI/EC analysis in `ROOT-CAUSE.md`.

### Fixed
- Added exit trap `trap 'exec 9>&- 2>/dev/null || true' EXIT` in `cs35l41-reload` to guarantee file descriptor 9 is closed on all termination paths.
- Guarded `sed` version extraction in `speakers.sh --status` to avoid `pipefail` crashes on fresh systems where the helper script has not yet been installed.

## [1.3.1] - 2026-08-30

### Fixed
- Started the watchdog timer immediately (`systemctl enable --now cs35l41-watchdog.timer`) so the safety net is active in the running session without requiring a reboot.
- Live fix switched from `systemctl start` to `systemctl restart cs35l41-fix` because `RemainAfterExit=yes` left previous runs "active".
- Diagnostics table now flags enabled-but-inactive watchdog timers and failed boot services.
- Test suite stubs `logger` to avoid polluting the system journal.

## [1.3.0] - 2026-08-28

### Added
- Watchdog escalation (`--escalate`): runs suspend/resume power-cycle if reloads fail, rate-limited to once per 3 minutes and restricted to the first 10 minutes of uptime.
- Fast polling (`wait_bound()`): polls driver bind status every 250ms up to 5 seconds instead of blind sleeps.
- Clamped-bus early short-circuit: monitors kernel log for `controller timed out` on `AMDI0010:00` and escalates immediately to suspend fallback.

### Changed
- Increased retry budget from 5 attempts (~30s) to 8 attempts with capped linear backoff (~90s).
- Competing instances now wait up to 30s for the concurrency lock instead of skipping on sight.
- Concurrency lock is released across `rtcwake` so `cs35l41-resume.service` can reload immediately on wake.
- In-use module detection: aborts immediately with exit code `2` if audio is playing (`modprobe -r` refused).
- Status, help, and version commands no longer require root privileges.

## [1.2.1] - 2026-08-25

### Fixed
- Verified dual amplifiers (`.0` and `.1`) across helper, status, and live fix; partial binds no longer register as fixed.
- Corrected watchdog timer `OnBootSec=90` and `OnUnitActiveSec=300`.
- Handled modprobe insertion failures without aborting the retry loop.
- Uninstall command stops and cleans `cs35l41-watchdog.service`.

## [1.1.0] - 2026-08-20

### Added
- Added suspend/resume fallback (`rtcwake -m mem -s 3`) when pure module reloads fail.
- Added `cs35l41-resume.service` ordered `After=suspend.target`.

## [1.0.0] - 2026-08-15

### Added
- Initial release: basic reload script and `cs35l41-fix.service` for ASUS Zenbook UM5302TA.
