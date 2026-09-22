# Zenbook_CS35l41

[![Self-Test CI](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml/badge.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/actions/workflows/selftest.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version: v1.4.0](https://img.shields.io/badge/version-1.4.0-green.svg)](https://github.com/as1furrahman/Zenbook_CS35l41/releases)

**ASUS Zenbook UM5302TA — CS35L41 Speaker Fix** (v1.4.0)

Fixes the Cirrus Logic CS35L41 smart amplifiers failing to probe on cold boot
with `Failed waiting for OTP_BOOT_DONE` (error `-110`) on the ASUS Zenbook
UM5302TA (and similar Rembrandt-generation Zenbooks).

## The problem

On many UM5302TA units the two speaker amps (`i2c-CSC3551:00-cs35l41-hda.0/1`)
fail to probe on cold boot. Transfers to them never complete, the driver's
OTP-boot wait aborts, and the amps stay unbound for the whole boot:

```
i2c_designware AMDI0010:00: controller timed out
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Failed waiting for OTP_BOOT_DONE
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: probe with driver cs35l41-hda failed with error -110
```

This is a **bus-level** failure, not a driver-readiness race: the DesignWare
controller is alive and reporting its own transfer timeout, and it is the amps
that never take part in the transfer. Measured on a real failing boot: 24
timeouts, **all** on the amps' bus (`AMDI0010:00`) and none on the sibling
controller, every transfer exactly ~1.02 s (the adapter's 1 s timeout), two
per amp per probe attempt — and byte-identical across six probe cycles spanning
16 minutes. A module reload cannot clear that, which is why the suspend step,
not a longer retry loop, is what recovers it. See [ROOT-CAUSE.md](ROOT-CAUSE.md).

Result: **no speaker audio** (headphones via the ALC294 codec still work).
The amps and the driver are fine — the *state* has to be cleared with a
suspend/resume boundary, after which both amps bind and load firmware
normally. Check yours with:

```bash
ls -d /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver 2>/dev/null
```

If both paths print, your amps are bound and this script isn't needed.

See [ROOT-CAUSE.md](ROOT-CAUSE.md) for the ACPI/DSDT analysis: the amp rail
has no `_PS0`/`_PS3`/`_PR0` and only the EC firmware can enable it, which is
why a suspend/resume boundary — not a module reload — is the decisive step.

## What the installer does

1. Writes `/usr/local/bin/cs35l41-reload` — a hardened helper that:
   - takes a `flock`; a competing unit waits up to 30 s for it instead of
     skipping on sight, so the units never collide or lose a turn
   - verifies **both** amps are bound; exits if they already are
   - reloads `snd_hda_scodec_cs35l41_i2c` up to 8 times with capped linear
     backoff (~90 s total), **polling** for the driver to bind every 250 ms
     instead of waiting out fixed sleeps
   - `--fallback`: after the retries, one 3-second suspend cycle
     (`rtcwake -m mem`) to power-cycle the amps, then retry
   - watches the kernel log for the clamped-bus signature (`controller timed
     out` on the amps' bus) and, when a power cycle is allowed, stops retrying
     immediately instead of spending the budget on attempts that provably
     cannot succeed — recovery lands at ~45 s instead of ~100 s
   - `--escalate`: same, but only while uptime is under 10 minutes and at
     most once per 3 minutes (the watchdog's self-healing path)
   - exits `2` immediately if the module is in use, so a fix attempt can
     never spin against running audio
2. Installs systemd units:
   - `cs35l41-fix.service` — runs once after boot, with `--fallback`
   - `cs35l41-resume.service` — reloads after suspend/hibernate (`After=suspend.target`,
     which systemd activates *after* the actual sleep, so this really is resume)
   - `cs35l41-watchdog.timer` — safety net: checks every 5 minutes, escalating
     within the boot window as described above — and **started immediately**, not
     merely enabled: `systemctl enable` alone only creates the symlink, which
     would leave the safety net dormant until the next reboot

### Recovery ladder

| Situation | What recovers it |
|---|---|
| Amps bind on a later probe | Boot service / watchdog reloads |
| Clamped bus (the measured failure) | Detected after one attempt → early escalation to the suspend fallback, ~45 s in |
| Rail comes up late, after the retry budget | Boot service `--fallback` suspend |
| Rail still dead after the boot suspend | Watchdog `--escalate` — in practice one extra attempt, ~8 min in, never after 10 min uptime |
| Amps fine already | Helper exits at once, nothing happens |

## Blast radius — what this touches

The fix is deliberately narrow. It touches only the two CS35L41 amp devices:

- **Module reload is limited to `snd_hda_scodec_cs35l41_i2c`** — the I2C glue
  driver for these amps. The ALC294 HDA codec, `snd_hda_intel`, the HDMI/DP
  codecs, PipeWire/WirePlumber/ALSA configuration and the mixer state are all
  untouched; headphones and microphones are on other PCMs and are not
  affected. The only visible side effect is that the *speaker* node may
  briefly disappear from PipeWire while the amp driver rebinds.
- **Nothing is force-unloaded.** Plain `modprobe -r`, which the kernel refuses
  if the module is in use, so a reload can never cut off audio that is playing.
- **No sysfs writes, no `rmmod --force`, no `/etc/modprobe.d` entries**, no
  ALSA/udev/pipewire config, no firmware, no kernel image changes.
- **`systemctl` is only ever asked to enable, disable, start, stop or
  reset-failed the four `cs35l41-*` units**, plus the standard
  `daemon-reload` after writing them. No other units are touched, nothing is
  restarted, and no other service's state is read or changed.
- **Files installed:** the helper (plus a single `cs35l41-reload.bak` kept
  when reinstalling), three units and one timer — nothing else. `--uninstall`
  removes exactly those and resets any failed unit state.
- **Inert on other machines:** the helper exits immediately when neither
  CSC3551 device exists, and all three units carry
  `ConditionPathExists=/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0`, so
  on hardware without these amplifiers the install does nothing at all.
- **The one machine-wide action is the suspend fallback.** `rtcwake -m mem -s 3`
  sleeps the whole system for ~3 s. Anything in flight pauses briefly, and a
  desktop configured to lock on suspend will lock. It happens only on an
  explicit flag, never in a loop: once at boot from the boot service, and from
  the watchdog only while uptime < 10 min, at most once every 3 min. During
  normal operation (amps bound) it never runs at all.

### Safety properties

- Only plain `modprobe`/`modprobe -r` — never `rmmod --force`, no sysfs writes
- `modprobe -r` refuses to unload in-use modules, so running audio can't be interrupted
- Exits without changes if both amps are already bound
- The suspend fallback requires an explicit flag and is gated by uptime and a
  rate limit; a plain watchdog/resume/manual run can only ever reload modules
- Worst case = status quo (amps unbound); the script cannot make things worse

## Install

**One-line install (pinned to release v1.4.0):**

```bash
curl -fsSL https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh | sudo bash
```

**Or download, inspect, and run:**

```bash
curl -fsSL -o speakers.sh https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh
less speakers.sh
sudo bash speakers.sh
```

**Or clone the repository:**

```bash
git clone https://github.com/as1furrahman/Zenbook_CS35l41.git
cd Zenbook_CS35l41
sudo bash speakers.sh
```

If speakers are currently dead, the installer attempts a live fix immediately —
no reboot needed. That attempt can take up to ~2 minutes and may sleep the
machine for ~3 s.

## Usage

```bash
bash speakers.sh --status           # diagnostics table (no root needed)
bash speakers.sh --test             # run self-test suite (no root needed)
sudo bash speakers.sh               # install / upgrade
sudo bash speakers.sh --reinstall   # force fresh install
sudo bash speakers.sh --uninstall   # fully remove everything
bash speakers.sh --help             # full usage
bash speakers.sh --version
```

Or using `make`:

```bash
make test                           # run syntax checks and selftest suite
make status                         # diagnostics table
sudo make install                   # install / upgrade
sudo make reinstall                 # force fresh install
sudo make uninstall                 # fully remove everything
```

`--status` reports hardware detection, amp binding status, the installed helper
version, services and timers, whether the module is loaded, whether `rtcwake` is
available, and when the suspend fallback last ran.

### Exit codes (helper)

| Code | Meaning |
|---|---|
| 0 | Both amps bound, or nothing to do — no CSC3551 hardware, already fixed, or another instance fixed it during lock wait |
| 1 | Could not fix within the full budget, or lock wait timed out with amps still unbound |
| 2 | Refused to act — the module is in use by playing audio |

## Tests & Development

Running developer lint targets (`make test` or `make lint`) requires `shellcheck`:

```bash
sudo apt install shellcheck         # Debian / Ubuntu (optional; developer tooling)
make test                           # runs syntax lint + shellcheck + selftest suite
# or without developer dependencies:
bash tests/helper-selftest.sh       # hermetic sandbox suite; exit 0 = pass
bash speakers.sh --test
```

34 checks. It runs the shipped `scripts/cs35l41-helper.sh` artifact directly
(and verifies byte-for-byte parity with the installer's embedded fallback),
extracts the installer's functions from `speakers.sh`, redirects every path and
timing constant into a sandbox, stubs `modprobe`/`rtcwake`, and asserts:

- a fix is detected — on the first reload, on delayed asynchronous bind, and across the suspend fallback
- it is inert without CSC3551 hardware and when the amps are already bound
- clock skew (backward clock adjust) does not block watchdog escalation
- the suspend fallback never fires without a flag, never mid-session, never
  twice inside the rate limit, and not at all when `rtcwake` is missing
  (that check runs against a sanitised `PATH`, so it cannot reach your real
  `rtcwake` and cannot suspend your machine)
- a failing `rtcwake` is survived without aborting the run
- an in-use module aborts with exit 2 instead of burning the budget
- a competing instance is waited for; lock timeout with unbound amps exits 1,
  while lock timeout where another instance fixed them exits 0
- the status table draws 21-column cells with real ANSI escapes, never
  literal `\033` text
- standalone `scripts/cs35l41-helper.sh` and the installer's embedded copy
  stay strictly in sync
- all service units enforce hardware `ConditionPathExists`
- installer execution ordering guarantees the live fix runs before starting the watchdog
- `--uninstall` cleans up all service units, timers, backups, locks, and stamp files
- nothing it runs reaches the system journal: `logger` is stubbed, and the
  suite aborts if a real one is reachable
- install-path guards for two bugs that shipped: the watchdog is *started*
  (not just enabled), and the live fix uses `restart` (not a no-op `start`)
- a clamped bus short-circuits the retry ladder when a power cycle is allowed,
  and does **not** short-circuit a plain resume/manual run
- pipe execution (`curl | bash` or stdin) correctly normalizes `$PROG` to `speakers.sh`

## Verify / troubleshoot

```bash
bash speakers.sh --status                 # Amp bound row should read YES
journalctl -t cs35l41 -b                  # helper log (tag set by logger -t)
journalctl -u cs35l41-fix -b              # boot service log
aplay -l                                  # speaker PCM on the ALC294 card
```

If a boot still fails:

```bash
sudo systemctl restart cs35l41-fix        # manual retry (restart clears RemainAfterExit state)
sudo modprobe -r snd_hda_scodec_cs35l41_i2c && sudo modprobe snd_hda_scodec_cs35l41_i2c
```

An exit code of `2` in the journal means the module was in use — the helper
deliberately backs off instead of fighting the audio stack.

### Pinning the mechanism further (optional)

The amps are the **only** clients on their bus (`i2c-0` → `AMDI0010:00`), so
rebinding just that controller cannot disturb anything else. On a failing boot,
*after* the script has run and failed and *before* you suspend by hand:

```bash
# the experiment (root; the only action here that changes anything)
echo AMDI0010:00 | sudo tee /sys/bus/platform/drivers/i2c_designware/unbind
echo AMDI0010:00 | sudo tee /sys/bus/platform/drivers/i2c_designware/bind
ls -d /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver 2>/dev/null
```

If the amps bind afterwards, the fault is on the controller side and the
whole-machine suspend could eventually be replaced by a bare controller
rebind. If they still fail, the amp rail/EC explanation in ROOT-CAUSE.md is
confirmed. A failed rebind would leave that bus down until the next reboot,
which is exactly why this is *not* automated in the script.

### What a healthy recovery looks like

Taken from a real cold boot on this laptop — the kernel fails the amps, the
boot service retries, then the suspend fallback recovers both:

```
02:27:40 kernel: cs35l41-hda ...-hda.0: Failed waiting for OTP_BOOT_DONE
02:27:40 kernel: cs35l41-hda ...-hda.0: probe with driver cs35l41-hda failed with error -110
02:27:42 kernel: cs35l41-hda ...-hda.1: probe with driver cs35l41-hda failed with error -110
02:42:41 cs35l41-reload: CS35L41: amps not bound, reloading modules...
02:43:52 cs35l41-reload: CS35L41: trying suspend/resume fallback (machine will sleep ~3s)...
02:43:52 rtcwake: wakeup from "mem" using /dev/rtc0 at ...
02:44:03 cs35l41-reload: CS35L41: fixed after suspend (attempt 1).
02:44:00 kernel: cs35l41-hda ...-hda.0: CS35L41 Bound - SSID: 10431F12, ... CH: L, FW EN: 1
02:44:01 kernel: cs35l41-hda ...-hda.1: CS35L41 Bound - SSID: 10431F12, ... CH: R, FW EN: 1
```

On a *good* boot you instead see the two `CS35L41 Bound` lines right after
boot, `journalctl -t cs35l41 -b` is empty, and `cs35l41-fix` exits silently
because the amps were already up.

## Tested on

Verified on the development machine:

| | |
|---|---|
| Laptop | ASUS Zenbook UM5302TA (`UM5302TA`) |
| BIOS | UM5302TA.313 |
| OS | Ubuntu 26.04.1 LTS |
| Kernel | 7.0.0-31-generic |
| Audio | ALSA + PipeWire (WirePlumber) |
| Amp module | `snd_hda_scodec_cs35l41_i2c` |

Earlier revisions were developed against Arch Linux / Omarchy (kernel
7.1.9-arch1-2). Nothing in the fix is distro-specific — it uses only sysfs i2c
device paths, the module name above, systemd and `rtcwake`.

Other Rembrandt Zenbooks with `CSC3551` ACPI devices likely work too — check
`ls /sys/bus/i2c/devices/ | grep CSC3551` first.

## Notes

- Requires: `bash`, `systemd`, `kmod` (`modprobe`, `modinfo`), and
  `util-linux` for `flock` and `logger` (Debian/Ubuntu: `logger` is in
  `bsdutils`). `rtcwake` (also `util-linux`) is needed only for the suspend
  fallback — `--status` reports whether it is present
- If the amps probe fine on a future kernel/firmware, just `--uninstall`
- Upstream fix: A pure kernel driver retry cannot re-power the dead EC rail
  (see [ROOT-CAUSE.md](ROOT-CAUSE.md)). A permanent vendor fix requires ASUS EC/BIOS
  firmware updates to ensure the amplifier rail is powered at cold boot.

## License

MIT
