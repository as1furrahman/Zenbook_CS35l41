# Root-cause analysis (ACPI/DSDT investigation, 2026-08)

Why a *kernel-only* fix cannot cover a dead-boot rail on UM5302TA firmware —
from the actual ACPI tables (DSDT + all 21 SSDTs disassembled):

1. `Device (\_SB.I2CA.SPKR)` (HID `CSC3551`, SUB `10431F12`) hosts both amps
   at I2C addresses 0x40/0x41, with a **single shared reset GPIO (pin 4,
   PullDown = held in reset by default)**, spk-id GPIO (pin 0x9B) and IRQ
   (pin 9).
2. The device has **no `_PS0`/`_PS3`/`_PR0`** — ACPI exposes **no rail
   control** for the amps at all.
3. Its `_STA` depends on `AMPD`, a field of the ASUS WMI/SMI exchange buffer
   `OperationRegion (EXBU, SystemMemory, 0xB7A1C698)` — populated by **EC
   firmware**. **No AML code anywhere (DSDT or SSDTs) ever writes `AMPD`**;
   there is no OS-callable method to enable the amp rail.
4. On "dead boots" the EC leaves the rail off; the unpowered amps **clamp the
   I2C bus**, so the DesignWare controller (`AMDI0010:00`) reports
   "controller timed out" on every transfer (not NACK) until the state is
   cleared. Measured on a real failing boot (24 logged timeouts):
   - all 24 were on the amps' bus; the sibling controller (`AMDI0010:01`,
     which hosts the touchpad) logged **zero** — so the SoC's controller IP
     and its driver were entirely healthy;
   - every transfer took ~1.02 s, i.e. the adapter's 1 s timeout, with no
     variance — a latched condition, not a race;
   - exactly 2 transfers per amp per probe attempt, the same 4-per-cycle
     shape at cold boot and in all five later reload attempts;
   - the **first ever** transfer on that bus already timed out (t+1.5 s after
     boot), so nothing preceded it that could have corrupted the controller;
   - the pattern was byte-identical across 6 probe cycles over 16 minutes,
     and 0 of them ever succeeded.
   The controller is alive and reporting its own timeout, so this is not a
   readiness race — the far end never participates. No recovery is attempted
   (no recovery-related messages appear), and a controller/userspace retry
   provably cannot clear it: 6/6 attempts failed, so a kernel-side probe-retry
   of any length would only have failed repeatedly too.
5. The only OS-reachable event that makes the EC re-initialise the amp rail
   is a **suspend/resume boundary**. Hence the `rtcwake -m mem` fallback in
   `speakers.sh` — used unconditionally by the boot service, and by the
   watchdog only within the first 10 minutes of uptime (it deliberately never
   power-cycles an established session). It is not a workaround, it is the
   architecturally correct fix for this platform.

Consequence: a kernel-side probe retry can help only on boots where the EC
enables the rail late, but cannot revive a dead-boot rail — and the failure
above is *measured* to be deterministic, so retrying is not a mitigation for
it at all. A userspace module reload has the same limitation. The
suspend/resume fallback is the only mechanism that reaches a dead-boot rail,
which is why it is wired into both the boot service and the watchdog's
boot-window escalation, and why `speakers.sh` now stops reloading as soon as
the clamped-bus signature appears instead of spending its whole budget first.
That combination is the deterministic solution here.

### Still open, and how to close it

The evidence localises the fault to the amps' bus segment, but two mechanisms
remain consistent with it: (a) the rail is off and the unpowered amps hold
the bus, as argued above; (b) the `AMDI0010:00` controller instance itself was
left unusable at cold boot and only its resume path re-initialises it. (b) is
disfavoured — the controller produced a normal transfer-timeout message and
its sibling instance was fine — but not excluded.

The discriminating test is cheap because the amps are the only clients on that
bus: unbind and rebind just the controller (see the README) on a failing boot.
If the amps then bind, (b) holds and the machine-wide suspend could be dropped
in favour of a controller rebind. If they still fail, (a) is confirmed.
