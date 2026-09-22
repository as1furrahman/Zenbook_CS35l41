#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 as1furrahman
# Self-test for the cs35l41-reload helper logic (no root, no system changes).
#
# Extracts the helper heredoc from speakers.sh, rewrites every path and its
# timing constants into a sandbox under .selftest/, stubs modprobe/rtcwake on
# PATH, and checks the control flow: that a fix is detected, that the suspend
# fallback only ever fires when allowed, that the lock behaves, and that the
# script is inert where it should be.
#
# Usage:  bash tests/helper-selftest.sh       (exit 0 = all passed)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$ROOT/.selftest"
BIN="$SB/bin"
export PATH="$BIN:$PATH"

rm -rf "$SB"
mkdir -p "$BIN" "$SB/run" "$SB/amp0" "$SB/amp1" "$SB/state"

# ── obtain the helper directly from scripts/cs35l41-helper.sh ───────────────
[[ -f "$ROOT/scripts/cs35l41-helper.sh" ]] || { echo "FAIL: scripts/cs35l41-helper.sh not found"; exit 1; }
cp "$ROOT/scripts/cs35l41-helper.sh" "$SB/reload.orig.sh"

# ── redirect every path/constant into the sandbox ───────────────────────────
sed -e "s|^DEV0=.*|DEV0=\"$SB/amp0\"|" \
    -e "s|^DEV1=.*|DEV1=\"$SB/amp1\"|" \
    -e "s|^LOCK=.*|LOCK=\"$SB/run/cs35l41-reload.lock\"|" \
    -e "s|^CTRL=.*|CTRL=\"AMDI0010:00\"|" \
    -e "s|^STAMP=.*|STAMP=\"$SB/run/cs35l41-suspended\"|" \
    -e "s|/proc/modules|$SB/proc_modules|g" \
    -e "s|/proc/uptime|$SB/proc_uptime|g" \
    -e "s|^ATTEMPTS=.*|ATTEMPTS=3|" \
    -e "s|^WAIT_BIND=.*|WAIT_BIND=\"\${TEST_WAIT_BIND:-0}\"|" \
    -e "s|^BACKOFF_MAX=.*|BACKOFF_MAX=0|" \
    -e "s|^LOCK_WAIT=.*|LOCK_WAIT=1|" \
    -e "s|^ESCALATE_INTERVAL=.*|ESCALATE_INTERVAL=180|" \
    -e "s|^ESCALATE_MAX_UPTIME=.*|ESCALATE_MAX_UPTIME=600|" \
    -e "s|sleep 0.5|sleep 0.02|g" \
    -e "s|sleep 1|sleep 0.02|g" \
    "$SB/reload.orig.sh" > "$SB/reload.sh"
chmod +x "$SB/reload.sh"
bash -n "$SB/reload.sh" || { echo "FAIL: helper has syntax errors"; exit 1; }

# ── stubs ───────────────────────────────────────────────────────────────────
cat > "$BIN/modprobe" <<STUB
#!/bin/bash
if [[ "\${1:-}" == "-r" ]]; then
    if [[ -e "$SB/state/busy" ]]; then
        printf 'snd_hda_scodec_cs35l41_i2c 16384 1 - Live 0x0\n' > "$SB/proc_modules"
        exit 1
    fi
    : > "$SB/proc_modules"
    exit 0
fi
[[ -e "$SB/state/fail-load" ]] && exit 1
[[ -e "$SB/state/bind-on-load" ]] && { : > "$SB/amp0/driver"; : > "$SB/amp1/driver"; }
[[ -e "$SB/state/bind-after-poll" ]] && ( sleep 0.08; : > "$SB/amp0/driver"; : > "$SB/amp1/driver" ) &
# Simulate a probe that hangs the i2c bus: 2 transfers per amp, as measured.
if [[ -e "$SB/state/clamp" ]]; then
    c=\$(cat "$SB/state/clamp_count" 2>/dev/null || echo 0)
    echo \$(( c + 4 )) > "$SB/state/clamp_count"
fi
exit 0
STUB

