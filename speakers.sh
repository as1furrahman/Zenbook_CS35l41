#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 as1furrahman
# ──────────────────────────────────────────────────────────────────────────────
#  ASUS Zenbook UM5302TA — CS35L41 Speaker Fix  (v1.4.0)
#
#  Fixes the Cirrus Logic CS35L41 speaker amplifiers failing to probe on cold
#  boot with "Failed waiting for OTP_BOOT_DONE" (error -110).
#
#  Scope — this tool touches only the two CS35L41 amplifiers:
#    * the only kernel module it ever unloads/reloads is
#      snd_hda_scodec_cs35l41_i2c (via plain modprobe -r, which the kernel
#      refuses whenever it is in use, so playing audio is never cut off);
#    * no sysfs writes, no rmmod --force, no modprobe.d/ALSA/PipeWire/udev
#      config, no firmware, no kernel or bootloader changes;
#    * the only files written are the helper and the systemd units listed by
#      --help, plus /run state that the kernel clears on every boot;
#    * it is inert on any machine without the CSC3551 devices: the helper
#      exits immediately and each unit carries ConditionPathExists.
#  The single whole-machine action is a deliberate ~3 s suspend/resume cycle,
#  used only when a module reload cannot fix it (see ROOT-CAUSE.md).
#
#  v1.4.0 (lock contract, clock skew, diagnostics & tooling):
#   - Fixed false-positive initial lock timeout: if flock wait expires with
#     amps unbound, exit 1 instead of claiming success to systemd; exit 0 only
#     if another instance fixed the amplifiers.
#   - Guarded escalate rate limiter against clock skew (( age >= 0 )).
#   - Added trap on exit to close file descriptor 9 and prevent leaks.
#   - Diagnostics status table now includes Hardware detection row and
#     flags failed resume service reloads.
#   - Added --test CLI flag to dispatch the self-test suite directly.
#   - Added Makefile and .gitignore for developer workflow and CI.
#   - Expanded self-test suite to 28 checks with subshell FD locking.
#
#  v1.3.1 (install-path fixes, found by checking the live system):
#   - The installer now *starts* the watchdog timer, not merely enables it.
#     `systemctl enable` only creates the symlink, so installing in a running
#     session left the safety net dormant — verified: on a real install the
#     timer had never run once, 52 minutes later. It is started last, after
#     the live fix, so it cannot race the boot service into a second suspend.
#   - The live fix uses `systemctl restart`, not `start`. The boot unit is
#     RemainAfterExit=yes, so after a successful boot run it stays "active"
#     and a plain `start` silently does nothing.
#   - --status now flags an enabled-but-inactive watchdog timer and a failed
#     boot service, instead of showing a bare "inactive"/"failed".
#   - The test suite stubs `logger`, so sandbox runs no longer write into the
#     system journal (they used to leave cs35l41-tagged noise in the exact log
#     command the troubleshooting docs tell you to read).
#
#  v1.3.0 (fix-rate + hardening pass — this script is the only recovery path):
#   - Reload budget raised from 5 hasty attempts (~30 s) to 8 attempts with
#     capped linear backoff (~90 s), and success is *polled* (every 250 ms,
#     up to 5 s) instead of blind 2 s sleeps: a fix is detected in well under
#     a second, and a failed attempt no longer wastes a flat 4 s.
#   - The watchdog can now escalate: if the reload budget fails it runs the
#     suspend/resume power cycle itself. Bounded twice over — only while
#     uptime < 10 min (a boot-time recovery; never power-cycles a machine
#     someone is using) and at most once per 3 min. In practice that allows a
#     single watchdog escalation, around the 8-minute mark, after the boot
#     service's own attempt.
#   - The reload lock is released across the suspend cycle so
#     cs35l41-resume.service can reload modules the instant the kernel comes
#     back. Previously its helper was silently skipped ("another instance
#     running") for the whole boot window.
#   - Competing instances now *wait* up to 30 s for the lock instead of
#     skipping immediately, and the helper takes no lock at all when the amps
#     are already bound.
#   - If modprobe -r refuses because the module is in use (audio playing),
#     the helper aborts with exit 2 instead of burning all 8 attempts
#     pretending to retry.
#   - Unloads only snd_hda_scodec_cs35l41_i2c. Also unloading the shared base
#     module could fail and abort the entire unload, leaving the stale module
#     still loaded.
#   - --status/--help/--version no longer require root; the status table
#     reports the suspend tool and the last fallback, and its rows align.
#
#  v1.2.1 fixes (review pass):
#   - Helper + status + live-fix now verify BOTH amps (.0 and .1),
#     not just amp 0 (partial bind previously counted as "fixed").
#   - Watchdog timer: duplicate OnBootSec keys collapse to one run;
#     now OnBootSec=90 + OnUnitActiveSec=300 (repeats every 5 min).
#   - Helper: modprobe insert failure no longer aborts via set -e
#     mid-retry-loop; it is treated as a failed attempt instead.
#   - Uninstall also stops cs35l41-watchdog.service.
#
#  NOTE: when 8 module reloads fail, the machine sleeps for ~3 s
#  (rtcwake -m mem) — once at boot, and from the watchdog at most once per
#  3 min while uptime is under 10 minutes. This is intentional: the EC only
#  re-initialises the amp rail across a suspend/resume boundary. It looks
#  like a brief freeze, and a desktop configured to lock on suspend will
#  lock the screen.
#
#  Usage:
#    sudo bash speakers.sh               # Install
#    sudo bash speakers.sh --status      # Diagnostics (no root required)
#    sudo bash speakers.sh --help        # Full usage
#    sudo bash speakers.sh --reinstall   # Force fresh install
#    sudo bash speakers.sh --uninstall   # Remove everything
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="1.4.0"
PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Hardware ─────────────────────────────────────────────────────────────────
DEV0="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0"
DEV1="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.1"
AMP0="$DEV0/driver"
AMP1="$DEV1/driver"
MODULE="snd_hda_scodec_cs35l41_i2c"

