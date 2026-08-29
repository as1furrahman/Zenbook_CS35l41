#!/bin/bash
# build-install.sh — build & install the patched cs35l41-hda i2c module.
#
# Usage:
#   ./build-install.sh            # build only (no root needed)
#   sudo ./build-install.sh install   # build + install + depmod (root)
#   sudo ./build-install.sh uninstall # remove override, restore stock module
#
# Safety:
#   - Nothing is installed unless the build succeeds.
#   - The stock packaged module is never modified; the patched .ko goes to
#     updates/ which depmod prefers over kernel/.
#   - Uninstall = delete one file + depmod. Fully reversible.
set -euo pipefail

KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}/build"
UPDATES="/lib/modules/${KVER}/updates"
KO="snd-hda-scodec-cs35l41-i2c.ko"

msg() { printf '%s\n' "==> $*"; }

if [[ ! -d "$KDIR" ]]; then
    echo "ERROR: kernel headers for ${KVER} not found ($KDIR)." >&2
    echo "Install with:  sudo pacman -S linux-headers" >&2
    exit 1
fi

if [[ "${1:-}" == "uninstall" ]]; then
    [[ $EUID -eq 0 ]] || { echo 'uninstall must run as root'; exit 1; }
    rm -fv "${UPDATES}/${KO}"
    depmod -a "$KVER"
    msg "Override removed. Stock module restored on next reboot/reload."
    msg "Reload now:  sudo modprobe -r snd_hda_scodec_cs35l41_i2c && sudo modprobe snd_hda_scodec_cs35l41_i2c"
    exit 0
fi

msg "Building against kernel ${KVER}"
make -C "$(pwd)" all

[[ -f "$KO" ]] || { echo 'ERROR: build did not produce the .ko' >&2; exit 1; }
msg "Built $(du -h "$KO" | cut -f1) ok"

if [[ "${1:-}" == "install" ]]; then
    [[ $EUID -eq 0 ]] || { echo 'install must run as root'; exit 1; }
    msg "Installing to ${UPDATES}/"
    install -D -m 0644 "$KO" "${UPDATES}/${KO}"
    depmod -a "$KVER"
    msg "Verifying override takes precedence:"
    modinfo -n "snd_hda_scodec_cs35l41_i2c"
    cat << 'NOTE'

Installed. Activate it:
  sudo modprobe -r snd_hda_scodec_cs35l41_i2c && sudo modprobe snd_hda_scodec_cs35l41_i2c
(or simply reboot).

Then check:  journalctl -k -b | grep cs35l41
Expect:      "Cirrus Logic CS35L41 ..." and bound drivers in
             /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver

To tune retries without rebuilding:
  echo 'options snd-hda-scodec-cs35l41-i2c probe_retries=5' | sudo tee /etc/modprobe.d/cs35l41-retry.conf

To revert:   sudo ./build-install.sh uninstall
NOTE
else
    msg "Dry build only. Run 'sudo ./build-install.sh install' to install."
fi
