# Zenbook_CS35l41

**ASUS Zenbook UM5302TA — CS35L41 Speaker Fix** (v1.2.1)

Fixes the Cirrus Logic CS35L41 smart amplifiers failing to probe on cold boot
with `Failed waiting for OTP_BOOT_DONE` (error `-110`) on the ASUS Zenbook
UM5302TA (and similar Rembrandt-generation Zenbooks).

## The problem

On many UM5302TA units, the two speaker amps (`i2c-CSC3551:00-cs35l41-hda.0/1`)
are probed by the kernel before the DesignWare I2C controller (`AMDI0010`) is
ready. The probe times out permanently for that boot:

```
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Failed waiting for OTP_BOOT_DONE
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: probe with driver cs35l41-hda failed with error -110
```

Result: **no speaker audio** (headphones via the ALC294 codec still work).
The amps themselves are fine — re-probing the module after boot succeeds.
Check yours with:

```bash
ls -d /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver 2>/dev/null
```

If both paths print, your amps are bound and this script isn't needed.

## What the installer does

1. Writes `/usr/local/bin/cs35l41-reload` — a hardened helper that:
   - takes a `flock` (no concurrent reloads)
   - verifies **both** amps are bound; exits if they already are
   - reloads `snd_hda_scodec_cs35l41_i2c` with 5 retries + backoff
   - optional `--fallback`: after 5 failed attempts, does a 3-second
     suspend cycle (`rtcwake -m mem`) to power-cycle the amps, then retries
2. Installs systemd units:
   - `cs35l41-fix.service` — runs once after boot
   - `cs35l41-resume.service` — runs after suspend/hibernate
   - `cs35l41-watchdog.timer` — safety net: checks every 5 minutes

### Safety properties

- Only plain `modprobe`/`modprobe -r` — never `rmmod --force`, no sysfs writes
- `modprobe -r` refuses to unload in-use modules, so running audio can't be interrupted
- Exits without changes if amps are already (even partially) bound
- Worst case = status quo (amps unbound); the script cannot make things worse

## Install

```bash
git clone https://github.com/as1furrahman/Zenbook_CS35l41.git
cd Zenbook_CS35l41
sudo bash speakers.sh
```

If speakers are currently dead, the installer attempts a live fix immediately —
no reboot needed.

## Usage

```bash
sudo bash speakers.sh --status      # diagnostics table
sudo bash speakers.sh --reinstall   # force fresh install
sudo bash speakers.sh --uninstall   # fully remove everything
```

## Verify / troubleshoot

```bash
sudo bash speakers.sh --status            # "Amp bound: YES" for both amps
journalctl -t cs35l41 -b                  # helper log
journalctl -u cs35l41-fix -b              # boot service log
aplay -l                                  # speaker PCM on the ALC294 card
```

If a boot still fails:

```bash
systemctl start cs35l41-fix               # manual retry
sudo modprobe -r snd_hda_scodec_cs35l41_i2c && sudo modprobe snd_hda_scodec_cs35l41_i2c
```

## Tested on

- ASUS Zenbook UM5302TA (BIOS UM5302TA.313), Omarchy / Arch Linux,
  kernel 7.1.9-arch1-2, ALSA + PipeWire

Other Rembrandt Zenbooks with `CSC3551` ACPI devices likely work too —
check `ls /sys/bus/i2c/devices/ | grep CSC3551` first.

## Notes

- Requires: `bash`, `systemd`, `kmod`, `util-linux` (`flock`), optionally
  `util-linux`'s `rtcwake` for the suspend fallback
- If the amps probe fine on a future kernel/firmware, just `--uninstall`
- Upstream-worthy fix: a probe-retry in the kernel driver — consider reporting
  at [bugzilla.kernel.org](https://bugzilla.kernel.org) so this gets fixed
  for everyone

## License

MIT