# ── Files this tool owns (nothing else is ever written) ──────────────────────
HELPER="/usr/local/bin/cs35l41-reload"
BOOT_SVC="/etc/systemd/system/cs35l41-fix.service"
RESUME_SVC="/etc/systemd/system/cs35l41-resume.service"
WATCHDOG_SVC="/etc/systemd/system/cs35l41-watchdog.service"
WATCHDOG_TMR="/etc/systemd/system/cs35l41-watchdog.timer"
STAMP="/run/cs35l41-suspended"
LOCK="/run/lock/cs35l41-reload.lock"

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
    local pad=$(( 46 - ${#1} ))
    local line=""
    for (( i=0; i<pad; i++ )); do line+="─"; done
    printf "\n  ${DIM}├─ ${NC}${BLD}%s${NC}${DIM} %s${NC}\n\n" "$label" "$line"
}

# Status-table cell: a highlighted badge padded to exactly 21 visible columns,
# so it lines up with the plain "%-21s" rows.
# Colours must go in the printf *format* string: printf expands \033 there, but
# not when the value is passed as an argument. cell() is covered by tests/.
cell() {
    local color="$1" text="$2"
    local pad=$(( 21 - ${#text} - 2 ))
    (( pad > 0 )) || pad=0
    printf "${color}${BLK} %s ${NC}" "$text"
    printf '%*s' "$pad" ''
}

# ── Banner ───────────────────────────────────────────────────────────────────
banner() {
    printf "\n"
    printf "  ${CYN}${BLD}╔═╗ ╔═╗ ══╗ ╔══ ╦   ╦ ╦  ╦${NC}\n"
    printf "  ${CYN}${BLD}║   ╚═╗  ═╣ ╚═╗ ║   ╚═╣  ║${NC}\n"
    printf "  ${CYN}${BLD}╚═╝ ╚═╝ ══╝ ══╝ ╚═╝   ╩  ╩${NC}\n"
    printf "  ${DIM}Speaker Fix · ASUS Zenbook UM5302TA · v${VERSION}${NC}\n"
}

# Colours live in the printf format strings throughout: printf expands \033
# there, but never in an argument (and `cat` expands nothing at all).
usage() {
    printf '\n'
    printf "  ${BLD}Usage${NC}  sudo bash %s [option]\n\n" "$PROG"
    printf "    ${WHT}(none)${NC}         Install the fix\n"
    printf "    ${WHT}--status${NC}       Diagnostics table (no root required)\n"
    printf "    ${WHT}--reinstall${NC}    Force a fresh install over an existing one\n"
    printf "    ${WHT}--uninstall${NC}    Stop and remove everything this installed\n"
    printf "    ${WHT}--help${NC}         Show this text\n"
    printf "    ${WHT}--version${NC}      Show the version\n"
    printf "    ${WHT}--test${NC}         Run the self-test suite (no root required)\n"
    printf '\n'
    printf "  ${BLD}Files installed${NC}\n"
    printf '    %s\n' "$HELPER" "$BOOT_SVC" "$RESUME_SVC" "$WATCHDOG_SVC" "$WATCHDOG_TMR"
    printf '\n'
    printf "  ${BLD}Runtime state${NC} ${DIM}(/run is tmpfs — cleared on every boot)${NC}\n"
    printf '    %-29s  %s\n' "$LOCK" "serialises reload attempts"
    printf '    %-29s  %s\n' "$STAMP" "timestamp of the last suspend fallback"
    printf '\n'
}

need_root() {
    (( EUID == 0 )) || die "This action must run as root:  sudo bash ${PROG}"
}

# ── Status ───────────────────────────────────────────────────────────────────
status() {
    banner
    step "DIAGNOSTICS"

    local ver amp0_ok amp1_ok amp_ok boot_st resume_st resume_fail mod_ok
    local watchdog_st watchdog_en fb_stamp fallback_st suspend_tool hw_ok

    ver="$(sed -n 's/^# Version: //p' "$HELPER" 2>/dev/null | head -n1)"
    [[ -n "$ver" ]] || ver="not installed"

    hw_ok=$([[ -d "$DEV0" && -d "$DEV1" ]] && echo yes || echo no)
    amp0_ok=$([[ -e "$AMP0" ]] && echo yes || echo no)
    amp1_ok=$([[ -e "$AMP1" ]] && echo yes || echo no)
    amp_ok=$([[ "$amp0_ok" == yes && "$amp1_ok" == yes ]] && echo yes || echo no)
    if [[ -f "$BOOT_SVC" ]]; then
        boot_st="$(systemctl is-active cs35l41-fix 2>/dev/null || true)"
    else
        boot_st="not found"
    fi
    if [[ -f "$RESUME_SVC" ]]; then
        resume_st="$(systemctl is-enabled cs35l41-resume 2>/dev/null || true)"
        resume_fail="$(systemctl is-failed cs35l41-resume 2>/dev/null || true)"
    else
        resume_st="not found"
        resume_fail=""
    fi
    if [[ -f "$WATCHDOG_TMR" ]]; then
        watchdog_st="$(systemctl is-active cs35l41-watchdog.timer 2>/dev/null || true)"
        watchdog_en="$(systemctl is-enabled cs35l41-watchdog.timer 2>/dev/null || true)"
    else
        watchdog_st="not found"
        watchdog_en="not found"
    fi
    if grep -q "^${MODULE} " /proc/modules 2>/dev/null; then mod_ok=yes; else mod_ok=no; fi

    if command -v rtcwake >/dev/null 2>&1; then
        suspend_tool="rtcwake"
    else
        suspend_tool="missing"
    fi

    fb_stamp="$(cat "$STAMP" 2>/dev/null || true)"
    if [[ "$fb_stamp" =~ ^[0-9]+$ ]]; then
        fallback_st="$(date -d "@$fb_stamp" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$fb_stamp")"
    else
        fallback_st="never this boot"
    fi

    printf "  ${DIM}┌─────────────────┬───────────────────────┐${NC}\n"
    printf "  ${DIM}│${NC}  ${BLD}Version${NC}        ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$ver"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    if [[ "$hw_ok" == yes ]]; then
        printf "  ${DIM}│${NC}  Hardware       ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_GRN" "YES")"
    else
        printf "  ${DIM}│${NC}  Hardware       ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_RED" "NO")"
    fi
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    if [[ "$amp_ok" == yes ]]; then
        printf "  ${DIM}│${NC}  Amp bound      ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_GRN" "YES")"
    else
        printf "  ${DIM}│${NC}  Amp bound      ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_RED" "NO")"
    fi
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Boot service   ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$boot_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Resume service ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$resume_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Watchdog timer ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$watchdog_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Suspend tool   ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$suspend_tool"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    printf "  ${DIM}│${NC}  Last fallback  ${DIM}│${NC}  %-21s ${DIM}│${NC}\n" "$fallback_st"
    printf "  ${DIM}├─────────────────┼───────────────────────┤${NC}\n"
    if [[ "$mod_ok" == yes ]]; then
        printf "  ${DIM}│${NC}  Module loaded  ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_GRN" "YES")"
    else
        printf "  ${DIM}│${NC}  Module loaded  ${DIM}│${NC}  %s ${DIM}│${NC}\n" "$(cell "$BG_RED" "NO")"
    fi
    printf "  ${DIM}└─────────────────┴───────────────────────┘${NC}\n\n"

    if [[ "$hw_ok" != yes ]]; then
        printf "  ${YLW}CSC3551 amplifier devices not found — wrong machine?${NC}\n\n"
    fi

    if [[ "$amp_ok" != yes ]]; then
        printf "  ${DIM}per-amp bind: .0=%s  .1=%s${NC}\n" "$amp0_ok" "$amp1_ok"
        printf "  ${DIM}both must be bound; a partial bind still means no speakers.${NC}\n\n"
    fi

    if [[ "$suspend_tool" == missing ]]; then
        printf "  ${YLW}rtcwake is missing — the suspend fallback cannot run.${NC}\n"
        printf "  ${DIM}Install util-linux, or the fix is limited to module reloads.${NC}\n\n"
    fi

    if [[ "$watchdog_st" == inactive && "$watchdog_en" == enabled ]]; then
        printf "  ${YLW}watchdog timer is enabled but not running — the retry safety net is off.${NC}\n"
        printf "  ${DIM}Start it now:  systemctl start cs35l41-watchdog.timer${NC}\n\n"
    fi

    if [[ "$boot_st" == failed ]]; then
        printf "  ${YLW}boot service failed this boot — journalctl -u cs35l41-fix -b${NC}\n\n"
    fi

    if [[ "${resume_fail:-}" == failed ]]; then
        printf "  ${YLW}last resume reload failed — journalctl -u cs35l41-resume${NC}\n\n"
    fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help)    banner; usage; exit 0 ;;
    -V|--version)     printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --status)         status; exit 0 ;;
    --test|--selftest) exec bash "$SCRIPT_DIR/tests/helper-selftest.sh" ;;
    "")               ;;
    --reinstall)  need_root; systemctl stop cs35l41-fix cs35l41-resume \
                      cs35l41-watchdog.timer cs35l41-watchdog.service 2>/dev/null || true
                  warn "Forcing fresh install..." ;;
    --uninstall)  need_root
                  banner
                  step "UNINSTALLING"
                  systemctl disable --now cs35l41-fix cs35l41-resume \
                      cs35l41-watchdog.timer cs35l41-watchdog.service 2>/dev/null || true
                  systemctl reset-failed cs35l41-fix cs35l41-resume \
                      cs35l41-watchdog.service 2>/dev/null || true
                  rm -f "$HELPER" "${HELPER}.bak" "${HELPER}".old* \
                        "$BOOT_SVC" "$RESUME_SVC" "$WATCHDOG_SVC" "$WATCHDOG_TMR" \
                        "$LOCK" /var/lock/cs35l41-reload.lock "$STAMP"
                  systemctl daemon-reload
                  ok "Units disabled and removed"
                  ok "Helper script removed"
                  printf "\n  ${GRN}${BLD}✓  Fully uninstalled.${NC}\n\n"
                  exit 0 ;;
    *)            banner
                  fail "Unknown option: $1"
                  usage
                  exit 2 ;;