cat > "$BIN/journalctl" <<STUB
#!/bin/bash
n=\$(cat "$SB/state/clamp_count" 2>/dev/null || echo 0)
[[ "\$n" =~ ^[0-9]+$ ]] || n=0
for (( i=0; i<\$n; i++ )); do
    echo "i2c_designware AMDI0010:00: controller timed out"
done
exit 0
STUB

cat > "$BIN/rtcwake" <<STUB
#!/bin/bash
[[ -e "$SB/state/rtcwake-fail" ]] && exit 1
[[ -e "$SB/state/bind-on-resume" ]] && { : > "$SB/amp0/driver"; : > "$SB/amp1/driver"; }
exit 0
STUB
# Tests must never write to the system journal. The helper logs through
# `logger -t cs35l41`, which otherwise pollutes `journalctl -t cs35l41` — the
# exact command the troubleshooting docs tell users to read.
cat > "$BIN/logger" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$SB/logger.calls"
exit 0
STUB
chmod +x "$BIN/modprobe" "$BIN/rtcwake" "$BIN/logger" "$BIN/journalctl"

# Prove the stub shadows any real logger before relying on that below.
resolved="$(PATH="$BIN:$PATH" command -v logger)"
if [[ "$resolved" != "$BIN/logger" ]]; then
    echo "  FAIL  a real logger ($resolved) is reachable from the tests"
    exit 1
fi

# ── helpers ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$SB/state"; mkdir -p "$SB/state"
    mkdir -p "$SB/amp0" "$SB/amp1"
    rm -f "$SB/amp0/driver" "$SB/amp1/driver" "$SB/run/cs35l41-suspended"
    : > "$SB/proc_modules"
    echo 100 > "$SB/proc_uptime"
}
run_helper() { OUT="$(TEST_WAIT_BIND="${TEST_WAIT_BIND:-0}" "$SB/reload.sh" "$@" 2>&1)"; RC=$?; }

pass=0; failed=0
check() {  # desc, expected rc, expected substring
    local desc="$1" want_rc="$2" want="${3:-}"
    local hit=1
    if [[ -n "$want" ]]; then grep -qF -- "$want" <<<"$OUT" || hit=0; fi
    if [[ "$RC" == "$want_rc" && "$hit" == 1 ]]; then
        printf '  PASS  %s (rc=%s)\n' "$desc" "$RC"; pass=$((pass+1))
    else
        printf '  FAIL  %s (rc=%s, wanted %s%s)\n' "$desc" "$RC" "$want_rc" \
               "${want:+, containing: $want}"
        # shellcheck disable=SC2001
        sed 's/^/          | /' <<<"$OUT"
        failed=$((failed+1))
    fi
}

echo "helper self-test (sandbox: $SB)"

# ── scope guards ────────────────────────────────────────────────────────────
reset_state; rm -rf "$SB/amp0" "$SB/amp1"
run_helper --fallback
check "no CSC3551 hardware -> inert, no suspend" 0 "nothing to do"
if [[ ! -e "$SB/run/cs35l41-suspended" ]]; then
    echo "  PASS  inert run did not record a fallback"; pass=$((pass+1))
else
    echo "  FAIL  inert run recorded a fallback"; failed=$((failed+1))
fi

reset_state; : > "$SB/amp0/driver"; : > "$SB/amp1/driver"
run_helper; check "already bound -> no-op" 0 "already bound"

reset_state
run_helper; check "plain mode never suspends" 1 "not allowed to suspend"

# ── the recovery ladder ─────────────────────────────────────────────────────
reset_state; : > "$SB/state/bind-on-load"; : > "$SB/logger.calls"
run_helper --fallback; check "binds on first reload" 0 "fixed (attempt 1/3)"
if grep -qF 'fixed (attempt 1/3)' "$SB/logger.calls" 2>/dev/null; then
    echo "  PASS  helper logs through logger (stubbed; journal untouched)"; pass=$((pass+1))
else
    echo "  FAIL  helper did not log through logger"; failed=$((failed+1))
fi
reset_state; : > "$SB/state/bind-after-poll"
TEST_WAIT_BIND=1 run_helper --fallback
check "delayed bind exercises wait_bound polling loop" 0 "fixed (attempt 1/3)"

