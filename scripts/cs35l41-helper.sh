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
ESCALATE_INTERVAL=60     # min seconds between watchdog-triggered sleep cycles
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

log "trying suspend/resume fallback (machine will sleep ~5s)..."
# Drop the lock across the sleep so cs35l41-resume.service can reload the
# modules the instant the kernel comes back — the moment most likely to
# succeed, because the rail has just been re-powered.
flock -u 9
if rtcwake -m mem -s 5 2>/dev/null; then
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
