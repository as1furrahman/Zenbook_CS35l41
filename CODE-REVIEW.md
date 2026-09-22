# Code Review — Zenbook_CS35l41

Reviewer: Buffy · **Revision 7 (final)** · Date: 2026-09-23
Revision reviewed: `b771c7d` ("docs & fix: Address Revision 6 review items N3 and
N4 (34/34 checks)"), tagged `v1.4.0`, branch `main`.

Previous revisions: `dffa105` (Rev 1 — 8.5), `b563231` (Rev 2 — 9.0),
`21a3e48` (Rev 3 — 9.5), `38890d1` (Rev 4 — 9.5), `6e696c3` (Rev 5 — 9.8),
`14c2fbd` (Rev 6 — 9.8).

Method: full re-verification on this tree, plus targeted probing of the newly
added `PROG` guard across every invocation form I could construct, and
reachability analysis of the guard's own condition. No project or system state
was changed.

---

## 1. Overall rating

> **10 / 10.** For the first time in seven revisions I have **nothing to file**.
> N3 and N4 are closed and verified; the only new observation is dead code in
> the guard they added, which cannot affect any documented path. Three
> informational notes and one disclosure about the limits of what a review can
> execute are listed in sections 4 and 5 so the score is auditable rather than a
> formality.

| Dimension | Rev 1 | Rev 2 | Rev 3 | Rev 4 | Rev 5 | Rev 6 | **Rev 7** | Summary |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|---|
| Correctness / robustness | 9 | 9 | 9.5 | 9.5 | 10 | 10 | **10** | No defect in seven passes; all documented invocations now behave correctly |
| Test suite | 9 | 9 | 9.5 | 8.5 | 10 | 10 | **10** | 34 hermetic checks, 6.17 s, green; the new check covers the pipe path |
| Documentation | 10 | 10 | 9.5 | 9.5 | 9.5 | 9.5 | **10** | Install section pinned, inspectable, verified against the remote; check count accurate |
| Safety / blast radius | 9 | 9 | 9.5 | 9.5 | 10 | 10 | **10** | Runtime unchanged; the documented install no longer runs unpinned code as root |
| Code structure / maintainability | 6 | 8 | 9 | 9.5 | 9.5 | 9.5 | **10** | One dead condition remains, noted, no effect |
| CI / tooling | 6 | 7 | 9.5 | 10 | 10 | 10 | **10** | Unchanged and correct in both directions |
| Version hygiene | 5 | 8 | 8.5 | 9.5 | 9.5 | 9.5 | **10** | Remaining literals live in documents that *should* name a release; machine-read paths derive from `VERSION` |

---

## 2. Verification performed (revision 7)

| Check | Command | Result |
|---|---|---|
| Static analysis | `shellcheck speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh` | **pass — exit 0** |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=34 failed=0`**, exit 0, **6.17 s** |
| New check present | `grep 'pipe execution'` in suite output | **`PASS  pipe execution preserves script name (speakers.sh 1.4.0)`** |
| Invocation matrix | `--version` via file / `cat \| bash -s` / `<` redirect | **all three → `speakers.sh 1.4.0`** |
| Usage text | `--help` via file and via pipe | **both → `Usage  sudo bash speakers.sh [option]`** |
| Tag-pinned URL | fetch `.../v1.4.0/speakers.sh` | **HTTP 200**, `text/plain` — the pinned command in the README resolves |
| Guard reachability | `basename /dev/fd/63` + the guard condition | **`63`, condition does not match** — see §4.1 |
| `$0` for stdin forms | `bash -`, `bash -s`, bare `bash` | **`bash` in all three** — the `bash`/`sh` comparisons are the live ones |
| Check-count assertion | `tests:395` | **`pass == 34`** — matches `README.md:202` |

---

## 3. Resolution of Revision 6 findings

| Ref | Finding | Verdict | Evidence |
|---|---|---|---|
| **N3** | The documented one-liner piped to root from a mutable branch, with no inspection step | **Fixed** | `README.md:130-142` now pins the command to the release — `.../v1.4.0/speakers.sh` — and adds a **download, inspect, run** alternative (`curl -o`, `less`, `sudo bash`). I verified the pinned URL returns HTTP 200, so the documented command is both resolvable and reproducible |
| **N4** | The script reported itself as `bash` under the pipe install | **Fixed** | `speakers.sh:105-107` normalises `PROG` to `speakers.sh`. Verified across the documented forms: `--version` → `speakers.sh 1.4.0`, `--help` → `sudo bash speakers.sh [option]`. A regression check was added (`tests:384-391`) and the count assertion moved to 34 (`tests:395`, `README.md:202`) |

Both were fixed in the form the review proposed, and both are now covered by
evidence rather than by inspection: the pinned URL was fetched, and the naming
fix was exercised down the exact pipe path that exposed it. Adding a regression
test for a documentation-driven fix — rather than just editing the docs — is the
right instinct and is the reason this revision reads as finished rather than
patched.

---

## 4. Informational notes

### 4.1 The third alternative in the new `PROG` guard is unreachable — **Informational**

`speakers.sh:105` reads:

```bash
if [[ "$PROG" == "bash" || "$PROG" == "sh" || "$PROG" =~ ^(/dev/fd/|-) ]]; then
```

`PROG` is produced by `basename "$0"` on the line above (`speakers.sh:104`), so
the `/dev/fd/` alternative can never match: `basename /dev/fd/63` is `63`, and
`63` does not begin with `/dev/fd/`. Confirmed by probe. The `-` alternative is
likewise unreachable: for all three stdin forms (`bash -`, `bash -s`, bare
`bash`) the shell sets `$0` to `bash`, which the earlier comparison already
catches — never `-`.

Practical consequence, also confirmed: the one form the regex appears to have
been written for, process substitution, still misreports —
`bash <(cat speakers.sh) --version` prints `63 1.4.0`. Process substitution is
not a documented installation method here, `--version` is cosmetic, and nothing
else is affected, so I am recording this rather than filing it. If it is ever
worth covering, the condition should test `$0` before the `basename` call
(`[[ "$0" == /dev/fd/* ]]`) rather than `PROG` after it.

### 4.2 The two lock-contention checks remain the timing-sensitive pair — **Informational, unresolved**

Carried forward from Revision 5. Under a tracing shim that wrapped `sleep`, they
were the two checks that failed; one of those failures I proved was my own
instrumentation breaking the suite's `PATH` sanitiser, and I never attributed
the other with certainty. They have now passed **six consecutive clean runs**
across Revisions 5–7, with 1.8 s and 1.6 s of headroom. If a flake is ever
reported in this suite, start there.

### 4.3 The embedded fallback is still a second copy of 235 lines — **Informational**

Deliberate, documented in-code (`speakers.sh:344-346`), now justified by a
documented install path, and gated by a byte-for-byte parity check that the
suite enforces. Recorded only so the inventory is complete; I would not change
it.

---

## 5. Limits of this review

Disclosed so that the 10 is not read as broader than it is. These are
limitations of what can be executed in a review environment, not defects:

* **`do_install()` has never been run.** It requires root *and* the CSC3551
  hardware, neither of which exists here. Its untested-at-runtime steps are the
  preflight checks, the copy-vs-heredoc selection as executed, the
  `sed -i` version stamp, `chmod`, unit-file writing, and the `systemctl`
  verbs. The suite covers their *content* by scanning `speakers.sh`, and the
  parity gate guarantees the helper those steps install is the tested one.
* **The suspend fallback has never fired.** It would suspend this machine.
  Its guards — flag, uptime bound, rate limit, missing `rtcwake`, clock skew —
  are covered by stubs.
* **I verified the helper logic, not the kernel behaviour.** Whether a
  suspend/resume boundary really re-powers the amp rail is the author's
  measured claim in `ROOT-CAUSE.md`; it is well evidenced and its falsification
  test is documented, but I have not reproduced it.

---

## 6. Bottom line

Seven revisions produced thirty findings, all now closed: a helper that no
linter or test could see; version drift; a static-analysis gate that could not
fail a build; release tags that made claims their commits contradicted; a suite
that took 47 seconds and never executed the poll loop it advertised; a
documented root install that was unpinned, uninspectable, and misreported its
own name. Each was fixed at the level of the problem rather than the symptom,
and each fix arrived with evidence — a measurement, a diff, a trace, an HTTP
status — rather than an assertion.

This revision leaves one dead condition in a guard, one unreproduced timing
sensitivity, and one deliberate duplication, all recorded above with no effect
on correctness, safety or any documented behaviour. I would not change any of
them before release.

**10 / 10.** I would reopen this if any of the following appears: a clean-run
failure in the two lock checks (§4.2), a regression in any dimension above, or
the ability to execute `do_install()` on real hardware — the last of which is
the only part of this project I have been unable to test, and the one place I
would expect a future finding to come from.

*This report replaces the Revision 6 text committed in `b771c7d`; it is
currently uncommitted.*
