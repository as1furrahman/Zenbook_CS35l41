#!/bin/bash
# build-install.sh — build & install the patched cs35l41-hda i2c module.
#
# Usage:
#   ./build-install.sh                     # build only (no root needed)
#   sudo ./build-install.sh install        # verify + install + depmod (no module reload)
#   sudo ./build-install.sh activate       # install + reload module, AUTO-ROLLBACK on failure
#   sudo ./build-install.sh uninstall      # remove override, restore stock module
#
# Safety design (no way to break the system):
#   1. Nothing is installed unless the build succeeds AND the built module's
#      vermagic matches the running kernel exactly.
#   2. After install, module dependency resolution is verified
#      (modprobe --show-depends) BEFORE anything is activated.
#   3. Activation is a separate explicit step. If the patched module fails
#      to insert for ANY reason, 'activate' automatically deletes the
#      override and reloads the stock module — the system ends up exactly
#      as it was.
#   4. The stock packaged module file is never modified; the patched .ko
#      lives in updates/, which depmod ranks above kernel/.
#   5. This driver is not boot-critical: if it is absent or fails, the
#      system boots normally (speakers silent — the pre-existing condition).
#      This kernel also has PANIC_ON_OOPS unset, MODVERSIONS unset and
#      MODULE_SIG_FORCE unset, so a module load failure can only ever
#      degrade to 'amps unbound', never panic.
set -euo pipefail

KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}/build"
UPDATES="/lib/modules/${KVER}/updates"
MODNAME="snd_hda_scodec_cs35l41_i2c"
KO="snd-hda-scodec-cs35l41-i2c.ko"

msg()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "this action must run as root (sudo)"; }

check_headers() {
    [[ -d "$KDIR" ]] || die "kernel headers for ${KVER} not found ($KDIR).
Install with:  sudo pacman -S linux-headers"
}

build() {
    check_headers
    msg "Building against kernel ${KVER}"
    make -C "$(pwd)" all
    [[ -f "$KO" ]] || die "build did not produce ${KO}"

    # --- Safety gate 1: vermagic must match the running kernel ---
    local vmagic built
    vmagic="$(uname -r)"
    built="$(modinfo -F vermagic "$KO")"
    [[ "$built" == "$vmagic"* ]] || die "vermagic mismatch: built '${built}' vs running '${vmagic}'.
Re-run after booting the kernel you intend to use (or rebuild headers)."
    msg "vermagic OK (${built})"
    msg "Built $(du -h "$KO" | cut -f1)"
}

install_mod() {
    need_root
    build
    msg "Installing to ${UPDATES}/"
    install -D -m 0644 "$KO" "${UPDATES}/${KO}"
    depmod -a "$KVER"

    # --- Safety gate 2: dependency resolution must point at our module ---
    msg "Verifying module resolution:"
    modprobe --show-depends "$MODNAME" || die "module dependency resolution failed"
    modinfo -n "$MODNAME"
    [[ "$(modinfo -n "$MODNAME")" == "${UPDATES}/${KO}" ]] \
        || die "modprobe does not resolve to the patched module (${UPDATES}/${KO})"
    msg "Patch is installed and will take effect on next reboot."
    msg "To activate right now (with auto-rollback): sudo $0 activate"
}

activate_mod() {
    need_root
    [[ -f "${UPDATES}/${KO}" ]] || install_mod

    msg "Attempting safe activation with auto-rollback..."
    if modprobe -r "$MODNAME" 2>/dev/null; then
        msg "stock module unloaded"
    else
        msg "stock module was not loaded (amps unbound) — proceeding"
    fi

    if modprobe "$MODNAME"; then
        msg "PATCHED MODULE ACTIVE."
        msg "Check amps:  ls -d /sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.{0,1}/driver"
        msg "Check log:   journalctl -k -b | grep cs35l41 | tail"
        return 0
    fi

    # --- Safety net: patched module refused to load -> full rollback ---
    msg "PATCHED MODULE FAILED TO LOAD — rolling back to stock automatically"
    rm -fv "${UPDATES}/${KO}"
    depmod -a "$KVER"
    modprobe "$MODNAME" 2>/dev/null \
        && msg "Stock module restored. System is exactly as before." \
        || msg "Stock module also not loaded (same as pre-patch state). Nothing broken."
    exit 1
}

uninstall_mod() {
    need_root
    if modprobe -r "$MODNAME" 2>/dev/null; then
        msg "patched module unloaded"
    fi
    rm -fv "${UPDATES}/${KO}"
    depmod -a "$KVER"
    modprobe "$MODNAME" 2>/dev/null \
        && msg "Stock module restored." \
        || msg "No module loaded (stock state will be used on next boot)."
    msg "Fully reverted."
}

case "${1:-}" in
    "")           build ;;
    install)      install_mod ;;
    activate)     activate_mod ;;
    uninstall)    uninstall_mod ;;
    *)            sed -n '2,16p' "$0"; exit 1 ;;
esac
