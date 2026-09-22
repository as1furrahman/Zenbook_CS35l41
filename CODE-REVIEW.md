# Code Review — Zenbook_CS35l41

Reviewer: Buffy · **Revision 6** · Date: 2026-09-23
Revision reviewed: `14c2fbd` ("docs: Document one-line curl install in README.md
(closes N1) and track Revision 5 review"), tagged `v1.4.0`, branch `main`.

Previous revisions: `dffa105` (Rev 1 — 8.5), `b563231` (Rev 2 — 9.0),
`21a3e48` (Rev 3 — 9.5), `38890d1` (Rev 4 — 9.5), `6e696c3` (Rev 5 — 9.8).

Scope: all 11 tracked files. This commit is documentation-only
(`README.md` +8 lines, plus this report); `speakers.sh`,
`scripts/cs35l41-helper.sh`, `tests/helper-selftest.sh`, `Makefile` and the
workflow are byte-identical to Revision 5.

Method: re-ran the full verification on the current tree; then, because the
commit documents a **new supported install path**, exercised that path rather
than assuming it: identity of the remote, HTTP resolution of the documented URL,
execution of the real script when read from a pipe, and a proof of the mechanism
the install path depends on. Scratch files were written to `/tmp` and removed.

---

## 1. Overall rating

> **9.8 / 10 — unchanged, for the second time in a row but for opposite
> reasons.** N1 is closed and verified. Documenting the no-clone install
> surfaced two small, user-visible items on that path (N3, N4) that did not
> exist when the path was undocumented. One closed, two opened, both trivial.

| Dimension | Rev 1 | Rev 2 | Rev 3 | Rev 4 | Rev 5 | **Rev 6** | Summary |
|---|:---:|:---:|:---:|:---:|:---:|:---:|---|
| Correctness / robustness | 9 | 9 | 9.5 | 9.5 | 10 | **10** | Unchanged; no defect in six passes |
| Test suite | 9 | 9 | 9.5 | 8.5 | 10 | **10** | 33 hermetic checks, 6.2 s; unchanged and still green |
| Documentation | 10 | 10 | 9.5 | 9.5 | 9.5 | **9.5** | One-liner added and URL verified; the command as written pipes to root from a mutable branch (N3) and misreports its own name (N4) |
| Safety / blast radius | 9 | 9 | 9.5 | 9.5 | 10 | **10** | Runtime behaviour unchanged |
| Code structure / maintainability | 6 | 8 | 9 | 9.5 | 9.5 | **9.5** | Unchanged |
| CI / tooling | 6 | 7 | 9.5 | 10 | 10 | **10** | Unchanged |
| Version hygiene | 5 | 8 | 8.5 | 9.5 | 9.5 | **9.5** | Unchanged |

Flat mean ≈ 9.8.

---

## 2. Verification performed (revision 6)

| Check | Command | Result |
|---|---|---|
| Static analysis | `shellcheck speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh` | **pass — exit 0** |
| Full suite | `bash tests/helper-selftest.sh` | **pass — `passed=33 failed=0`**, exit 0, **6.17 s** |
| Remote identity | `git remote -v` | `as1furrahman/Zenbook_CS35l41` — **matches the owner/repo in the new URL**; branch `main` matches too |
| Documented URL resolves | fetch `raw.githubusercontent.com/.../main/speakers.sh` | **HTTP 200**, `text/plain`, serves the current script — no typo |
| Tag-pinned URL resolves | fetch `.../v1.4.0/speakers.sh` | **HTTP 200** — pinning to the release tag is available and would work |
| Script runs from a pipe | `cat speakers.sh \| bash -s -- --version` / `--status` / `--help` | **all exit 0**, table renders correctly |
| Heredoc survives a pipe | synthetic: `printf '… heredoc …' \| bash` | **bash continues past the heredoc and completes** — the mechanism the install path relies on |
| Name reporting under a pipe | compare `--version` from file vs pipe | file → `speakers.sh 1.4.0`; pipe → **`bash 1.4.0`** (see N4) |

I did not install anything and cannot install anything here (no CSC3551
hardware, and installing would change system state), so the *heredoc selection*
branch in `do_install()` is verified by the parity test rather than by me; what
I verified is that the path is mechanically sound and the URL is correct.

---

## 3. Resolution of N1

| Ref | Finding | Verdict | Evidence |
|---|---|---|---|
| **N1** | The duplicated fallback served an install path the README never documented | **Fixed** | `README.md:130-136` now leads with a one-line `curl … \| sudo bash` install under a "One-line install (no clone needed)" heading, with the clone route kept below. The fallback's in-code justification (`speakers.sh:344-346`) is now backed by user-facing documentation, and the URL's owner, repo and branch all match the actual remote |

This is the right resolution of the two options I offered. The fallback now
serves a documented workflow instead of a hypothetical one, and the parity gate
guarantees the copy it installs is the same 235 lines the test suite runs.

---

## 4. Two notes on the newly documented path

Both are one-line fixes, and both only matter because the pipe install is now
advertised.

### N3 — the one-liner pipes into root from a mutable branch, with no inspection step — **Low**

```bash
curl -fsSL https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/main/speakers.sh | sudo bash
```

Two properties are worth a sentence in the README:

1. **It is unreviewable by construction.** The user runs whatever the response
   body contains, as root, having had no opportunity to read it. For a script
   that writes systemd units and can suspend the machine, the usual courtesy is
   either a download-then-run form (`curl -fsSL … -o speakers.sh && less
   speakers.sh && sudo bash speakers.sh`) or at least a "read it first" note.
2. **It tracks `main`, not the release.** I confirmed the endpoint serves
   whatever `main` currently holds — today that includes review-driven changes
   made after `v1.4.0` was cut. A user who reads this README and runs the command
   a month from now gets a different script from the one the documentation
   describes, and no checksum can pin it. I verified the tag-pinned form
   resolves (**HTTP 200**):

   `https://raw.githubusercontent.com/as1furrahman/Zenbook_CS35l41/v1.4.0/speakers.sh`

   Since `v1.4.0` now exists and is accurate, pinning the documented command to
   the tag would make the documented install reproducible, at no cost.

This is a documentation judgement, not a defect — `curl | sudo bash` is a common
idiom for hardware fixes, and the script itself is careful (no `rmmod --force`,
no sysfs writes, `modprobe -r` refuses in-use modules). It is filed because the
README is otherwise explicit about blast radius, and these two properties sit
against that grain.

### N4 — the script misreports its own name when piped — **Low**

`PROG="$(basename "$0")"` (`speakers.sh:104`). Under `curl | bash`, `$0` is
`bash`, so verified output becomes:

```
from file:  speakers.sh 1.4.0
from pipe:  bash 1.4.0
from pipe:  Usage  sudo bash bash [option]
```

The same root cause affects the post-install Quick Reference
(`speakers.sh:702-705`), which would print `sudo bash bash --status`. Nothing
breaks — but on the install path the README now recommends, the tool tells the
user to run a command that does not exist. A one-line guard in `PROG` (treat
`bash`/`sh`/`/dev/fd/*` as "speakers.sh") fixes all three sites, and a cheap
regression test is available: `cat speakers.sh | bash -s -- --version` should
print `speakers.sh 1.4.0`, not `bash 1.4.0`.

---

## 5. What remains

| Ref | Severity | Item |
|---|---|---|
| N3 | Low | Pin the documented one-liner to `v1.4.0`, and/or add a download-then-inspect alternative |
| N4 | Low | `PROG` reports `bash` under the documented pipe install; add a pipe-path regression test |
| N2 | Informational | The two lock-contention checks remain the suite's timing-sensitive pair — never observed failing in clean runs (5 clean runs now), recorded for future diagnosis only |
| — | Informational | Residual `1.4.0` literals in README/CHANGELOG are cosmetic; the install path and `--status` both derive from `VERSION` |

Twenty-five findings from Revisions 1–5 remain closed; two new Low notes are
opened here, both created by documenting a path that previously had no
documentation.

---

## 6. Bottom line

N1 is closed properly, and the resolution I would have chosen: the embedded
fallback now exists to serve a documented, mechanical, verified install path
rather than a hypothetical one. I checked the new documentation as if it were
code — the URL's owner and repo match the remote, the endpoint returns the
script with HTTP 200, the script runs correctly when read from a pipe, and the
heredoc mechanism the install path depends on survives stdin. It works.

The two notes above are the cost of that new surface area, and both are the kind
of thing that only becomes visible once a path is supported: a root-level
install command that cannot be inspected and is not pinned, and a tool that
introduces itself as `bash` on that same path. Neither is a defect; both are one
line.

**9.8 / 10.** The number is unchanged from Revision 5 but the composition moved:
one finding closed, two trivial ones opened. I would still call this finished —
the remaining items are polish, and the substantive work across six revisions
(artifacts tested rather than copies, gates that actually fail, release claims
that match their commits, a headline path actually executed, a suite that runs
in 6 s) is done and verified rather than asserted.

*This report replaces the Revision 5 text committed in `14c2fbd`; it is
currently uncommitted.*