esac

# ── Install ──────────────────────────────────────────────────────────────────
need_root
banner

step "PREFLIGHT CHECKS"
[[ -d "$DEV0" && -d "$DEV1" ]] || die "CS35L41 amplifier not found. Wrong machine?"
ok "Hardware detected"

modinfo "$MODULE" &>/dev/null || die "Kernel module '${MODULE}' not found."
ok "Kernel module available"

if ! command -v rtcwake >/dev/null 2>&1; then
    warn "rtcwake not found — install util-linux for the suspend fallback"
fi

step "INSTALLING COMPONENTS"

# ── 1. Helper script ────────────────────────────────────────────────────────
if [[ -f "$HELPER" ]]; then
    cp -f "$HELPER" "${HELPER}.bak" 2>/dev/null || true
fi

cat > "$HELPER" << 'EOF'
#!/bin/bash
# Version: 1.4.0
# CS35L41 module reload helper — installed by speakers.sh, used by the
# cs35l41-fix / cs35l41-resume / cs35l41-watchdog systemd units.
#
# It touches exactly one kernel module (snd_hda_scodec_cs35l41_i2c) and the
# two CSC3551 amplifier devices. On any other machine it is inert.
#
# Usage: cs35l41-reload [--fallback] [--escalate]
#   (none)      reload the modules and retry with backoff   (resume / manual)
#   --fallback  ...then one suspend/resume cycle if retries fail   (boot)
#   --escalate  ...then a suspend/resume cycle, rate-limited and only within
#               the first minutes of uptime                  (watchdog)
#
# Exit codes: 0 = amps bound or nothing to do, 1 = could not fix / lock timeout,
#             2 = refused to act (module in use, audio playing)
set -euo pipefail
trap 'exec 9>&- 2>/dev/null || true' EXIT

