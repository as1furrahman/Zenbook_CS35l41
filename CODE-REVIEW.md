# Code Review — Zenbook_CS35l41 (v1.4.0)

Reviewer: Buffy · Date: 2026-09-23 · Revision reviewed: `dffa105` (branch `main`)

Scope: the whole repository as it stands — `speakers.sh` (711 L),
`tests/helper-selftest.sh` (301 L), `README.md` (299 L), `ROOT-CAUSE.md` (65 L),
`Makefile`, `.github/workflows/selftest.yml`, `.gitignore`.

Method: full read of every tracked file, plus execution of the project's own
verification path. Nothing was installed and no system state was changed.

---

## 1. Overall rating

> **8.5 / 10** — an unusually disciplined, well-evidenced single-purpose fix.
> No correctness defects were found. The deductions are all about
> *maintainability and CI depth*, not about whether the tool works.

| Dimension | Rating | Summary |
|---|---|---|
| Correctness / robustness | **9 / 10** | Failure modes are designed rather than discovered; only gap is reliance on host tooling |
| Test suite | **9 / 10** | 28 sandboxed checks with real isolation; slow and coupled to installer internals |
| Documentation | **10 / 10** | Measured evidence, stated falsification test, explicit blast radius |
| Safety / blast radius | **9 / 10** | Narrow by construction and documented; one deliberate whole-machine action |
| Code structure / maintainability | **6 / 10** | 711-line monolith, embedded helper, duplicated constants |
| CI / tooling | **6 / 10** | Syntax check + tests only; no static analysis, unpinned action |
| Version hygiene | **5 / 10** | Same version literal repeated in 7 places; no single source of truth |

---

## 2. Verification performed

| Check | Command | Result |
|---|---|---|
| Syntax, installer | `bash -n speakers.sh` | **pass** |
| Syntax, test suite | `bash -n tests/helper-selftest.sh` | **pass** |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=28 failed=0`**, exit 0 |
| Diagnostics | `bash speakers.sh --status` | **pass**, exit 0, table renders correctly |
| CLI | `bash speakers.sh --version` | **pass** → `speakers.sh 1.4.0` |
| Suite runtime | `time bash tests/helper-selftest.sh` | **~57 s wall, 0.7 s user** (see G-4) |

All 28 checks passed on a first run, which is a good sign for a suite that
asserts negative behaviour (inert paths, refusal paths, lock contention).

---

## 3. Strengths (what is working well)

1. **Failure modes are designed, not discovered.**
   An in-use module aborts immediately with exit 2 (`speakers.sh:429`) instead
   of burning the full 8-attempt budget pretending to retry. A lock timeout
   distinguishes "amps still unbound" (exit 1) from "another instance fixed
   them" (exit 0). `modprobe -r` is never forced, so playing audio cannot be cut.
2. **Install-path regressions have tests.**
   Two bugs that actually shipped — a watchdog that was enabled but never
   started, and a live fix using `start` instead of `restart` — are pinned by
   assertions (`tests/helper-selftest.sh:258`, `:263`). This is rare discipline
   for a personal hardware fix.
3. **The suite proves its own isolation.**
   It aborts if a real `logger` is reachable, and it re-runs the helper against
   a *sanitised* `PATH` built from coreutils symlinks so the host's real
   `rtcwake` cannot be reached (`tests/helper-selftest.sh:203-222`). It also
   asserts on real ANSI escapes rather than literal `\033`.
4. **Diagnostics are honest.**
   `--status` flags an enabled-but-inactive watchdog timer and a failed boot
   service rather than printing a bare `inactive`/`failed`.
5. **Documentation is evidence-based.**
   `ROOT-CAUSE.md` does not just assert "the rail is dead" — it gives the ACPI
   analysis (no `_PS0`/`_PS3`/`_PR0`, `AMPD` never written by AML) *and* the
   measured counter-evidence (24 timeouts, all on one bus, sibling controller
   clean, ~1.02 s each, byte-identical across 6 cycles), then names the cheap
   experiment that would falsify it.
6. **Blast radius is enumerated.**
   The README lists exactly which files are written and which `systemctl` verbs
   are used, and every unit carries `ConditionPathExists`, so the install is a
   genuine no-op on other hardware.

---

## 4. Gaps and problems

No critical or high-severity defects were found. All items below are
maintainability, testing-depth or hygiene issues.

### G-1 — No static analysis (`shellcheck`) — **Medium**
`make lint` performs `bash -n` only (`Makefile:7-9`), and CI repeats the same
two syntax checks (`selftest.yml:17-20`). For 711 lines of bash using heredocs,
embedded subshells, arithmetic guards, `eval`-extracted functions and regex
gates, syntax-checking is close to no coverage. `shellcheck` would be expected
to flag unquoted expansions, useless `|| true` placements, and the
`local` declarations (`speakers.sh:192`) that are declared but never assigned.

### G-2 — Version duplicated in seven places — **Medium**
The literal `1.4.0` appears in: `VERSION=` (`speakers.sh:102`), the helper's
`# Version:` header (`speakers.sh:353`), four unit `Description=` strings, and
the README badge. There is no single source of truth and no check that they
agree. This is already observably confusing: `--status` reported
**`Version 1.3.1`** while `--version` printed **`1.4.0`** — correct behaviour
(status reads the *installed* helper, version reads the *shipped* script), but
the table does not say which is which, so it reads as a bug.