reset_state; : > "$SB/state/bind-on-resume"
run_helper --fallback
check "dead boot recovers via suspend fallback" 0 "fixed across the suspend/resume boundary"
if [[ -s "$SB/run/cs35l41-suspended" ]]; then
    echo "  PASS  fallback recorded a timestamp"; pass=$((pass+1))
else
    echo "  FAIL  fallback did not record a timestamp"; failed=$((failed+1))
fi

reset_state; : > "$SB/state/bind-on-resume"; date +%s > "$SB/run/cs35l41-suspended"
run_helper --escalate; check "escalate respects the rate limit" 1 "not repeating"

reset_state; : > "$SB/state/bind-on-resume"
echo $(( $(date +%s) + 999999 )) > "$SB/run/cs35l41-suspended"
run_helper --escalate; check "clock skew (future stamp) does not block escalation" 0 "fixed across the suspend/resume boundary"

reset_state; echo 5000 > "$SB/proc_uptime"
run_helper --escalate; check "escalate refuses mid-session" 1 "not escalating"

reset_state; : > "$SB/state/bind-on-resume"
run_helper --escalate; check "escalate fires in the boot window" 0 "fixed across the suspend/resume boundary"

reset_state; : > "$SB/state/fail-load"; : > "$SB/state/rtcwake-fail"
run_helper --fallback; check "survives insert+rtcwake failure" 1 "rtcwake failed"

# ── clamped bus: skip the provably-futile ladder when a power cycle is allowed ──
reset_state; : > "$SB/state/clamp"; : > "$SB/state/bind-on-resume"
run_helper --fallback
check "clamped bus short-circuits to the fallback" 0 "a reload cannot clear this"
if grep -qF 'attempt 2/' <<<"$OUT"; then
    echo "  FAIL  still burned a second futile reload attempt"; failed=$((failed+1))
else
    echo "  PASS  no second reload attempt was made"; pass=$((pass+1))
fi

reset_state; : > "$SB/state/clamp"
run_helper
check "plain run keeps the full ladder (cannot suspend)" 1 "not allowed to suspend"
if grep -qF 'attempt 2/3' <<<"$OUT"; then
    echo "  PASS  plain run did not short-circuit"; pass=$((pass+1))
else
    echo "  FAIL  plain run short-circuited without being allowed to power-cycle"; failed=$((failed+1))
fi

# ── safety: in-use module ───────────────────────────────────────────────────
reset_state; : > "$SB/state/busy"
run_helper; check "in-use module aborts fast (no wasted retries)" 2 "in use"

# ── rtcwake absent: must refuse to suspend ──────────────────────────────────
# A sanitised PATH of coreutils symlinks plus our stubs, so the host's real
# rtcwake cannot be reached from this test even by accident.
MINBIN="$SB/minbin"
mkdir -p "$MINBIN"
for b in bash flock grep mkdir dirname basename readlink date sleep cut cat journalctl; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$MINBIN/$b"
done
ln -sf "$BIN/modprobe" "$MINBIN/modprobe"
ln -sf "$BIN/logger" "$MINBIN/logger"
[[ -x "$MINBIN/rtcwake" ]] && { echo "  FAIL  sanitiser left a real rtcwake reachable"; exit 1; }

reset_state; : > "$SB/state/bind-on-resume"
OUT="$(PATH="$MINBIN" "$SB/reload.sh" --fallback 2>&1)"; RC=$?
check "no rtcwake on PATH -> refuses to suspend" 1 "rtcwake not found"
if [[ ! -e "$SB/run/cs35l41-suspended" ]]; then
    echo "  PASS  no rtcwake: no fallback recorded"; pass=$((pass+1))
else
    echo "  FAIL  no rtcwake: a fallback was recorded"; failed=$((failed+1))
fi

# ── locking ─────────────────────────────────────────────────────────────────
reset_state; : > "$SB/state/bind-on-load"
flock "$SB/run/cs35l41-reload.lock" -c "sleep 0.5" &
locker=$!
sleep 0.2
run_helper --fallback
wait "$locker" 2>/dev/null
check "waits out a competing instance" 0 "fixed (attempt 1/3)"

