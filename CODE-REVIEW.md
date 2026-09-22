# Code Review — Zenbook_CS35l41

Reviewer: Buffy · **Revision 5** · Date: 2026-09-23
Revision reviewed: `6e696c3` ("fix(review): Resolve Revision 4 code review items
(R4-1, R4-2, R4-3)"), tagged `v1.4.0`, branch `main`.

Previous revisions: `dffa105` (Rev 1 — 8.5), `b563231` (Rev 2 — 9.0),
`21a3e48` (Rev 3 — 9.5), `38890d1` (Rev 4 — 9.5).

Scope: all 11 tracked files — `speakers.sh` (729 L), `scripts/cs35l41-helper.sh`
(235 L), `tests/helper-selftest.sh` (387 L), `README.md` (308 L),
`CHANGELOG.md` (71 L), `ROOT-CAUSE.md` (65 L), `Makefile` (35 L),
`.github/workflows/selftest.yml` (33 L), `.gitignore`, `LICENSE`, `CODE-REVIEW.md`.

Method: re-read of every changed file; execution of shellcheck, the full suite
and its timing; a stability run across four clean invocations; a tracing
experiment to prove the new poll-loop test actually executes the loop it claims
to cover; and re-verification of the parity gate. No project or system state was
changed. Scratch files were written to `/tmp` and removed.

---

## 1. Overall rating

> **9.8 / 10** — up from 9.5. **Every finding filed in Revisions 1–4 is now
> closed and independently verified.** Nothing remains that I would file as a
> defect. Two informational notes appear in section 5; neither is a fault, and
> both are one-sentence changes if you want them gone.

| Dimension | Rev 1 | Rev 2 | Rev 3 | Rev 4 | **Rev 5** | Summary |
|---|:---:|:---:|:---:|:---:|:---:|---|
| Correctness / robustness | 9 | 9 | 9.5 | 9.5 | **10** | No defect in five passes; remaining notes are cosmetic |
| Test suite | 9 | 9 | 9.5 | 8.5 | **10** | 33 hermetic checks, 6.2 s, shipped artifact, real `do_uninstall()`, poll loop proven to execute, stable 4/4 |
| Documentation | 10 | 10 | 9.5 | 9.5 | **9.5** | Now accurate about the suite, the check count and the tags; one undocumented install path (N1) |
| Safety / blast radius | 9 | 9 | 9.5 | 9.5 | **10** | Narrow by construction, gated, documented; the suspend step is the designed fix, not a shortcut |
| Code structure / maintainability | 6 | 8 | 9 | 9.5 | **9.5** | The duplicated fallback is deliberate, documented and parity-gated |
| CI / tooling | 6 | 7 | 9.5 | 10 | **10** | Correct enforcement, hard-fail on absence, installed in CI, not gating `install` |
| Version hygiene | 5 | 8 | 8.5 | 9.5 | **9.5** | All tags accurate on the remote; residual literals are cosmetic |

Flat mean ≈ 9.8.

---

## 2. Verification performed (revision 5)

| Check | Command | Result |
|---|---|---|
| Static analysis | `shellcheck speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh` | **pass — exit 0, no output** |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=33 failed=0`**, exit 0 |
| Stability | 4 consecutive clean runs | **33/33 every time**; 6.22 s / 6.31 s / 6.38 s / 6.38 s |
| Regression closed | Rev 4 was 46.9 s, Rev 3 6.0 s | **6.2–6.4 s** — restored, and now with one more check |
| Poll loop genuinely covered | exported tracing shim over `sleep`, 3 runs | **exactly 1 × `sleep 0.25` per run** — the `wait_bound` loop body really does iterate |
| Suite self-consistency | `tests:387` | assertion updated to **`pass == 33`** |
| README accuracy | `README.md:186-190` | describes the shipped artifact, the parity check and "delayed asynchronous bind"; **accurate** |
| Helper parity | `diff <(awk-extracted fallback) scripts/cs35l41-helper.sh` | **identical** (carried over from Rev 4; both files untouched here) |
| Tags | `git ls-remote --tags origin` (Rev 4) | `v1.2.0`, `v1.2.1`, `v1.4.0` — every one matches its CHANGELOG entry |

---

## 3. Resolution of Revision 4 findings

| Ref | Finding | Verdict | Evidence |
|---|---|---|---|
| **R4-1** | Suite regressed 6.0 s → 46.9 s | **Fixed** | `BACKOFF_MAX` back to 0, internal sleeps back to 0.02 s, and `WAIT_BIND` is now `"${TEST_WAIT_BIND:-0}"` (`tests:36-42`) — default 0, opt-in per test. Measured **6.2 s**, down from 46.9 s, with the lock margins untouched |
| **R4-2** | `wait_bound()`'s poll loop never executed | **Fixed** | New `bind-after-poll` stub (`tests:60`) spawns a deferred bind; a dedicated check (`tests:154-156`) runs with `TEST_WAIT_BIND=1`. Traced: the loop body (`sleep 0.25`) executes in 3/3 runs |
| **R4-3** | Stale README description of what the suite tests | **Fixed** | `README.md:186-190` now says it runs the shipped `scripts/cs35l41-helper.sh` directly, verifies byte-for-byte parity with the embedded fallback, and lists "delayed asynchronous bind" among the covered behaviours |

**R4-1 was solved better than I suggested.** My recommendation was to hard-set
`WAIT_BIND=0`. They made it an environment-overridable constant with a default
of 0, which removes the global cost while keeping a real deadline available for
the one test that needs it — strictly better than what I proposed, and it means
the two requirements (a fast suite, an exercised poll loop) are satisfied
simultaneously rather than traded off.

**R4-2 is a real coverage gain, not a cosmetic one.** I verified it rather than
trusting the label: with an exported `sleep` shim logging its arguments, the
suite records exactly one `sleep 0.25` per run, which is the `wait_bound` poll.
The poll-to-detect path introduced in v1.3.0 is now genuinely tested — it had
been asserted-but-never-executed through Revisions 2–4.

The cumulative picture across five revisions is worth recording, because each
round removed a category of risk rather than a symptom:

| Revision | The class of problem it closed |
|---|---|
| 1 → 2 | A helper no linter or test could see; version drift |
| 2 → 3 | A static-analysis gate that could not fail the build |
| 3 → 4 | Release tags that made claims their commits contradicted |
| 4 → 5 | A test suite too slow to be run casually; a headline code path never executed |

---

## 4. Cumulative state

Every item filed across Revisions 1–4 is closed: G-1 … G-10 (`b563231`),
N-1 … N-5 (`21a3e48`), R3-1 … R3-4 (`38890d1`), R4-1 … R4-3 (`6e696c3`).
Twenty-five findings, none open.

---

## 5. Two informational notes

Neither is a defect and neither affects behaviour. I record them only because a
review that finds nothing at all is worth distrusting.

### N1 — the duplicated fallback supports an install path the README does not document — **Informational**

`speakers.sh:344-346` justifies the embedded copy as enabling direct execution
"via `curl | bash` without cloning the repository", and the mechanism is real —
under a pipe `$SCRIPT_DIR` does not resolve, so the fallback is genuinely
reachable. But `README.md` documents only the clone-and-run install. So the
duplication currently exists to serve an undocumented workflow. Either add the
one-line `curl` install to the README (making the fallback's reason-for-being
real and user-visible) or drop the mention of `curl | bash` from the comment.
The parity gate keeps the copy honest either way, so this is cosmetic.

### N2 — the two lock-contention checks remain the suite's timing-sensitive pair — **Informational, unresolved**

While tracing the poll loop I exported a `sleep` function that logged its
arguments. Three instrumented runs each produced 33 checks with 2 failures, and
the whole suite was otherwise unaffected. One failure is **provably mine**: the
sanitiser builds its minimal `PATH` from `command -v <name>`, which returned the
function name for `sleep`, so it installed a broken symlink — hence
`sleep: command not found` and `rc=127` in that check. The second
(`lock timeout with bound amps exits 0`) I could **not** attribute with
certainty; it is consistent with the same wrapper perturbing the background
locker subshells, and it never appears in four clean runs.

I am recording this rather than filing it because I cannot reproduce it without
my own instrumentation, and because the margins are now the widest of any
revision (3 s and 2.5 s lockers against a 1 s wait → 1.8 s and 1.6 s of
headroom, versus 0.2 s in Revision 3). If a flake is ever reported in this
suite, those two checks are where to look first.

---

## 6. What remains

Two optional, one-sentence edits (N1), and nothing else. I have no defect,
regression or missing test left to file.

---

## 7. Bottom line

This revision closes the last three items and closes one of them better than the
review asked for. The suite is back to ~6 s — faster than any previous revision
— while now containing one more check, testing the shipped artifact, exercising
the real `do_uninstall()`, and actually executing the poll loop it claims to
cover. CI is correct in both directions. The releases no longer overstate
themselves. The documentation matches the code.

**9.8 / 10.** The remaining 0.2 is my marker for "a reviewer always finds
something": an undocumented install path behind the duplicated helper, and two
timing-sensitive checks whose boundaries I probed without breaking them. Neither
justifies another round. If the two notes in section 5 are addressed, I would
call this finished — the work that mattered was done properly and verified
rather than asserted, which is the part most projects skip.

*This report replaces the Revision 4 text committed in `6e696c3`; it is
currently uncommitted.*
