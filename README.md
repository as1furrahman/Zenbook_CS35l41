# ASUS Zenbook UM5302TA — CS35L41 Audio Fix

[![Self-Test CI](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml/badge.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml)
[![Version: v1.4.0](https://img.shields.io/badge/version-1.4.0-green.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

### Automated Speaker Fix & Driver Recovery Daemon for Dual CS35L41 Amplifiers (`CSC3551`)

---

## Overview

### Problem Statement
On cold boot, ASUS Zenbook UM5302TA units frequently encounter ACPI power-rail timeouts (`error -110: Failed waiting for OTP_BOOT_DONE`), leaving the speaker amplifiers unbound while headphones remain functional.

### Architectural Solution
Because the amplifier rail lacks ACPI power management (`_PS0`/`_PR0`) and relies on Embedded Controller (EC) initialization across power transitions, a pure kernel reload cannot reset the state. This project provides a hardened, non-destructive userspace daemon and recovery service that safely restores speaker audio without requiring a manual reboot.

For technical measurements and ACPI/DSDT analysis, see [ROOT-CAUSE.md](ROOT-CAUSE.md).

---

## Installation

### Option 1: One-Line Install (Recommended)

Quick install pinned to release `v1.4.0`:

```bash
curl -fsSL https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh | sudo bash
```

### Option 2: Download, Inspect, and Run

```bash
curl -fsSL -o speakers.sh https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh
less speakers.sh
sudo bash speakers.sh
```

### Option 3: Clone Repository

```bash
git clone https://github.com/as1furrahman/Zenbook_CS35l41.git
cd Zenbook_CS35l41
sudo bash speakers.sh
```

> **Note:** If speakers are dead at installation time, the installer immediately runs a live fix. If bus escalation is needed, the system may briefly sleep for ~3 seconds to power-cycle the amplifier rail.

---

## Usage

### CLI Commands

```bash
bash speakers.sh --status           # View real-time hardware & service diagnostics
bash speakers.sh --test             # Run 34-check hermetic self-test suite
sudo bash speakers.sh               # Install or upgrade services
sudo bash speakers.sh --reinstall   # Perform clean reinstallation
sudo bash speakers.sh --uninstall   # Completely remove helper, services, and timers
bash speakers.sh --help             # Display CLI usage manual
bash speakers.sh --version          # Display script version
```

### Make Targets

```bash
make test                           # Run syntax checks, ShellCheck, and test suite
make status                         # Display diagnostics table
sudo make install                   # Install fix
sudo make reinstall                 # Force clean reinstallation
sudo make uninstall                 # Completely remove fix
```

---

## Architecture & How It Works

The installer sets up three lightweight, hardware-gated systemd units:

1. **`cs35l41-fix.service`**: Triggers at boot. Verifies amplifier binding and performs fast polling reloads. If a clamped bus (`controller timed out`) is detected, it executes an early 3-second `rtcwake` suspend fallback to cycle the amplifier rail.
2. **`cs35l41-resume.service`**: Hooks `suspend.target` to verify amplifiers immediately wake and rebind after normal suspend/resume.
3. **`cs35l41-watchdog.timer`**: Runs every 5 minutes as a background safety net, with a rate-limited escalation window during the first 10 minutes of boot.

### Recovery Escalation Ladder

| Condition | Action Taken | Recovery Time |
|---|---|---|
| **Amps already bound** | No-op; helper exits immediately | 0 s |
| **Normal unbind** | Driver reload with 250ms polling loop | < 2 s |
| **Clamped I2C bus** | Early short-circuit to 3 s `rtcwake` fallback | ~45 s |
| **Active audio playing** | Helper detects in-use module (exit code 2) and defers | Safe backoff |

---

## Safety & Non-Destructive Design

- **Zero Force Operations**: Never uses `rmmod --force` or manual sysfs overrides.
- **Audio Protection**: Uses standard `modprobe -r` which the kernel rejects if audio is streaming, preventing playback disruption.
- **Hardware Isolation**: Reloads only `snd_hda_scodec_cs35l41_i2c`. The Realtek ALC294 codec, headphones, microphones, and HDMI/DP audio streams are untouched.
- **Strictly Scoped Systemd**: All services are guarded with `ConditionPathExists=/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0` to remain inert on unsupported machines.
- **Process Concurrency**: Guarded with `flock` to guarantee multiple units or triggers never race.

---

## Verification & Self-Test

The repository includes a comprehensive, hermetic sandbox test suite:

```bash
# Run developer linting (requires shellcheck)
make lint

# Run full hermetic test suite (34 sandboxed checks)
bash tests/helper-selftest.sh
```

All 34 checks execute inside an isolated sandbox (`.selftest/`) with stubbed device trees, simulated hardware timings, stubbed system logging, and isolated process subshells without modifying host machine state.

---

## Compatibility & Hardware Requirements

- **Supported Models**: ASUS Zenbook S 13 OLED (UM5302TA), Zenbook 14, and related AMD Rembrandt/Barcelo platforms with ACPI hardware ID `CSC3551`.
- **System Requirements**: Linux kernel 5.19+, `systemd`, `kmod` (`modprobe`), `util-linux` (`flock`, `rtcwake`), and `bash`.

---

## License

[MIT](LICENSE)