DEV0="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0"
DEV1="/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.1"
AMP0="$DEV0/driver"
AMP1="$DEV1/driver"
MODULE="snd_hda_scodec_cs35l41_i2c"
LOCK="/run/lock/cs35l41-reload.lock"
STAMP="/run/cs35l41-suspended"      # epoch of the last suspend fallback

ATTEMPTS=8               # module reload attempts before giving up
WAIT_BIND=5              # seconds to wait for the driver to bind after a load
BACKOFF_MAX=10           # cap on the linear backoff between attempts
LOCK_WAIT=30             # seconds to wait for a competing instance to finish
ESCALATE_INTERVAL=180    # min seconds between watchdog-triggered sleep cycles
ESCALATE_MAX_UPTIME=600  # escalate only in the first 10 min after boot

log() { echo "CS35L41: $*"; logger -t cs35l41 "$*" 2>/dev/null || true; }

both_bound() { [[ -e "$AMP0" && -e "$AMP1" ]]; }

# ── Inert on hardware without these amplifiers (the units guard on the same
#    condition, this is belt and braces) ──
if [[ ! -d "$DEV0" && ! -d "$DEV1" ]]; then
    log "no CSC3551 amplifier on this system; nothing to do."
    exit 0
fi

# ── Already working? Fast path, before taking any lock ──
both_bound && { log "both amps already bound."; exit 0; }

