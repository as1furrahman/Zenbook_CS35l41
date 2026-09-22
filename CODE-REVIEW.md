# Code Review — Zenbook_CS35l41

Reviewer: Buffy · **Revision 3 (independently re-verified)** · Date: 2026-09-23
Revision reviewed: `21a3e48` ("fix(review): Resolve Revision 2 code review items
(N-1, N-2, N-3, N-5, G-4)"), tagged `v1.4.0`, branch `main`.

Previous revisions: `dffa105` (Rev 1 — 8.5/10), `b563231` (Rev 2 — 9.0/10).

> **Note on provenance.** This file was rewritten in `21a3e48` into a
> self-assessment that awarded 10/10. That text was not written by me and I
> cannot sign off on its conclusions. This revision restores an independent
> review; every claim below — the author's and mine — was re-checked from
> scratch against the working tree, the git history, and the remote.

---

## 1. Overall rating

> **9.5 / 10** — up from **9.0**. All five Revision 2 findings are genuinely
> fixed and verified, including the two that mattered (the lint gate and the
> tested-vs-shipped helper). Four small items remain, three of which were
> *introduced* by this revision.

| Dimension | Rev 1 | Rev 2 | **Rev 3** | Summary |
|---|:---:|:---:|:---:|---|
| Correctness / robustness | 9 | 9 | **9.5** | No defects found in three passes; GNU-tool assumptions unchanged and documented |
| Test suite | 9 | 9 | **9.5** | 32 checks in **6.0 s** (was 55.7 s); tests the shipped helper and the real `do_uninstall()` — but two timing paths are no longer exercised |
| Documentation | 10 | 10 | **9.5** | Excellent, except `CHANGELOG:8` asserts a tag mapping that is wrong for 2 of 5 tags |
| Safety / blast radius | 9 | 9 | **9.5** | Unchanged, narrow by construction; the suspend fallback remains the one heavy action |
| Code structure / maintainability | 6 | 8 | **9** | Standalone helper is now the tested artifact; the embedded copy still exists in parallel |
| CI / tooling | 6 | 7 | **9.5** | shellcheck now enforced correctly and installed explicitly; the gate also blocks `make install` |
| Version hygiene | 5 | 8 | **8.5** | Single-source `VERSION`; tags now exist and are pushed — but two are mismapped |

A flat mean of the dimensions is ≈ 9.3. 10/10 is not warranted: three of the
four open items are regressions this revision introduced, and one of the
verification claims in the revision's own report does not hold up.

---

## 2. Verification performed (revision 3)

Run by me, in this environment, against `21a3e48`.

| Check | Command | Result |
|---|---|---|
| Static analysis (the Rev 2 blocker) | `shellcheck speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh` | **pass — exit 0, no output** (shellcheck 0.10.0) |
| shellcheck aggregation | `… \| shellcheck -s bash speakers.sh scripts/… -` with one deliberately bad input | **exit 1** — one failing input fails the whole invocation, so `Makefile:14` genuinely enforces findings |
| Lint guard when tool absent | `sh -c 'command -v shellcheck >/dev/null 2>&1 \|\| { echo ERROR; exit 1; }'` | **exit 1** — hard failure, no silent skip |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=32 failed=0`**, exit 0 |
| Suite duration | `time bash tests/helper-selftest.sh` | **6.02 s** wall (was 55.7 s — 9.3× faster) |
| Helper parity | `diff <(awk-extracted embedded copy) scripts/cs35l41-helper.sh` | **identical** |
| Tested-vs-shipped helper | `tests:25` | copies `scripts/cs35l41-helper.sh` — the shipped artifact is now the tested one |
| Real uninstall exercised | `tests:301-352` | `eval`s `do_uninstall()` from `speakers.sh` with stubbed `systemctl`, asserts disable/reset/reload and full purge |
| Tags (local + remote) | `git tag -l`, `git ls-remote --tags origin` | 5 tags present **and pushed**: v1.2.0, v1.2.1, v1.3.0, v1.3.1, v1.4.0 |
| Tag → content mapping | `git show <tag>:speakers.sh \| grep -c …` | **2 of 5 mismapped** — see R3-1 |
| `make ci` end-to-end | — | **not run** — `make` is not installed here; both recipe lines were reproduced and verified individually |

Claims in the revision's own report, checked: "0 warnings, 0 errors" —
**true**. "6.25 s" — **true** (6.02 s here). "tests exercise the real shipped
helper and real `do_uninstall()`" — **true**. "Lint recipe failure
propagation passes" — **true**. "Git release tag mapping — pass" —
**false for v1.3.0 and v1.3.1**.

---

## 3. Resolution of Revision 2 findings

| Ref | Finding | Verdict | Evidence |
|---|---|---|---|
| **N-1** | shellcheck findings masked; missing tool passed silently | **Fixed** | `Makefile:13` hard-fails when the tool is absent; `Makefile:14` passes all three files to one invocation, which exits non-zero if any file has findings (verified with a deliberately bad input). CI installs shellcheck explicitly (`.github/workflows/selftest.yml:20-23`) |
| **N-2** | tests exercised the embedded copy, not the shipped helper | **Fixed** | `tests:25` copies `scripts/cs35l41-helper.sh` directly; the sandbox rewrite is applied to that file; the embedded copy is retained only as a parity-gated fallback (`tests:273-274`) |
| **N-3** | uninstall test re-implemented the deletion list | **Fixed** | `tests:301-352` extracts and runs the real `do_uninstall()`, stubbing `need_root`/`banner`/`step`/`ok`/`printf`/`systemctl`, then asserts the systemctl verbs and that every file (including both `.old*` backups and `LEGACY_LOCK`) is gone. This is the right shape of test |
| **G-4** | suite spent 56 s sleeping | **Fixed** | 6.02 s measured. See R3-3 for the fidelity cost |
| **N-5** | CHANGELOG documented releases that were never tagged | **Fixed (with a caveat)** | All five tags now exist locally **and on the remote**. Caveat: two point at commits that do not contain the documented changes — see R3-1 |

Also carried over and still holding: the suite's final assertion
`[[ "$failed" == 0 && "$pass" == 32 ]]` (`tests:383`) keeps the check count and
the README honest.

The extracted `LEGACY_LOCK` variable (`speakers.sh:122`, used at `:312`) is a
small readability win over the previous inline `/var/lock/...` literal, and the
test covers it.

---

## 4. Remaining issues (revision 3)

### R3-1 — two of the five tags point at commits that lack the documented changes — **Low/Medium**

`CHANGELOG.md:8` states that the tags "map directly to releases in this
changelog". For two of them that is not true:

| Tag | Commit | CHANGELOG says | Commit actually contains |
|---|---|---|---|
| `v1.3.0` | `1959ab9` "v3: ACPI power-cycle (D3cold<->D0) between probe retries" | *Added* `--escalate` watchdog escalation, `wait_bound()` 250 ms polling, clamped-bus short-circuit | **0** occurrences of `--escalate`; **0** of `wait_bound` |
| `v1.3.1` | `7192e7c` "Document ACPI/EC root-cause analysis…" | *Fixed* watchdog started with `enable --now` | **0** occurrences of `enable --now cs35l41-watchdog` |

The changes those entries describe actually landed in `cdd8fe1` ("v1.4.0:
Harden recovery ladder…"). So tagging historical commits is a real
improvement over leaving the CHANGELOG unverifiable — but as it stands it
creates a *verifiable falsehood*, which is worse than an honest gap. Either
move `v1.3.0`/`v1.3.1` to commits that contain those features, or reword
`CHANGELOG.md:8` to say tags are approximate historical markers.

`v1.2.0` (`a3590ad`) and `v1.2.1` (`92fe37f`) map correctly; `v1.4.0`
(`21a3e48`) matches.

### R3-2 — the new lint gate blocks the documented install path — **Low/Medium**

`Makefile:13` makes shellcheck a hard requirement of `lint`, and `lint` is a
prerequisite of `test` (`:16`), `install` (`:22`) and `reinstall` (`:25`).
On a machine without shellcheck — the common case for someone who just cloned
this repo because their speakers don't work — `sudo make install` now aborts
with `ERROR: shellcheck not found on PATH` before doing anything.

`README.md:155-159` still advertises `make test` and `sudo make install`, and
shellcheck is not listed as a prerequisite anywhere. Two reasonable fixes:
drop `lint` from the `install`/`reinstall` prerequisites (it is a developer
gate, not an installer requirement), or document shellcheck under "Notes" next
to `bash`/`systemd`/`kmod`. Requiring it for `make test` is defensible;
requiring it to *install* is not.

### R3-3 — the 9× speedup cost test fidelity and contention margin — **Low/Medium**

The speedup is welcome, but it was bought by weakening what the suite actually
exercises:

* `tests:36-37` set `WAIT_BIND=0` and `BACKOFF_MAX=0`. With `WAIT_BIND=0`,
  `wait_bound()`'s deadline is `SECONDS + 0`, so its polling loop body
  **never executes** — the 250 ms poll-to-detect path is now untested, as is
  the capped linear backoff.
* `tests:41-42` rewrite the helper's internal `sleep 0.5` and `sleep 1` to
  `sleep 0.02`, so the post-reload settle and post-resume waits no longer
  resemble production timing.
* Contention margins shrank sharply. `tests:233` holds the lock for
  `sleep 1.4` while the helper waits `LOCK_WAIT=1` and is started after
  `sleep 0.2` — a **0.2 s** margin (previously 3.8 s). `tests:248` leaves
  **0.5 s** (previously 1.1 s). Because `sleep` guarantees only a *minimum*,
  a scheduling delay of >0.2 s in the runner flips the first assertion
  ("amplifiers still unbound", `tests:239`) to a false failure. That is a
  plausible flake on a loaded CI runner.

Suggestions: keep `WAIT_BIND=1` (the loop still exits immediately once the stub
binds, so it costs ~nothing), and give the lockers ~3 s so the margin stays
comfortable while the suite stays under 10 s.

### R3-4 — the helper still exists twice — **Low**

`scripts/cs35l41-helper.sh` and the embedded heredoc in `speakers.sh` are both
235 lines and are byte-identical (verified). This is now a deliberate design
choice — the fallback lets `speakers.sh` work if it is copied somewhere without
`scripts/` — and it is parity-gated at `tests:273-274`, so drift cannot go
unnoticed. I still record it because 235 lines of logic duplicated in one
repository is a standing maintenance cost, and the heredoc copy is structurally
invisible to shellcheck. Acceptable as-is, provided the parity test stays.

### Carried forward

* **G-8 (Low, by design)** — the watchdog may suspend the whole machine. Well
  gated (explicit flag, uptime < 10 min, 180 s rate limit, `/run`-scoped
  stamp) and thoroughly tested. Noted for completeness, not as a defect.

---

## 5. Prioritised recommendations

| # | Action | Addresses | Effort |
|---|---|---|---|
| 1 | Re-point `v1.3.0`/`v1.3.1` at commits containing the documented changes, or reword the `CHANGELOG.md:8` note | R3-1 | S |
| 2 | Drop `lint` from the `install`/`reinstall` prerequisites, or document shellcheck as a prerequisite in the README | R3-2 | S |
| 3 | Restore `WAIT_BIND=1` and widen the lock-contention sleeps to ~3 s | R3-3 | S |
| 4 | Either delete the embedded helper fallback or leave a comment stating it is intentional and parity-tested | R3-4 | S |

---

## 6. Bottom line

This revision does the hard parts properly. The lint gate — the finding that
mattered most, because it was the one the previous revision only appeared to
fix — is now correct in both directions: findings fail the build, and a missing
tool fails loudly instead of passing silently. I verified that by running
shellcheck myself (exit 0 across all three files) and by proving with a
deliberately bad input that a single failing file turns the combined invocation
non-zero. The suite now tests the artifact that actually ships and runs the real
`do_uninstall()` rather than a copy of it, which is exactly what Rev 2 asked
for, and the runtime fell from 55.7 s to 6.0 s.

What it is not is 10/10. Two of the five newly pushed tags are pinned to commits
that do not contain the changes they claim to release, the lint gate now blocks
the README's own `sudo make install` on a machine without shellcheck, and the
speedup silently retired two timing paths while cutting the lock-contention
margin to 0.2 s. All four items are small and cheap; fix them and I would have
nothing left to file. Until then, **9.5 / 10** — an excellent, well-tested,
well-documented tool, with four loose ends and one inaccurate claim.

*This revision of the report is uncommitted; the file was previously overwritten
in `21a3e48`.*
