# ASUS Zenbook UM5302TA — CS35L41 Audio Fix

[![Self-Test CI](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml/badge.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml)
[![Version: v1.4.0](https://img.shields.io/badge/version-1.4.0-green.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Automated speaker fix for ASUS Zenbook UM5302TA laptops running Linux, resolving Cirrus Logic CS35L41 cold-boot amplifier timeouts (`CSC3551`, error `-110`).

For technical root-cause analysis, see [ROOT-CAUSE.md](ROOT-CAUSE.md).

---

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh | sudo bash
```

*Or download and inspect first:*

```bash
curl -fsSL -o speakers.sh https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh && less speakers.sh && sudo bash speakers.sh
```

---

## Usage

```bash
bash speakers.sh --status           # Check hardware & service status
sudo bash speakers.sh               # Install / update fix
sudo bash speakers.sh --reinstall   # Force clean reinstall
sudo bash speakers.sh --uninstall   # Completely remove fix
bash speakers.sh --test             # Run 34-check test suite
```

---

## How It Works

1. **Boot Recovery (`cs35l41-fix.service`)**: Retries amplifier binding at boot with fast polling. If the bus is clamped, cycles power via a brief 3 s suspend fallback.
2. **Resume Hook (`cs35l41-resume.service`)**: Ensures amplifiers rebind cleanly after suspend/hibernate.
3. **Safety Watchdog (`cs35l41-watchdog.timer`)**: Checks binding every 5 minutes during the initial boot window.

---

## Requirements

- **Hardware**: ASUS Zenbook UM5302TA (or Rembrandt laptops with `CSC3551` amps)
- **Software**: Linux kernel 5.19+, systemd, kmod, util-linux (`flock`, `rtcwake`), bash

---

## License

[MIT](LICENSE)