# ── Concurrency lock. Wait briefly for a competing unit rather than skipping
#    on sight: skipping is what used to lose the post-resume reload. ──
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK" || { log "cannot open lock file ${LOCK} (root required?)."; exit 1; }
if ! flock -w "$LOCK_WAIT" 9; then
    if both_bound; then
        log "another instance fixed the amplifiers while we waited."
        exit 0
    fi
    log "lock held for ${LOCK_WAIT}s; amplifiers still unbound." >&2
    exit 1
fi

# Re-check under the lock — the instance we waited for may have fixed it.
both_bound && { log "both amps already bound."; exit 0; }

# ── Poll for the bind instead of sleeping blindly: once the rail is up the
#    driver binds within a few hundred ms, so a fixed sleep only delays
#    detection and burns the retry budget. ──
wait_bound() {
    local deadline=$(( SECONDS + $1 ))
    while (( SECONDS < deadline )); do
        both_bound && return 0
        sleep 0.25
    done
    both_bound
}

# 0 = module actually reloaded, 1 = load failed, 2 = refused (module in use)
reload() {
    # modprobe -r refuses to unload an in-use module, so running audio is
    # never interrupted. If it refuses AND the module is still loaded, some
    # other user is holding it: report a distinct failure instead of
    # pretending to retry (an insert would be a no-op and fail 8 times).
    # Never force-unload.
    if ! modprobe -r "$MODULE" 2>/dev/null; then
        if grep -q "^${MODULE} " /proc/modules 2>/dev/null; then
            log "cannot unload ${MODULE}: in use (audio playing?)."
            return 2
        fi
    fi
    sleep 0.5
    modprobe "$MODULE" 2>/dev/null || return 1
    return 0
}