reset_state
( exec 8>"$SB/run/cs35l41-reload.lock"; flock 8; sleep 3 ) &
locker=$!
sleep 0.2
run_helper --fallback
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null
check "lock timeout with unbound amps exits 1" 1 "amplifiers still unbound"

reset_state
(
    exec 8>"$SB/run/cs35l41-reload.lock"
    flock 8
    sleep 0.2
    : > "$SB/amp0/driver"
    : > "$SB/amp1/driver"
    sleep 2.5
) &
locker=$!
sleep 0.1
run_helper --fallback
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null
check "lock timeout with bound amps exits 0" 0 "another instance fixed the amplifiers"

# ── install-path regression guards ──────────────────────────────────────────
# Both of these shipped as real bugs: a watchdog that was enabled but never
# started, and a live fix that used `start` (a no-op once the unit is active).
if grep -qE 'systemctl enable --now cs35l41-watchdog\.timer' "$ROOT/speakers.sh"; then
    echo "  PASS  installer starts the watchdog timer (--now)"; pass=$((pass+1))
else
    echo "  FAIL  installer only enables the watchdog — it stays dormant"; failed=$((failed+1))
fi
if grep -qE 'systemctl restart cs35l41-fix' "$ROOT/speakers.sh"; then
    echo "  PASS  live fix restarts the boot unit (start would be a no-op)"; pass=$((pass+1))
else
    echo "  FAIL  live fix uses start — a no-op when the unit is already active"; failed=$((failed+1))
fi

# ── standalone helper sync guard (G-3 / N-2) ────────────────────────────────
awk '/^[[:space:]]*cat > "\$HELPER" << .EOF.$/ { f=1; next } f && /^[[:space:]]*EOF$/ { f=0 } f' \
    "$ROOT/speakers.sh" > "$SB/reload.embedded.sh"
if diff -u "$ROOT/scripts/cs35l41-helper.sh" "$SB/reload.embedded.sh" >/dev/null; then
    echo "  PASS  standalone helper and installer embedded copy are identical"; pass=$((pass+1))
else
    echo "  FAIL  scripts/cs35l41-helper.sh and speakers.sh embedded copy differ"; failed=$((failed+1))
fi

# ── systemd unit integrity & ordering (G-5) ─────────────────────────────────
units_ok=1
for svc_var in BOOT_SVC RESUME_SVC WATCHDOG_SVC; do
    if ! awk -v v="$svc_var" '$0 ~ "cat > \"\\$" v "\" << EOF",/^EOF$/ { if ($0 ~ /ConditionPathExists=\/sys\/bus\/i2c\/devices\/i2c-CSC3551:00-cs35l41-hda\.0/) found=1 } END { exit !found }' "$ROOT/speakers.sh"; then
        units_ok=0
    fi
done
if (( units_ok )); then
    echo "  PASS  all service units gate on hardware ConditionPathExists"; pass=$((pass+1))
else
    echo "  FAIL  service units missing ConditionPathExists"; failed=$((failed+1))
fi

order_ok=0
awk '/systemctl restart cs35l41-fix/ { f=1 } /systemctl enable --now cs35l41-watchdog\.timer/ { if (f) exit 0; else exit 1 }' "$ROOT/speakers.sh" && order_ok=1
if (( order_ok )); then
    echo "  PASS  installer ordering: live fix executes before watchdog start"; pass=$((pass+1))
else
    echo "  FAIL  watchdog started before live fix finished"; failed=$((failed+1))
fi

# ── uninstall coverage (G-5 / N-3) ──────────────────────────────────────────
# Exercise the real do_uninstall() from speakers.sh under a sandboxed environment.
eval "$(sed -n '/^do_uninstall() {/,/^}/p' "$ROOT/speakers.sh")"

