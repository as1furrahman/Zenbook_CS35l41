# Kernel Patch — CS35L41 probe retry on -ETIMEDOUT

Permanent, in-kernel fix for the boot race that kills the speaker amps on the
ASUS Zenbook UM5302TA:

```
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: Failed waiting for OTP_BOOT_DONE
cs35l41-hda i2c-CSC3551:00-cs35l41-hda.0: probe with driver cs35l41-hda failed with error -110
```

## What it does

Modifies `sound/hda/codecs/side-codecs/cs35l41_hda_i2c.c` only. If
`cs35l41_hda_probe()` fails with `-ETIMEDOUT` (the I2C controller not ready
yet during early boot), the probe is retried with exponential backoff
(250 ms, 500 ms, 1000 ms — 3 retries by default, tunable via the
`probe_retries` module parameter).

This is safe because `cs35l41_hda_probe()` fully releases all resources on
its error path (GPIO descriptors, ACPI reference, allocations) and re-asserts
the amp hardware reset on entry — a retry is a clean, fresh attempt.

No other kernel code, no ABI change, no firmware changes.

## Files

| File | Purpose |
|---|---|
| `0001-cs35l41-hda-i2c-retry-probe-on-ETIMEDOUT.patch` | The patch (against kernel 7.1.9; applies to nearby versions) |
| `cs35l41_hda_i2c.c` | The already-patched driver source (7.1.9) |
| `cs35l41_hda.h` | Driver header needed for the out-of-tree build |
| `Makefile` | Out-of-tree kbuild: produces `snd-hda-scodec-cs35l41-i2c.ko` |
| `build-install.sh` | Build / install / uninstall helper |

## How the override works

The module is built with the **same name** as the in-kernel module
(`snd-hda-scodec-cs35l41-i2c`) and installed to
`/lib/modules/$(uname -r)/updates/` — a directory `depmod` ranks **above**
the stock `kernel/` tree. So the packaged module file is never touched, and
removing one file + `depmod` fully reverts the override.

## Requirements

- `sudo pacman -S linux-headers base-devel` (headers matching your running kernel)
- Kernel: written and verified against **7.1.9**; the source file is identical
  from ~6.4 through current, so nearby versions should work. If `patch`
  reports fuzz/rejects, re-generate against your exact source.

## Install

```bash
cd kernel-patch

./build-install.sh                  # 1. dry build (no root needed)
sudo ./build-install.sh install     # 2. install + depmod
sudo modprobe -r snd_hda_scodec_cs35l41_i2c && sudo modprobe snd_hda_scodec_cs35l41_i2c
# or simply reboot

# verify both amps bound:
ls -d /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver
journalctl -k -b | grep cs35l41     # expect: "Cirrus Logic CS35L41 (...)..." 
```

After this works, the `speakers.sh` reload script becomes unnecessary —
you can uninstall it. (Keeping both is harmless but redundant.)

## Tuning

```bash
echo 'options snd-hda-scodec-cs35l41-i2c probe_retries=5' | sudo tee /etc/modprobe.d/cs35l41-retry.conf
```

## Uninstall / revert

```bash
sudo ./build-install.sh uninstall   # deletes the override, depmod, done
```

## Kernel-upgrade caveat

The override is per-kernel-version (`updates/` lives under
`/lib/modules/<ver>/`). After a kernel update you must rebuild and reinstall
for the new version, or the stock (unpatched) module is used again —
in that case `speakers.sh` is a good interim safety net. Automate with
dkms-style hooks if desired.

## Upstreaming

This is intentionally minimal and upstream-friendly. Consider submitting to
alsa-devel@alsa-project.org (maintainer: Cirrus Logic / Stefan Binding) —
with this merged, no out-of-tree anything would be needed for UM5302TA owners.
