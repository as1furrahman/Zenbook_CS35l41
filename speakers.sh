#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  ASUS Zenbook UM5302TA — CS35L41 Speaker Fix  (v1.2.0)
#
#  Fixes Cirrus Logic CS35L41 amplifiers that fail on cold boot with
#  "Failed waiting for OTP_BOOT_DONE" (error -110).
#
#  Usage:
#    sudo bash speakers.sh               # Install
#    sudo bash speakers.sh --uninstall   # Remove everything
#    sudo bash speakers.sh --status      # Quick diagnostics
#    sudo bash speakers.sh --reinstall   # Force fresh install
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="1.2.0"
AMP="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0"
HELPER="/usr/local/bin/cs35l41-reload"
BOOT_SVC="/etc/systemd/system/cs35l41-fix.service"
RESUME_SVC="/etc/systemd/system/cs35l41-resume.service"
WATCHDOG_SVC="/etc/systemd/system/cs35l41-watchdog.service"
WATCHDOG_TMR="/etc/systemd/system/cs35l41-watchdog.timer"
MODULE="snd_hda_scodec_cs35l41_i2c"

# ── Colors & Styles ──────────────────────────────────────────────────────────
BLK='\033[0;30m'   RED='\033[0;31m'   GRN='\033[0;32m'   YLW='\033[1;33m'
CYN='\033[0;36m'   WHT='\033[1;37m'   BLD='\033[1m'      DIM='\033[2m'
NC='\033[0m'
BG_GRN='\033[42m'  BG_RED='\033[41m'

