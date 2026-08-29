# Root-cause analysis (ACPI/DSDT investigation, 2026-08)

Why a *pure kernel* fix is impossible on UM5302TA firmware — from the actual
ACPI tables (DSDT + all 21 SSDTs disassembled):

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
   I2C bus**, so the DesignWare controller (`AMDI0010`) reports
   "controller timed out" on every transfer (not NACK) for 25+ minutes.
   Upstream's `i2c_recover_bus()` + controller reinit can't clear a bus
   clamped by an unpowered slave.
5. The only OS-reachable event that makes the EC re-initialise the amp rail
   is a **suspend/resume boundary**. Hence the `rtcwake -m mem` fallback in
   `speakers.sh` — it is not a workaround, it is the architecturally correct
   fix for this platform.

Consequence: `kernel-patch/` (probe retries) helps on boots where the EC
enables the rail late, but cannot revive a dead-boot rail. The watchdog +
suspend fallback remains the deterministic solution.