### G-3 — Helper is embedded as a heredoc, tests depend on that shape — **Medium**
The helper lives inside `speakers.sh` between `cat > "$HELPER" << 'EOF'` and
`EOF`, and the suite recovers it with an `awk` pattern tied to that exact line
(`tests/helper-selftest.sh:24`). Renaming the delimiter or changing the
quoting breaks the suite's ability to test *anything*, failing with only
`could not extract helper`. The installer's own functions are similarly
`eval`'d out of the source by regex (`:271-272`, `:285`), which means
shellcheck (G-1) could never see most of this code even if added.
Constants are consequently duplicated between installer and helper
(`DEV0`/`DEV1`/`MODULE` at `speakers.sh:107-111` and again at `:371-376`).

### G-4 — Test suite takes ~57 s of almost pure sleeping — **Low/Medium**
`user` time is 0.7 s against 57 s wall. Contributors include the fixed
`LOCK_WAIT`/`sleep 5` lockers (`tests/helper-selftest.sh:231`), the reload
backoff, and `sleep 0.25` polling. The practical impact is that the suite
exceeds any default 30 s command timeout, so it looks hung when it is only
slow, and it will keep a default CI runner busy. Measurable and easy to trim.

### G-5 — Installer path is only grep-tested — **Medium**
The only installer coverage is two `grep -qE` assertions on literal command
strings (`tests/helper-selftest.sh:258`, `:263`). Nothing exercises
`--uninstall` (which removes more paths than install creates:
`speakers.sh:310-318`), the ordering guarantee that the watchdog is started
*after* the live fix, or the rendered contents of the generated unit files.
Three of those are checkable without root by rendering the heredocs into a
sandbox.

### G-6 — CI configuration — **Low**
* `actions/checkout@v4` is a moving tag, not a SHA pin (`selftest.yml:15`).
* No `permissions:` block, so the job runs with default `GITHUB_TOKEN` scope.
* The workflow re-implements `make ci` inline (`selftest.yml:17-30`) rather than
  calling it, so the Makefile and CI can drift apart silently.
* No job asserts the `passed=28` figure, so the README's "28 checks" claim can
  rot without anything failing.

### G-7 — Status table column offset — **Low (cosmetic)**
Badge cells are built as `" " + text + " " + padding` (`cell()`,
`speakers.sh:144`) while text rows use `%-21s`. Both end up 21 visible columns,
so the box borders align, but badge text sits one column to the right of every
text row ("YES" vs "1.3.1"). The `cell()` comment claims the rows "line up";
they line up on the right edge only.

### G-8 — Unbounded trust in the suspend fallback — **Low (by design, note only)**
The one whole-machine action is well gated: explicit flag only, `--escalate`
requires uptime < 600 s and a 180 s rate limit, and the stamp lives in `/run`
so it resets each boot. It is documented, tested (rate limit, clock skew,
uptime bound, missing `rtcwake`). It is still a system-wide sleep triggered
from a timer, and a desktop configured to lock on suspend will lock — a
trade-off worth re-reading if this is ever run unattended on a machine that is
not a laptop the owner is sitting in front of.

### G-9 — No `CHANGELOG.md` — **Low**
Version history exists only as a hand-maintained comment block at the top of
`speakers.sh` (`:23-98`), duplicating what the git log already holds. Its six
paragraphs are excellent release notes; they would be more discoverable in a
`CHANGELOG.md`, or dropped in favour of the tags (only `v1.4.0` exists).

### G-10 — `--reinstall` / argument parsing — **Low (style)**
Action subcommands fall through the `case` into the install path
(`speakers.sh:299-327`) rather than calling a function, which makes the control
flow harder to follow than it needs to be. Inconsistent indentation in the
dispatch block (`-V|--version` is over-indented) is a small readability wart.

---

## 5. Prioritised recommendations

| # | Action | Addresses | Effort |
|---|---|---|---|
| 1 | Add `shellcheck` to `make lint` and to CI, then triage its output | G-1 | S |
| 2 | Derive the helper header, unit descriptions and status row from one `VERSION`; have `--status` label the row "Installed version" | G-2 | S |
| 3 | Move the helper into its own `helper.sh`, copied (or `sed`-substituted) by the installer, so it is lintable and testable directly | G-3 | M |
| 4 | Have CI call `make ci` instead of duplicating commands, and assert the check count / add a `permissions:` block and SHA pin | G-6 | S |
| 5 | Cut the fixed sleeps in the lock tests; target < 15 s total runtime | G-4 | S |
| 6 | Render the unit heredocs into a sandbox and assert their contents and install ordering; add a `--uninstall` path test | G-5 | M |
| 7 | Fix the badge row offset in `cell()` or update its comment to say "right edge" | G-7 | S |
| 8 | Promote the release-notes block to `CHANGELOG.md` | G-9 | S |

---

## 6. Bottom line

This is a well-scoped, carefully hardened fix whose documentation and test
suite are both markedly above what the problem requires — the root-cause
write-up in particular sets a standard most kernel-adjacent bug reports do not
reach. Nothing in the review suggests the tool fails at its job; the 9/10
correctness score reflects tested behaviour, not optimism.

The realistic risk is **drift**: a version number maintained by hand in seven
places, an installer whose logic no static analyser can see, and a CI job that
checks syntax and little else. Items 1–3 would move this from "excellent
personal fix" to "maintainable by someone else".