ok()   { printf "  ${GRN}●${NC}  %b\n" "$*"; }
warn() { printf "  ${YLW}●${NC}  %b\n" "$*"; }
fail() { printf "  ${RED}●${NC}  %b\n" "$*" >&2; }
die()  { fail "$*"; printf "\n"; exit 1; }
step() {
    local label="$1"
    local label_len=${#label}
    local pad=$(( 46 - label_len ))
    local line=""
    for (( i=0; i<pad; i++ )); do line+="─"; done
    printf "\n  ${DIM}├─ ${NC}${BLD}%s${NC}${DIM} %s${NC}\n\n" "$label" "$line"
}

badge() {
    local color="$1" text="$2"
    printf " ${color}${BLK} %s ${NC}" "$text"
}

# ── Banner ───────────────────────────────────────────────────────────────────
banner() {
    printf "\n"
    printf "  ${CYN}${BLD}╔═╗ ╔═╗ ══╗ ╔══ ╦   ╦ ╦  ╦${NC}\n"
    printf "  ${CYN}${BLD}║   ╚═╗  ═╣ ╚═╗ ║   ╚═╣  ║${NC}\n"
    printf "  ${CYN}${BLD}╚═╝ ╚═╝ ══╝ ══╝ ╚═╝   ╩  ╩${NC}\n"
    printf "  ${DIM}Speaker Fix · ASUS Zenbook UM5302TA · v${VERSION}${NC}\n"
}

# ── Root check ───────────────────────────────────────────────────────────────
(( EUID == 0 )) || { printf "\n  ${RED}${BLD}✘${NC}  Run as root: ${WHT}sudo bash %s${NC}\n\n" "$0"; exit 1; }

# ── Status ───────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--status" ]]; then
    banner

    step "DIAGNOSTICS"

    ver=$(grep -oP '(?<=^# Version: ).*' "$HELPER" 2>/dev/null || echo 'not installed')
    amp_ok=$([[ -e "$AMP/driver" ]] && echo "yes" || echo "no")
    boot_st=$(systemctl is-active cs35l41-fix 2>/dev/null || echo "not found")
    resume_st=$(systemctl is-enabled cs35l41-resume 2>/dev/null || echo "not found")
    watchdog_st=$(systemctl is-active cs35l41-watchdog.timer 2>/dev/null || echo "not found")
    mod_ok=$(lsmod | grep -q cs35l41_i2c && echo "yes" || echo "no")

    printf "  ${DIM}┌─────────────────┬───────────────────────┐${NC}\n"
    printf "  ${DIM}│${NC}  ${BLD}Version${NC}        ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$ver"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"

    if [[ "$amp_ok" == "yes" ]]; then
        printf "  ${DIM}│${NC}  Amp bound      ${DIM}│${NC} $(badge "$BG_GRN" "YES")                  ${DIM}│${NC}\n"
    else
        printf "  ${DIM}│${NC}  Amp bound      ${DIM}│${NC} $(badge "$BG_RED" " NO")                  ${DIM}│${NC}\n"
    fi

    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Boot service   ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$boot_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Resume service ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$resume_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Watchdog timer ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$watchdog_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"

    if [[ "$mod_ok" == "yes" ]]; then
        printf "  ${DIM}│${NC}  Module loaded  ${DIM}│${NC} $(badge "$BG_GRN" "YES")                  ${DIM}│${NC}\n"
    else
        printf "  ${DIM}│${NC}  Module loaded  ${DIM}│${NC} $(badge "$BG_RED" " NO")                  ${DIM}│${NC}\n"
    fi

    printf "  ${DIM}└─────────────────┴───────────────────────┘${NC}\n"
    printf "\n"
    exit 0
fi

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    banner
    step "UNINSTALLING"
    systemctl disable --now cs35l41-fix cs35l41-resume cs35l41-watchdog.timer 2>/dev/null || true
    rm -f "$HELPER" "$BOOT_SVC" "$RESUME_SVC" "$WATCHDOG_SVC" "$WATCHDOG_TMR" /var/lock/cs35l41-reload.lock
    systemctl daemon-reload
    ok "Services disabled and removed"
    ok "Helper script removed"
    printf "\n  ${GRN}${BLD}✓  Fully uninstalled.${NC}\n\n"
    exit 0
fi

# ── Reinstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--reinstall" ]]; then
    systemctl stop cs35l41-fix cs35l41-resume cs35l41-watchdog.timer 2>/dev/null || true
    warn "Forcing fresh install..."
elif [[ -n "${1:-}" ]]; then
    die "Unknown option: $1\n\n  Usage:\n    sudo bash $(basename "$0")               # Install\n    sudo bash $(basename "$0") --uninstall   # Remove\n    sudo bash $(basename "$0") --status      # Diagnostics\n    sudo bash $(basename "$0") --reinstall   # Reinstall"
fi

# ── Install ──────────────────────────────────────────────────────────────────
banner

step "PREFLIGHT CHECKS"
[[ -d "$AMP" ]] || die "CS35L41 amplifier not found. Wrong machine?"
ok "Hardware detected"

modinfo "$MODULE" &>/dev/null || die "Kernel module '${MODULE}' not found."
ok "Kernel module available"

step "INSTALLING COMPONENTS"

# ── 1. Helper script ────────────────────────────────────────────────────────
if [[ -f "$HELPER" ]]; then
    cp --backup=numbered "$HELPER" "${HELPER}.old" 2>/dev/null || true
fi

cat > "$HELPER" << 'EOF'
#!/bin/bash
# Version: 1.2.0
# CS35L41 module reload helper — used by systemd services.
# Usage: cs35l41-reload [--fallback]
set -euo pipefail

AMP="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0/driver"
LOCK="/var/lock/cs35l41-reload.lock"

# ── Concurrency lock ──
exec 9>"$LOCK"
flock -n 9 || { echo "CS35L41: another instance running, skipping."; exit 0; }

# ── Already working? ──
[[ -e "$AMP" ]] && { echo "CS35L41: already bound."; exit 0; }

reload() {
    modprobe -r snd_hda_scodec_cs35l41_i2c snd_hda_scodec_cs35l41 2>/dev/null || true
    sleep 2
    modprobe snd_hda_scodec_cs35l41_i2c
    sleep 2
}

log() { echo "CS35L41: $*"; logger -t cs35l41 "$*" 2>/dev/null || true; }

# ── Retry loop (5 attempts with backoff) ──
log "amps not bound, reloading modules..."
for i in 1 2 3 4 5; do
    reload
    if [[ -e "$AMP" ]]; then
        log "fixed (attempt $i)."
        exit 0
    fi
    backoff=$(( i * 2 ))
    log "attempt $i failed, retrying in ${backoff}s..."
    sleep "$backoff"
done

# ── Suspend fallback (boot only) ──
if [[ "${1:-}" != "--fallback" ]]; then
    log "reload failed after 5 attempts."
    exit 1
fi

if ! command -v rtcwake &>/dev/null; then
    log "rtcwake not found, cannot try suspend fallback."
    exit 1
fi

log "trying suspend/resume fallback..."
rtcwake -m mem -s 3 2>/dev/null || true
sleep 1

for i in 1 2 3; do
    reload
    if [[ -e "$AMP" ]]; then
        log "fixed after suspend (attempt $i)."
        exit 0
    fi
done

log "all attempts failed." >&2
exit 1
EOF
chmod 755 "$HELPER"
ok "Helper script  →  ${DIM}${HELPER}${NC}"

# ── 2. Boot service ─────────────────────────────────────────────────────────
cat > "$BOOT_SVC" << 'EOF'
[Unit]
Description=CS35L41 speaker fix (boot) v1.2.0
After=sound.target multi-user.target
Wants=sound.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/usr/local/bin/cs35l41-reload --fallback
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
ok "Boot service   →  ${DIM}${BOOT_SVC}${NC}"

# ── 3. Resume service ───────────────────────────────────────────────────────
cat > "$RESUME_SVC" << 'EOF'
[Unit]
Description=CS35L41 speaker fix (resume) v1.2.0
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/cs35l41-reload

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target
EOF
ok "Resume service →  ${DIM}${RESUME_SVC}${NC}"

# ── 4. Watchdog timer (safety net) ──────────────────────────────────────────
cat > "$WATCHDOG_SVC" << 'EOF'
[Unit]
Description=CS35L41 speaker watchdog v1.2.0

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs35l41-reload
EOF

cat > "$WATCHDOG_TMR" << 'EOF'
[Unit]
Description=CS35L41 speaker watchdog timer v1.2.0

[Timer]
OnBootSec=90
OnBootSec=180

[Install]
WantedBy=timers.target
EOF
ok "Watchdog timer →  ${DIM}${WATCHDOG_TMR}${NC}"

step "ACTIVATING"

systemctl daemon-reload
systemctl enable cs35l41-fix cs35l41-resume cs35l41-watchdog.timer --quiet
ok "Services & watchdog enabled"

if [[ ! -e "$AMP/driver" ]]; then
    warn "Speakers not working — attempting live fix..."
    printf "  ${DIM}   (this may take a moment)${NC}\n"
    if systemctl start cs35l41-fix 2>/dev/null && [[ -e "$AMP/driver" ]]; then
        ok "Speakers fixed!"
    else
        warn "Couldn't fix live — reboot to apply"
    fi
else
    ok "Speakers already working"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
printf "\n"
printf "  ${GRN}${BLD}╭──────────────────────────────────────────────────╮${NC}\n"
printf "  ${GRN}${BLD}│${NC}                                                  ${GRN}${BLD}│${NC}\n"
printf "  ${GRN}${BLD}│${NC}   ${GRN}${BLD}Installed successfully!${NC}                        ${GRN}${BLD}│${NC}\n"
printf "  ${GRN}${BLD}│${NC}   ${DIM}Runs automatically on boot and after suspend.${NC}  ${GRN}${BLD}│${NC}\n"
printf "  ${GRN}${BLD}│${NC}                                                  ${GRN}${BLD}│${NC}\n"
printf "  ${GRN}${BLD}╰──────────────────────────────────────────────────╯${NC}\n"
printf "  ${DIM}──────────────────────────────────────────────────${NC}\n"
printf "\n"
printf "  ${BLD}Quick Reference${NC}\n"
printf "\n"
printf "  ${WHT}Status${NC}       ${CYN}sudo bash %s --status${NC}\n" "$(basename "$0")"
printf "  ${WHT}Reinstall${NC}    ${CYN}sudo bash %s --reinstall${NC}\n" "$(basename "$0")"
printf "  ${WHT}Uninstall${NC}    ${CYN}sudo bash %s --uninstall${NC}\n" "$(basename "$0")"
printf "\n"
printf "  ${WHT}Service${NC}      ${CYN}systemctl status cs35l41-fix${NC}\n"
printf "  ${WHT}Journal${NC}      ${CYN}journalctl -u cs35l41-fix -b${NC}\n"
printf "\n"