# ── Clamped-bus detection ──
# The DesignWare controller logs "controller timed out" when a transfer can
# never complete — which is what an unpowered amplifier holding SDA/SCL low
# looks like. Measured on the UM5302TA, a failing probe has exactly the same
# shape every single time: 2 transfers per amp at ~1.02 s each (the adapter's
# 1 s timeout), 4 timeouts per module reload, and it was byte-for-byte
# identical across 6 probe cycles spanning 16 minutes. A module reload
# provably cannot clear that state, so when a power cycle is permitted we stop
# reloading as soon as it appears instead of burning the whole budget first.
# The client's parent is the adapter (i2c-0); the adapter's parent is the
# platform device whose name prefixes the driver's log lines (AMDI0010:00).
ADAPTER="$(basename "$(readlink -f "$DEV0/.." 2>/dev/null)")"
CTRL="$(basename "$(readlink -f "/sys/bus/i2c/devices/${ADAPTER}/.." 2>/dev/null)")"
# readlink -f hands back a literal path when a link is missing, so only trust
# a plausible platform-device name; otherwise disable detection entirely.
[[ "$CTRL" =~ ^[A-Z0-9]+:[0-9A-F]+$ ]] || CTRL=""

clamp_timeouts() {
    [[ -n "$CTRL" ]] || { echo 0; return 0; }
    local n
    n="$(journalctl -k -b --no-pager -n 2000 2>/dev/null \
         | grep -c -- "${CTRL}: controller timed out" || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

# ── Retry loop ──
mode="${1:-}"
log "amps not bound, reloading modules..."
clamped=0
timeouts_before="$(clamp_timeouts)"
for (( i = 1; i <= ATTEMPTS; i++ )); do
    rc=0
    reload || rc=$?

    if (( rc == 2 )); then
        log "aborting: ${MODULE} is in use."
        exit 2
    fi

    if (( rc == 0 )) && wait_bound "$WAIT_BIND"; then
        log "fixed (attempt $i/$ATTEMPTS)."
        exit 0
    fi

    # Only worth short-circuiting when we can actually power-cycle; a plain
    # run (resume/manual) keeps the full ladder, since after a resume the bus
    # may legitimately come good with a reload alone.
    if [[ "$mode" == "--fallback" || "$mode" == "--escalate" ]]; then
        timeouts_now="$(clamp_timeouts)"
        if (( timeouts_now > timeouts_before )); then
            clamped=1
            log "bus clamped (${timeouts_now} controller timeouts): a reload cannot clear this."
            break
        fi
    fi

    if (( i < ATTEMPTS )); then
        backoff=$(( i * 2 ))
        if (( backoff > BACKOFF_MAX )); then backoff=$BACKOFF_MAX; fi
        log "attempt $i/$ATTEMPTS failed, retrying in ${backoff}s..."
        sleep "$backoff"
    fi
done

if (( clamped )); then
    log "stopping reloads early — the unpowered amps are holding the bus."
else
    log "reload budget exhausted (${ATTEMPTS} attempts)."
fi

# ── Suspend/resume fallback ──
# Per the DSDT/SSDT analysis (ROOT-CAUSE.md) the amp rail has no ACPI
# _PS0/_PS3/_PR0: only an EC-visible suspend/resume boundary re-initialises
# it, so a sleep cycle is the architecturally correct fix here rather than a
# random workaround. It is still a whole-machine event, so it only ever
# happens on an explicit flag, never in a loop, and never mid-session.
if [[ "$mode" != "--fallback" && "$mode" != "--escalate" ]]; then
    log "not allowed to suspend (no --fallback/--escalate); giving up."
    exit 1
fi

if [[ "$mode" == "--escalate" ]]; then
    uptime_s=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    [[ "$uptime_s" =~ ^[0-9]+$ ]] || uptime_s=0
    if (( uptime_s > ESCALATE_MAX_UPTIME )); then
        log "system has been up ${uptime_s}s (>${ESCALATE_MAX_UPTIME}s): not escalating."
        exit 1
    fi

    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    age=$(( $(date +%s) - last ))
    if (( age >= 0 && age < ESCALATE_INTERVAL )); then
        log "suspend fallback ran $(( age / 60 )) min ago; not repeating."
        exit 1
    fi
fi

if ! command -v rtcwake >/dev/null 2>&1; then
    log "rtcwake not found, cannot try suspend fallback."
    exit 1
fi

log "trying suspend/resume fallback (machine will sleep ~3s)..."
# Drop the lock across the sleep so cs35l41-resume.service can reload the
# modules the instant the kernel comes back — the moment most likely to
# succeed, because the rail has just been re-powered.
flock -u 9
if rtcwake -m mem -s 3 2>/dev/null; then
    date +%s > "$STAMP" 2>/dev/null || true
else
    log "rtcwake failed; continuing without a power cycle."
fi
sleep 1

if ! flock -w "$LOCK_WAIT" 9; then
    log "another instance took over after resume; exiting."
    exit 0
fi

if both_bound; then
    log "fixed across the suspend/resume boundary."
    exit 0
fi

for (( i = 1; i <= 3; i++ )); do
    rc=0
    reload || rc=$?
    if (( rc == 2 )); then
        log "aborting: ${MODULE} is in use."
        exit 2
    fi
    if (( rc == 0 )) && wait_bound "$WAIT_BIND"; then
        log "fixed after resume (attempt $i/3)."
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
Description=CS35L41 speaker fix (boot) v1.4.0
Documentation=https://github.com/as1furrahman/Zenbook_CS35l41
ConditionPathExists=/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0
After=sound.target multi-user.target
Wants=sound.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/usr/local/bin/cs35l41-reload --fallback
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
ok "Boot service   →  ${DIM}${BOOT_SVC}${NC}"

# ── 3. Resume service ───────────────────────────────────────────────────────
# Ordered After=suspend.target, which systemd activates only *after*
# systemd-suspend.service (the unit that actually sleeps) has finished — so
# this genuinely runs on resume, not before suspend.
cat > "$RESUME_SVC" << 'EOF'
[Unit]
Description=CS35L41 speaker fix (resume) v1.4.0
Documentation=https://github.com/as1furrahman/Zenbook_CS35l41
ConditionPathExists=/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0
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
Description=CS35L41 speaker watchdog v1.4.0
Documentation=https://github.com/as1furrahman/Zenbook_CS35l41
ConditionPathExists=/sys/bus/i2c/devices/i2c-CSC3551:00-cs35l41-hda.0

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs35l41-reload --escalate
EOF

cat > "$WATCHDOG_TMR" << 'EOF'
[Unit]
Description=CS35L41 speaker watchdog timer v1.4.0
Documentation=https://github.com/as1furrahman/Zenbook_CS35l41

[Timer]
OnBootSec=90
OnUnitActiveSec=300
AccuracySec=15

[Install]
WantedBy=timers.target
EOF
ok "Watchdog timer →  ${DIM}${WATCHDOG_TMR}${NC}"

step "ACTIVATING"

systemctl daemon-reload
systemctl enable cs35l41-fix cs35l41-resume --quiet
ok "Boot + resume services enabled"

if [[ ! -e "$AMP0" || ! -e "$AMP1" ]]; then
    warn "Speakers not working — attempting live fix..."
    printf "  ${DIM}   (up to ~2 min; the machine may sleep for ~3 s)${NC}\n"
    # restart, not start: the unit is RemainAfterExit=yes, so a prior
    # successful run leaves it "active" and a plain start would do nothing.
    if systemctl restart cs35l41-fix 2>/dev/null && [[ -e "$AMP0" && -e "$AMP1" ]]; then
        ok "Speakers fixed!"
    else
        warn "Couldn't fix live — reboot to apply"
    fi
else
    ok "Speakers already working"
fi

# Start the watchdog *now*, not just at the next boot. `enable` only creates
# the symlink, so an install done in a running session otherwise leaves the
# safety net dormant for the rest of that session — which is precisely when a
# failed boot fix needs it. Started last so it cannot race the boot service
# into a second suspend attempt.
systemctl enable --now cs35l41-watchdog.timer --quiet
if systemctl is-active --quiet cs35l41-watchdog.timer; then
    ok "Watchdog timer running (checks every 5 min)"
else
    warn "Watchdog timer not running — start it: systemctl start cs35l41-watchdog.timer"
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
printf "  ${WHT}Status${NC}       ${CYN}bash %s --status${NC}\n" "$PROG"
printf "  ${WHT}Reinstall${NC}    ${CYN}sudo bash %s --reinstall${NC}\n" "$PROG"
printf "  ${WHT}Uninstall${NC}    ${CYN}sudo bash %s --uninstall${NC}\n" "$PROG"
printf "  ${WHT}Help${NC}         ${CYN}bash %s --help${NC}\n" "$PROG"
printf "\n"
printf "  ${WHT}Service${NC}      ${CYN}systemctl status cs35l41-fix${NC}\n"
printf "  ${WHT}Journal${NC}      ${CYN}journalctl -u cs35l41-fix -b${NC}\n"
printf "\n"