if (
    # shellcheck disable=SC2317
    need_root() { :; }
    # shellcheck disable=SC2317
    banner() { :; }
    # shellcheck disable=SC2317
    step() { :; }
    # shellcheck disable=SC2317
    ok() { :; }
    # shellcheck disable=SC2317
    printf() { :; }
    # shellcheck disable=SC2317
    systemctl() { echo "systemctl $*" >> "$SB/systemctl.log"; }
    # shellcheck disable=SC2034
    GRN="" BLD="" NC=""

    HELPER="$SB/bin/cs35l41-reload"
    BOOT_SVC="$SB/systemd/cs35l41-fix.service"
    RESUME_SVC="$SB/systemd/cs35l41-resume.service"
    WATCHDOG_SVC="$SB/systemd/cs35l41-watchdog.service"
    WATCHDOG_TMR="$SB/systemd/cs35l41-watchdog.timer"
    LOCK="$SB/run/cs35l41-reload.lock"
    LEGACY_LOCK="$SB/run/cs35l41-reload-legacy.lock"
    STAMP="$SB/run/cs35l41-suspended"

    mkdir -p "$SB/systemd" "$SB/bin" "$SB/run"
    touch "$HELPER" "${HELPER}.bak" "${HELPER}.old1" "${HELPER}.old2" \
          "$BOOT_SVC" "$RESUME_SVC" "$WATCHDOG_SVC" "$WATCHDOG_TMR" \
          "$LOCK" "$LEGACY_LOCK" "$STAMP"

    do_uninstall

    grep -q "disable --now cs35l41-fix" "$SB/systemctl.log" || exit 1
    grep -q "reset-failed cs35l41-fix" "$SB/systemctl.log" || exit 2
    grep -q "daemon-reload" "$SB/systemctl.log" || exit 3

    for f in "$HELPER" "${HELPER}.bak" "${HELPER}.old1" "${HELPER}.old2" \
             "$BOOT_SVC" "$RESUME_SVC" "$WATCHDOG_SVC" "$WATCHDOG_TMR" \
             "$LOCK" "$LEGACY_LOCK" "$STAMP"; do
        [[ -e "$f" ]] && exit 4
    done
    exit 0
); then
    echo "  PASS  do_uninstall() disables units, reloads daemon, and purges files"; pass=$((pass+1))
else
    echo "  FAIL  do_uninstall() failed to disable units or purge files"; failed=$((failed+1))
fi

# ── status-table cell alignment (cell() is what draws the badges) ──────────
# Pull in the installer's real config block and the real function; never a copy.
eval "$(awk '/^cat > "\$HELPER" << /{exit} /^[A-Z][A-Z0-9_]*=/{print}' "$ROOT/speakers.sh")"
eval "$(sed -n '/^cell() {/,/^}/p' "$ROOT/speakers.sh")"
width_of() { printf '%s' "$(cell "$1" "$2")" | sed 's/\x1b\[[0-9;]*m//g' | wc -c; }
for text in YES NO; do
    w="$(width_of '\033[42m' "$text")"
    if [[ "$w" == 21 ]]; then
        printf '  PASS  status cell "%s" is 21 columns wide\n' "$text"; pass=$((pass+1))
    else
        printf '  FAIL  status cell "%s" is %s columns (want 21)\n' "$text" "$w"
        failed=$((failed+1))
    fi
done

# ── escape handling: colours must be real ANSI codes, never literal \033 ────
eval "$(sed -n '/^usage() {/,/^}/p' "$ROOT/speakers.sh")"
out="$(usage)"
if grep -q '\\033' <<<"$out"; then
    printf '  FAIL  usage() prints literal \\033 instead of colour\n'
    failed=$((failed+1))
elif [[ "$(width_of '\033[42m' YES)" == 21 ]] && grep -q 'Usage' <<<"$out"; then
    printf '  PASS  usage() renders real ANSI escapes\n'; pass=$((pass+1))
else
    printf '  FAIL  usage() produced unexpected output\n'; failed=$((failed+1))
fi

# ── pipe-execution invocation name guard (N4) ───────────────────────────────
pipe_ver="$(bash -s -- --version < "$ROOT/speakers.sh" 2>/dev/null)"
if [[ "$pipe_ver" == "speakers.sh $VERSION" ]]; then
    echo "  PASS  pipe execution preserves script name ($pipe_ver)"; pass=$((pass+1))
else
    echo "  FAIL  pipe execution misreported script name: $pipe_ver"; failed=$((failed+1))
fi

echo
echo "passed=$pass failed=$failed"
rm -rf "$SB"
[[ "$failed" == 0 && "$pass" == 34 ]]
