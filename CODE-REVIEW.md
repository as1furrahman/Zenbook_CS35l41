# Code Review — Zenbook_CS35l41

Reviewer: Buffy · **Revision 4** · Date: 2026-09-23
Revision reviewed: `38890d1` ("fix(review): Resolve Revision 3 review findings
(R3-1 through R3-4)"), tagged `v1.4.0`, branch `main`.

Previous revisions: `dffa105` (Rev 1 — 8.5/10), `b563231` (Rev 2 — 9.0/10),
`21a3e48` (Rev 3 — 9.5/10).

Scope: all 11 tracked files — `speakers.sh` (729 L), `scripts/cs35l41-helper.sh`
(235 L), `tests/helper-selftest.sh` (383 L), `README.md` (307 L),
`CHANGELOG.md` (71 L), `ROOT-CAUSE.md` (65 L), `Makefile` (35 L),
`.github/workflows/selftest.yml` (33 L), `.gitignore`, `LICENSE`, `CODE-REVIEW.md`.

Method: full re-read of every changed file, execution of the project's own
verification path (shellcheck, suite, timing), `git ls-remote` against the
remote for the tag claims, and a controlled experiment on a throwaway copy of
the suite to isolate the timing regression. No project or system state was
changed; scratch files were created under `/tmp` and removed.

---

## 1. Overall rating

> **9.5 / 10 — unchanged from Revision 3, by coincidence rather than by
> stasis.** Three of the four Revision 3 items are properly closed and verified,
> and two of those were real gains (accurate release tags, an unblocked install
> path). The fourth was fixed in one respect and broke in another: the test
> suite's runtime went from 6.0 s back to **46.9 s**, re-opening the finding that
> had been closed two revisions ago.

| Dimension | Rev 1 | Rev 2 | Rev 3 | **Rev 4** | Summary |
|---|:---:|:---:|:---:|:---:|---|
| Correctness / robustness | 9 | 9 | 9.5 | **9.5** | Unchanged; still no defect found in four passes |
| Test suite | 9 | 9 | 9.5 | **8.5** | Real artifacts still tested, but 46.9 s (was 6.0 s) and the poll loop is still never entered |
| Documentation | 10 | 10 | 9.5 | **9.5** | Accurate on tags and dependencies now; one stale sentence at `README.md:186` |
| Safety / blast radius | 9 | 9 | 9.5 | **9.5** | Unchanged, narrow by construction |
| Code structure / maintainability | 6 | 8 | 9 | **9.5** | The duplicated fallback is now documented as intentional and parity-tested |
| CI / tooling | 6 | 7 | 9.5 | **10** | Correct enforcement, hard-fail when absent, installed in CI, and no longer gating `install` |
| Version hygiene | 5 | 8 | 8.5 | **9.5** | Every remaining tag is accurate on the remote; the note no longer overstates |

Flat mean of the dimensions ≈ 9.4.

---

## 2. Verification performed (revision 4)

| Check | Command | Result |
|---|---|---|
| Static analysis | `shellcheck speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh` | **pass — exit 0, no output** (v0.10.0) |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=32 failed=0`**, exit 0 |
| Suite duration | `time bash tests/helper-selftest.sh`, run twice | **46.9 s / 46.7 s** — reproducible |
| Helper parity | `diff <(awk-extracted embedded copy) scripts/cs35l41-helper.sh` | **identical** |
| Tags (local) | `git tag -l` | `v1.2.0`, `v1.2.1`, `v1.4.0` — the two inaccurate tags are gone |
| Tags (remote, authoritative) | `git ls-remote --tags origin` | same three only — the deletion was pushed, so `CHANGELOG.md:8` is now **accurate** |
| Tag → content | `git log -1 <tag>^{}` | `v1.2.0`→`a3590ad`, `v1.2.1`→`92fe37f`, `v1.4.0`→`38890d1` — all three match their entries |
| Install path unblocked | `grep -n '^install:\|^reinstall:' Makefile` | **no `lint` prerequisite** — `make install` works without shellcheck |
| Dev dependency documented | `README.md:176-183` | shellcheck listed for `make test`/`make lint`, with the dependency-free `bash tests/helper-selftest.sh` path spelled out |
| Timing regression | controlled experiment, section 4 | **caused entirely by two timing knobs, one-line fix** |
| `make ci` end-to-end | — | not run — `make` is not installed here; both recipe lines verified individually |

---

## 3. Resolution of Revision 3 findings

| Ref | Finding | Verdict | Evidence |
|---|---|---|---|
| **R3-1** | Two of five tags pinned to commits lacking the documented changes | **Fixed** | `v1.3.0` and `v1.3.1` deleted locally **and on the remote** (`git ls-remote` confirms only three tags remain); `CHANGELOG.md:8` reworded to name exactly `v1.2.0`, `v1.2.1`, `v1.4.0` and to describe v1.0.0–v1.3.1 entries as internal development history. Every surviving tag now matches its entry |
| **R3-2** | The lint gate blocked the documented install path | **Fixed** | `Makefile:22,25` — `install` and `reinstall` no longer depend on `lint`. `README.md:176-183` documents shellcheck as developer-only tooling and offers the dependency-free suite invocation |
| **R3-3** | Speedup had cost fidelity and contention margin | **Partial — and a new regression** | Margins restored (`tests:233` holds 3 s, `tests:248` 2.5 s → 1.8 s / 1.6 s of headroom) and `BACKOFF_MAX=1` returns real backoff arithmetic. But suite runtime went **6.0 s → 46.9 s**, re-opening G-4. See R4-1 |
| **R3-4** | Helper duplicated with no explanation | **Fixed** | `speakers.sh:344-346` documents the fallback as a `curl \| bash` path and points at the parity test. The rationale is accurate: under a pipe `$SCRIPT_DIR` does not resolve, so the fallback really is reachable. Parity gate at `tests:273-274` still passes |

Two of these were substantive, not cosmetic. The tag work in particular took the
honest route — removing an inaccurate claim rather than leaving a plausible-
sounding one in place — and the citation is verified against the remote, not
just the local clone. `CHANGELOG.md:8` no longer asserts anything that is false.

---

## 4. Finding this revision introduced

### R4-1 — the suite's runtime went from 6.0 s back to 46.9 s — **Low/Medium (regression)**

`tests:36-37,41-42` now run the sandbox helper with `WAIT_BIND=1`,
`BACKOFF_MAX=1` and 0.1 s internal sleeps, where Revision 3 used
`WAIT_BIND=0`, `BACKOFF_MAX=0` and 0.02 s. I isolated the cause on a throwaway
copy of the repo under `/tmp` (all four runs pass 32/32):

| Variant | `WAIT_BIND` | `BACKOFF_MAX` | internal sleeps | Lockers | Runtime |
|---|---|---|---|---|---|
| Rev 3 as shipped | 0 | 0 | 0.02 | 1.4 s / 1.4 s | 6.0 s |
| **Rev 4 as shipped** | 1 | 1 | 0.1 | 3 s / 2.5 s | **46.9 s** |
| Experiment A — only `WAIT_BIND`→0 | 0 | 1 | 0.1 | 3 s / 2.5 s | 27.2 s |
| Experiment B — knobs reverted | 0 | 0 | 0.02 | **3 s / 2.5 s** | **5.9 s** |

Conclusions, each directly measured:

1. The entire ~41 s increase comes from the three timing knobs. `WAIT_BIND=1`
   alone accounts for ~20 s: on every path where the stub *does not* bind
   (failed loads, clamped bus, rate-limited escalation), each of the three
   attempts now waits out a full 1 s `wait_bound` deadline. `BACKOFF_MAX=1`
   plus the 0.1 s sleeps account for the other ~21 s.
2. **The widened lock margins cost nothing.** Experiment B keeps the 3 s / 2.5 s
   lockers — the whole point of R3-3 — and still finishes in 5.9 s. So the
   margin fix and the speed fix are not in tension; only the two knobs are.

**My own error, for the record.** Revision 3's recommendation said to keep
`WAIT_BIND=1` because "the loop still exits immediately once the stub binds, so
it costs ~nothing". That is true only where a bind is expected. On the
never-binds paths it costs 1 s per attempt, which is exactly what happened. The
advice was incomplete and the direct cause of this regression; Experiment B is
the corrected recommendation.

Fix: set `WAIT_BIND=0` and `BACKOFF_MAX=0` again (keep whatever internal sleeps
you prefer — Experiment B used 0.02 s and still measured the intended
behaviour). If the intent was to prove the poll loop works, that belongs in a
dedicated test — see R4-2.

### R4-2 — `wait_bound()`'s polling loop is still never executed — **Low (unchanged from Rev 3)**

`reload()`'s stub binds both amps synchronously inside the `modprobe` call, so
by the time `wait_bound "$WAIT_BIND"` runs, `both_bound` is already true and the
loop body (`sleep 0.25` + re-check) never runs in any of the 32 checks —
regardless of whether `WAIT_BIND` is 0 or 1. The poll-to-detect behaviour that
v1.3.0 introduced is therefore still unverified.

A `state/bind-after-poll` stub that creates the driver files on, say, the third
`both_bound` check would cover it in a few hundred milliseconds, which is
cheaper than the ~20 s that `WAIT_BIND=1` spends globally for no coverage gain.

---

## 5. Other observations

* **R4-3 (Low) — one stale sentence in the README.** `README.md:186` says the
  suite "extracts the helper … from `speakers.sh`". Since `21a3e48` it copies
  `scripts/cs35l41-helper.sh` directly (`tests:25`) and extracts the embedded
  copy only for the parity assertion (`tests:273`). The sentence understates
  what the suite actually does — and testing the shipped artifact is the
  improvement. Worth correcting in a file that is otherwise meticulously
  accurate.
* **Informational — deleting published tags.** `v1.3.0` and `v1.3.1` were
  removed locally and remotely. For a personal fix like this that is the right
  call versus keeping a mapping that is false, and I verified the removal
  reached the remote. The only cost is the general one: anyone who already
  fetched those refs keeps a stale tag that no longer exists upstream.
* **G-8 (Low, by design, carried forward)** — the watchdog can suspend the whole
  machine. Gated by an explicit flag, uptime < 10 min and a 180 s rate limit,
  with a `/run`-scoped stamp, and covered by dedicated tests. Documented and
  deliberate; not a defect.
* **Informational** — `reload()` returns 2 both for a genuinely in-use module
  and for an unload that failed while the module remained listed. The log line
  says "in use (audio playing?)" and the helper exits 2, which the README
  documents as "module in use". Accurate for the reachable case on this
  hardware (it runs as root under systemd, so permission is not a factor);
  noted only because the message could mislead if the module were held for
  another reason.

---

## 6. Prioritised recommendations

| # | Action | Addresses | Effort |
|---|---|---|---|
| 1 | Set `WAIT_BIND=0` and `BACKOFF_MAX=0` in the sandbox rewrite; keep the 3 s / 2.5 s lockers | R4-1 | S |
| 2 | Add a delayed-bind stub so `wait_bound()`'s poll loop is actually exercised | R4-2 | S |
| 3 | Correct `README.md:186` to say the suite runs the shipped `scripts/cs35l41-helper.sh` and parity-checks the embedded copy | R4-3 | S |

---

## 7. Bottom line

This revision closed three of four items cleanly, and the two that mattered most
were worth doing: the released tags no longer make claims their commits
contradict, and `sudo make install` no longer fails on a machine that lacks a
developer linter. The fallback helper now explains itself. Those are real,
verifiable improvements, and `CI / tooling` has reached the top of the range.

The one misstep is the test suite: it now takes 46.9 s, which is back past the
default 30 s command timeout and undoes the previous revision's best
improvement. The controlled experiment shows this is not a design conflict —
the contention margins that Revision 3 asked for cost nothing at all (5.9 s with
them in place), and the whole regression is two sed substitutions. That also
means my Revision 3 advice on this point was wrong, and I have said so above
rather than leaving the implementer to infer it from the numbers.

**9.5 / 10.** Three findings remain, all small, all with a one-line fix. Do the
first — it restores the 6 s suite without touching the margins — and this is at
the top of the range with nothing left that I would file.

*This report replaces the Revision 3 text committed in `38890d1`; it is
currently uncommitted.*
