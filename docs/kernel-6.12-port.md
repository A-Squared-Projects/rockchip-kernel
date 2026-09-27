# Porting the Rithum Switch kernel from 6.1 to 6.12

What was learned bringing the RK3308 Rithum Switch kernel from the
rithum-6.1 tree (Rockchip develop-6.1 plus upstream stable) onto Rockchip's
develop-6.12, and what it cost. Written after the port booted and passed
the same selftest as 6.1 on RithumSwitch-0002 (Switch Pro, RK3308 rev B
silicon). Branch: `claude/kernel-6-12-port-kg1g39`, verified on hardware at
49d61b7249d, based on develop-6.12 (470f9dccb, 6.12.69) with v6.12.111
merged on top.

The short version: the port is 32-bit ARM, Thumb-2, same rkflash/SFTL
NAND stack, same boot image layout. Two faults are still open: a
use-after-free between an exiting TEE client and the OP-TEE shutdown path
(section 4.7, trigger removed at reboot) and
intermittent WiFi SDIO initialisation (section 4.2). No AArch64 switch was ever needed.
What it did need was an inventory of everything Rockchip left unported
for RK3308 on 6.12, and a complete carry-over of our own history, which
took two attempts.

## 1. What develop-6.12 is, and is not, for RK3308

Rockchip's develop-6.12 still carries the full 32-bit RK3308 path: the
arm `CPU_RK3308` Kconfig, the aarch32 device trees, both 32-bit SFTL
blobs, and an aarch32 defconfig that differs from the 6.1 one by a single
renamed symbol. That is why the port stays 32-bit.

It is not a validated RK3308 tree. Evidence collected on the way:

- `drivers/rkflash/rkflash_blk.c` is byte-identical to develop-6.1 and does
  not compile against the 6.12 block layer, yet Rockchip's own rk3308
  defconfigs (arm and arm64) select it. Nobody builds those configs.
- `sound/soc/codecs/rk3308_codec.c` is the *mainline* driver, not
  Rockchip's. It refuses version B silicon by design. Rockchip's driver is
  absent from the tree.
- The aarch32 voice-module DTS references a pinctrl label
  (`uart4_rts_gpio`) that exists nowhere. The boards that include it are
  not in the DTS Makefile, so dtc never ran on them.
- In the 569 develop-6.12 commits between January and June 2026, three
  touch RK3308 and none touch the aarch32 boards.
- The branch had merged stable only up to 6.12.69 while 6.12.111 was
  current.

Consequence: on 6.12 we are the maintainers of RK3308 support. On 6.1
Rockchip still was. Rockchip's eventual 6.12 changes to shared code will
keep arriving through their branch, but nothing RK3308-specific will.

## 2. How the branch was built

1. Start from develop-6.12, not from rithum-6.1. The two share history
   only up to mainline v6.1, so a merge is not an option; cherry-picks
   are.
2. Port `rkflash_blk.c` to the 6.12 block API (section 3.1). This was
   the one hard blocker: everything under it compiles.
3. Carry our changes over as cherry-picks with original authorship where
   the code still applies, and as final-state commits for the board DTS
   files and the defconfig, whose creation history could not be replayed.
4. Merge v6.12.111 and resolve the vendor-tree conflicts (section 5).
5. Fix what the first boots found (section 4).

### 2.1 The inventory mistake, and the sweep that fixed it

The first carry-over list held 44 commits. It was built from a session
clone that was shallow at about 300 commits, so everything before
2026-07-15 was invisible, including the first week of the port's history.
Three code changes from that week were missed and were only found after
a hardware report (section 4.5). Each was a real regression: the touch
controller's config being overwritten, the panel receiving no init
sequence, and a link dependency on the function tracer.

The check that closed it, and the one to run again after any future
rebase: deepen the clone until rithum history is complete, take every
commit authored by us or mentioning rithum, collect the union of files
they touch outside the board DTS and defconfig, and diff each of those
files between rithum-6.1 and the new branch. Any difference that is not
vendor or upstream evolution is a missed change. The full list on
rithum-6.1 is 91 commits, not 44.

    git log --format='%h|%an|%s' origin/rithum-6.1 \
      | awk -F'|' '$2 ~ /Kiernan/ || $3 ~ /[Rr]ithum/'

### 2.2 Carry-over disposition, by commit

Already in 6.12 upstream, dropped: both rtw88 SDIO fixes, the two
SO_PEERPIDFD commits, the gpio-rockchip/pinctrl-rk806 two-argument
pinctrl API adaptation, the earlyprintk diagnostic and its revert. The
wholesale rtw88 update to v6.6 is superseded by 6.12's own rtw88.

Cherry-picked as they stood: the thumb SFTL uaccess shim, the gt9xx
`phys` fix (three-way merge), the GT911 config commit, the ST7701
bit-bang, the rkflash mcount stub, the serial diagnostic removal, the
ZRELADDR Kconfig line (its defconfig half moved into the defconfig
commit).

Final state, not history: the thirteen rk3308-rithum-switch DTS files
(moved to `arch/arm/boot/dts/rockchip/`, the 6.12 layout) and
`rithum_linux_defconfig`.

## 3. Build-time findings

### 3.1 rkflash block glue and the SFTL blobs

`rkflash_blk.c` is the Linux-facing surface of the closed SFTL NAND
translation layer: it registers `rkflash0`, drains block requests through
one mutex into `sftl_read`/`sftl_write`, runs the `rkflash_gc` thread,
and wires the SFTL's vendor storage into `/dev/vendor_storage`, which is
where the serial number and MAC come from. Four API moves since 6.1:
`block_device_operations.open` takes a gendisk and `blk_mode_t` (6.5);
`blk_mq_alloc_disk` takes `queue_limits` and owns the queue (6.9);
`blk_queue_max_*` setters are gone (6.11); `__kmalloc` became
`__kmalloc_noprof` (6.10). The last one matters because all four
prebuilt SFTL blobs call `__kmalloc` by name, so a one-line wrapper in C
stands in for it rather than regenerating closed binaries. The 6.1 code
also allocated two request queues and leaked one; the port lets the disk
own its queue and frees the tag set on teardown.

The blob also needs the two things 6.1 already gave it: the uaccess shims
for the Thumb-2 build (a `bl` straight into `arm_copy_from_user` skips
the domain window under `CPU_SW_DOMAIN_PAN`) and, for the non-Thumb blob
only, a `__gnu_mcount_nc` stub because it was compiled with `-pg`.

### 3.2 FORTIFY_SOURCE in the decompressor

With GCC and `CONFIG_FORTIFY_SOURCE`, `atags_to_fdt.c` fails to link:
its `memcpy`/`strlen` become fortified wrappers, 6.12's
`fortify_warn_once()` is `WARN_ONCE()`, and the decompressor has neither
`warn_slowpath_fmt` nor a linker-script home for `.data..once`. Clang
proves the copies in bounds and drops the runtime path, which is why an
LLVM build never sees it. Fix: `#define __NO_FORTIFY` before the
includes, as `string.c` in the same directory already does.

### 3.3 Config canonicalisation traps

Two renames silently change the resolved config if the 6.1 defconfig is
reused as-is. `CONFIG_EMBEDDED` is gone; it selected `EXPERT`, and
`EXPERT` is what selects `DEBUG_KERNEL`, so without the rename the
softlockup detector, its panic, `SCHED_STACK_END_CHECK` and the rest of
the "panic and reboot when the kernel wedges" set drop out with no
message, and every `if EXPERT` line (VT console, XZ BCJ filters, CRDA)
reverts. `CONFIG_DEBUG_WX` became `CONFIG_ARM_DEBUG_WX` on 32-bit. The
defconfig commit lists the remaining diffs, all upstream churn with the
same effect. Method: resolve both defconfigs fully and diff the
`.config`s, not the defconfigs.

### 3.4 Warnings

GCC 16.2 builds the whole tree, modules and DTBs with zero warnings under
`CONFIG_WERROR=y`. Clang reports two stack-frame overruns that also fire
on the 6.1 tree (cryptodev ioctl, and `atags_to_fdt` in the
decompressor); they are clang-only and were left alone. One vendor file
(`clk-rk3308.c`) declared its CRU dump hook without a prototype, which
`-Werror` rejects; it is now static like its siblings.

## 4. Runtime findings, in the order they were found

### 4.1 GPIO pin numbering (every peripheral)

First boot: display, touch, Bluetooth, WiFi, SD and host VBUS all failed
with `pin NNN is not registered`, every NNN equal to 512 + bank * 32 +
pin. Rockchip's develop-6.12 sets `gc->base = -1` when `GPIO_SYSFS` is
off (their commit 72765f6037d), but the driver's fallback pin-range
registration still passed `gc->base` as the *pinctrl pin offset*, so
pinctrl was told the banks live at pins 512-671.

This is an incomplete backport. Mainline made the same move in April 2026
(c8079f83e0bf, by Rockchip) and broke every Rockchip SoC without
`gpio-ranges`; Jonas Karlman fixed it two weeks later (5cd9c6d332f4) by
passing `bank->pin_base`. Our fix is that line. Rockchip's branch never
picked up the fix.

`gpio-ranges` was then added to all five rk3308 banks so the GPIO core
registers the ranges itself and the fallback is off the path. Upstream's
rk3308.dtsi lacks it too; only the RK35xx trees have it, which is exactly
why those were the SoCs that did not regress. This is worth sending
upstream.

### 4.2 WiFi SDIO timeouts: open, intermittent, and not the pin bug

**Status: open.** An earlier version of this section said the
`gpio-ranges` commit had fixed it. That was called on two passing boots.
A later boot of a later tip (b93404711cb7, which differs from a passing
tip only by the fbdev read fix and docs) failed again with the same
signature, so the fault is intermittent and the two passes were luck.
Treat "WiFi works on 6.12" as unproven until a pass rate is known.

Signature, identical on every failing boot:

    mmc1: Bus speed (slot 0) = 400000Hz
    dwmmc_rockchip ff4a0000.mmc: card claims to support voltages below defined range
    mmc1: Bus speed (slot 0) = 50000000Hz
    mmc1: error -110 whilst initialising SDIO card
    ... retried at 300 kHz, 200 kHz and 100 kHz, each escalating back to
        50 MHz and timing out
    mmc1: Failed to initialize a non-removable card

Init at 400 kHz succeeds every time (CMD5, CMD3, CCCR and common CIS),
then the first CMD52 at 50 MHz times out. On 6.1 the same unit type enumerates on the first
attempt at 50 MHz, every time observed. The voltage warning is benign
and appears on 6.1 too. A failing boot is not silent: selftest halts at
S55 with "Hardware fault: wifi mac-wlan", so the unit looks dead from
the front panel while ssh (seeded at S50) still works.

What it is not: the `[WLAN_RFKILL] ... err -2` lines (ENOENT; power is
sequenced by `sdio_pwrseq`); the SDIO or WiFi device tree, identical to
6.1 apart from property renames; the dw_mmc-rockchip and dw_mmc code,
whose 6.1-to-6.12 delta is upstream refactoring; the pinctrl driver,
whose delta is other SoCs; the pin-range fix, since the pin layout was
identical before and after `gpio-ranges` and the fault persists with the
ranges in place.

Ruled out, by measurement on one passing and one failing boot of the
same build (555c18743d6):

- Clocks: `clk_summary` identical byte for byte. `clk_sdio_div` on DPLL
  at 100 MHz, `clk_sdio` 100 MHz, sample and drive clocks 50 MHz,
  VPLL0/VPLL1/DPLL rates the same. This kills the hypothesis that audio
  moves a PLL under the SDIO divider; it is a post-boot snapshot, so a
  PLL that moved and moved back would look the same, but nothing is
  left wrong afterwards.
- Pinconf of GPIO4 A0 to A5: identical.
- Audio: the acodec probe completes after SDIO's first attempt has
  already resolved on both boots (125 ms after success on the pass, in
  the middle of the retry ladder on the fail). The I2S nodes log nothing.
  A bystander, not a cause.

What the two boots do differ in is when SDIO bring-up starts: 0.914 s on
the pass, 1.032 s on the fail, and the first 400 kHz to 50 MHz attempt
succeeds in one and times out in the other. Every retry then repeats the
same shape: the identification commands at the low clock succeed (the
core would not print the 50 MHz bus speed otherwise), and the first
traffic at 50 MHz times out. So it is not "the card is
not there"; it is "the card answers at 400 kHz and never at 50 MHz", and
which of the two a boot gets is decided before the first attempt.

Control, run on unit 0002 with both images and the same loop (ssh in,
reboot, six times): 6.1 passes 6 of 6, the unpatched port passes 1 of
6. Earlier rate on the port: 5 of 14. Unit 0002 has a known microphone
fault, but the control shows its WiFi module is fine under 6.1, so this
is the port.

Where it dies, precisely. An earlier version of this section said
"the CIS read"; that was wrong. `mmc_sdio_init_card` reads the CCCR and the common CIS
at the init clock, then switches the card to high speed, then raises
the host clock, then sends the CMD52 pair of `sdio_enable_4bit_bus`,
then reads each function's CIS. So on a failing attempt CMD5, CMD3, the
CCCR and the common CIS all succeed at the init clock, and the first
command sent at 50 MHz gets no response. The `-110` lands about 1 ms
after the "50000000Hz" line on every failing attempt. That is the
controller's hardware response timeout (64 card clocks) surfacing
through the interrupt path; the software command timer would take at
least 10 ms. So the controller clock is running and the card simply
does not answer at 50 MHz. Each retry in the ladder re-asserts the
`sdio_pwrseq` reset before it identifies, so the card is reset four
times per failing boot and still never answers at speed.

Experiment A (`post-power-on-delay-ms = <100>` on `sdio_pwrseq`): WiFi
up on 6 of 6, but 5 of those 6 still failed the first two attempts and
came up on the third, at the 200 kHz init clock. A does not stop the
failure; it stretches the retry ladder until an attempt lands late
enough. Read together with the baseline (four attempts inside ~210 ms
of the first power-on, all failing) and A (third attempt roughly 400 ms
after the first power-on, passing), the card needs wall-clock time
after the first power-on that the reset pulses do not reset, or
something else in the same window has to finish first. A is a
workaround, not a fix, and must not be shipped as the answer.

Kernel-side diff of every piece of the SDIO path, rithum-6.1 against
this branch, all found functionally identical:

- `drivers/mmc/core/`: the sdio, sdio_ops, sdio_cis, core, host, bus,
  pwrseq and regulator deltas are renames, const-ification,
  `devm_mmc_alloc_host`, and the "Failed to initialize a non-removable
  card" message. No change to the init sequence.
- `drivers/mmc/host/dw_mmc.c`: tasklet became a BH workqueue (same
  softirq context), plus a `hw_reset` hook nothing on RK3308 uses.
- `drivers/mmc/host/dw_mmc-rockchip.c`: the vendor `USRID_INTER_PHASE`
  test became an `internal_phase` flag from the match data. RK3308
  binds as `rockchip,rk3288-dw-mshc`, so `internal_phase` is false and
  both trees drive the phases through `clk_set_phase` on
  `SCLK_SDIO_SAMPLE` and `SCLK_SDIO_DRV`. Sample phase is
  `rockchip,default-sample-phase`, absent for rk3308, so 0; drive
  phase is 90 in SD high speed. SDIO_CON0 = 0x2, CON1 = 0x0 on every
  boot captured so far is exactly those values.
- `drivers/clk/rockchip/clk-rk3308.c`, `clk-mmc-phase.c`, `clk.c`,
  `clk-pll.c`, and the clk core's mux and composite parent selection:
  the SDIO branches and their flags are byte-identical; the core's
  `CLK_SET_RATE_NO_REPARENT` handling was refactored without changing
  behaviour. `clk_sdio_div` can still reparent among DPLL, VPLL0, VPLL1
  and xin24m at every rate change.
- `net/rfkill/rfkill-wlan.c`: gpio to gpiod conversion and property
  renames. The `clk_wifi` rate and enable, and the GRF 0x0314
  REF_CLKOUT enable, are the same code. None of the WiFi GPIOs exist on
  this board, so the driver's effect is the pinctrl hog (`wifi_wake_host`,
  `rtc_32k`) and that clock enable.
- `drivers/soc/rockchip/io-domain.c`: only the regulator lookup used
  for a `dev_info` line changed. vccio4 is `vcc_1v8`, a fixed regulator
  probed at subsys_initcall, and the io-domain probes at fs_initcall,
  before dw_mmc at device_initcall, on both trees.
- `drivers/pinctrl/pinctrl-rockchip.c`: the 644-line delta is RV1103B
  and RK3572 support plus an input-enable hook no RK3308 path calls.
- `drivers/gpio/gpio-rockchip.c`: the vendor pin-base change and the
  four stable fixes ported here (4.1).
- Device tree: the SDIO, pwrseq, wlan-platdata, io-domains and cru
  nodes are identical to 6.1; the compiled DTB was already compared.

Experiment B (`max-frequency = <25000000>`, no A): 1 of 6, the same as
the unpatched port, and the failing ladder has the identical shape at
25 MHz: the first command after the clock leaves the init rate gets no
response about 1 ms later, on every attempt. So it is not 50 MHz and
not a rate margin in the simple sense. The card stops answering when
the clock leaves the init rate, whatever rate it lands on.

Retired by measurement across 18 boots (meta-rithum): the mmc1
start-time correlation (a pass at 0.917 s and a fail at 0.939 s on the
same image); USB enumeration overlap (both outcomes with and without
it); Bluetooth (`hci_uart` loads at 8.4 s, seven seconds after mmc1 is
decided, on every boot); the rfkill-wlan probe (1.17 s on every boot
regardless of outcome). Retired by code: the chip's state across a warm
reboot (the mmc host class shutdown hook is the same in both trees, and
a failed boot leaves the card in pwrseq reset through the reboot on
either kernel; B boot 5 passed after four failed boots and boot 6
failed after it, so the previous boot does not decide the next). On two
B boots 22 ms apart with intervals matching to 1 ms, one passed and
one failed: this looks like a genuine marginal condition, not an
ordering race with another driver.

Physical state measured on the port (B image, unit 0002): SDIO_CON0
0x2, CON1 0x0, GRF SOC_CON0 0x194 (bit 4 set, vccio4 at 1.8 V), GRF
0x314 0x7. All boots in every loop so far are warm reboots; nobody has
seen a cold boot on either kernel, which needs the bench.

The physical comparison with 6.1 on the same unit has now been made
(meta-rithum, three raw dumps on 0002: a 6.1 passing boot, a passing and
a failing boot of the unpatched port at 555c18743d6, all warm reboots):

- CRU 0xff500000 to 0x500: byte-identical across all three. Every PLL,
  MODE_CON, the clk_sdio_div mux and divider, the gates, SDIO_CON0/1.
- GRF 0xff000000 to 0x800: identical once the three volatile words are
  excluded. A first pass reported 0x424 tracking the outcome and 0x4a8
  tracking the kernel; five back-to-back reads on one boot showed both
  moving between reads (0x424, 0x48c and 0x4a8 are live status words,
  the other 509 are stable). Both were single-sample noise. No stable
  GRF word separates 6.1 from the port, or a passing boot from a
  failing one.
- dw_mmc 0xff4a0000 to 0x100: 6.1 pass versus port pass differ in one
  word, the IDMAC descriptor base address. Port pass versus fail differ
  only by the powered-off host after the failure.
- pinmux and pinconf of pins 128 to 133: identical (an earlier claim of
  the same was from an empty diff; this one is real, six lines each
  way). Pull-up, 8 mA, Schmitt on, same groups. Elsewhere, pin 0 (the
  WiFi host-wake line) is claimed on the port and unclaimed on 6.1: the
  gpiod conversion in rfkill-wlan matches the board's
  `WIFI,host_wake-gpios` property where 6.1 looked for
  `WIFI,host_wake_irq` and never claimed it. It is requested as-is with
  no direction change and is an input from the chip, not the data path.
- `clk_summary`: no SDIO, PLL, WiFi or 32 kHz clock differs in rate,
  parent or enable count.
- The two kernels' `.config`: preemption, HZ, timers, SMP and the MMC
  and WiFi options are identical; the 467 deltas are renamed or new
  6.12 symbols and unrelated drivers.
- Carried card state across the warm reboot: both outcomes occur with
  the card carried live (6.1 to A: up; A to B: down), and 6.1 passes
  after a boot that left the card in reset.

Note for anyone scripting this: the SDIO host index is not stable
across boots (`ff4a0000.mmc` came up as mmc0 or mmc1 on either kernel),
so resolve it through `/sys/devices/platform/ff4a0000.mmc/mmc_host/`.
`dw_mci/regs` in debugfs is absent on both images.

So every SoC-side register, clock, pin and config that can be read is
the same on a 6.1 passing boot and a port passing boot, and the code
that sequences the switch (`dw_mci_set_ios`, `dw_mci_setup_bus`, the
composite clock's set-rate-and-parent ordering) is identical too. The
fault is in what the card sees, and it is frequency-independent (B).

Two more device-tree experiments, six boots each, both clean negatives
(meta-rithum, properties verified on the running kernel):

- D, `rockchip,default-sample-phase = <90>` on `&sdio`: 1 of 6. SDIO_CON1
  went from 0x0 to 0x2 and stayed there, so the property reaches the
  hardware and CON1 really is the sample phase. Moving the sample edge
  does not help.
- E, `cap-sd-highspeed` and `sd-uhs-sdr104` removed: 1 of 6, at 25 MHz
  in default timing. With B (25 MHz in high-speed timing) also failing,
  the timing mode is not the culprit. The high-speed hold-race
  hypothesis above is dead; it is left in place so nobody re-runs it.

The table:

    variant  change                          rate  retries on failing boots
    none     unpatched 555c18743d6           1/6   4, then give up
    A        post-power-on-delay-ms 100      6/6   2 on five of six
    B        max-frequency 25 MHz            1/6   4
    C        post-power-on-delay-ms 300      6/6   1 on two of six
    D        default-sample-phase 90         1/6   4
    E        no highspeed, no sdr104         1/6   4
    6.1.188  control                         6/6   0

Correction to what A and C mean. The interval from the pwrseq
allocation to the first 400 kHz command is 11 to 20 ms on 6.1 (6 of 6
pass) and 12 to 16 ms on failing port boots, so the card is not short
of settling time; 6.1 gives it less and works. What C changes is when
in the boot the transaction happens: first command at about 1.23 s
instead of about 0.92 s. The defensible statement is: on the port, the
SDIO transaction at about 0.92 s mostly fails and the same transaction
at about 1.23 s works; on 6.1 it works at 0.92 s. A and C relocate the
transaction; they do not restore a 6.1 behaviour. A per-boot check of
what dmesg shows as concurrently active within 5 ms of the first
command does not discriminate either (passing and failing boots both
occur with zero and with several concurrent lines, and 6.1 passes with
more concurrent activity than some failing port boots).

An `initcall_debug` timeline (needs a build on this board: the command
line is the DTB's `/chosen/bootargs`, rewritten at image time, and the
FIT is signed, so there is no on-device env to edit) rules out every
switched load as a concurrent actor: the USB host VBUS regulator and
its 100 ms startup delay finish by 0.44 s, backlight and panel by
0.79 s, the USB controllers by 0.90 s, the audio card starts at 1.33 s,
and the LED driver never probes. The GT911 blocks i2c-1 for 200 ms
right before the mmc probe on both outcomes. On a passing and a failing
boot of the same image the pwrseq, 400 kHz, clock-switch and outcome
timestamps agree to within 1 ms, with the same preceding probe
durations.

The one thing that is concurrent with the transaction on both boots is
the SPI NAND: `rksfc_driver_init` starts at 1.055 s, the SFTL's initial
NAND reads run through the whole SDIO attempt, and the probe ends at
1.244 s. That does not separate pass from fail on the port, but it
lines up with everything else: A and C pass on the attempt that lands
after 1.24 s, and the failing attempts all sit inside the NAND burst.
The SFC pins are on GPIO3 A, so the NAND is on the 3.3 V vccio3 rail
(vcc_io), and the WiFi I/O rail vcc_1v8 is regulated from vcc_io. The
drivers link in the same order in both trees and `clk_sfc` has no rate
propagation to the PLLs, so the overlap is not a clock effect and is
not new by construction; whether 6.1 has the same overlap is unknown,
because no 6.1 timeline has been taken.

The same timeline on 6.1 closes the NAND line: 6.1's attach (1.014 to
1.044 s) sits inside its rksfc window (1.006 to 1.178 s) at the same
phase of the burst, 8 to 11 ms in on all three boots, and succeeds
first time. The overlap is not the difference. Two lessons from the
same round:

- Moving rksfc to `late_initcall` would have deadlocked the unit:
  `dm_init_init` is a late_initcall that spins on `dm-mod.waitfor=31:6`
  (the NAND block device, for the dm-verity root) and `md/` links
  before `rkflash/`. The safe form is `device_initcall_sync`. Not run,
  because after the 6.1 timeline it would only be a mitigation.
- Six boots cannot tell 3 of 6 from 1 of 6. F2 (panel and backlight
  disabled) went 3 of 6 then 0 of 6 on the same image; 3 of 12 has a
  0.32 probability under the baseline rate. A 6 of 6 is solid (2e-5
  under baseline); a 1 of 6 is baseline; anything in between needs
  twelve or more boots before it means anything. F3 (audio) dropped as
  low value.

The GPIO banks were the last software-readable state, and they are
identical too (five sweeps per bank for volatility first; gpio0 and
gpio1 EXT_PORT flicker on live inputs, every DR, DDR, INTEN and
INT_TYPE word is stable). Every stable word matches between a 6.1
passing boot and a port passing boot. The one difference is the
failure's consequence: gpio0 DR bit 2 is WL_REG_ON, released on both
passing boots and asserted only on the failing one, because the core
powers the card off after "Failed to initialize", which asserts the
pwrseq reset. The host-wake line is an input on both kernels (gpio0
DDR bit 0 clear), so the port's claim of it drives nothing. Decoded
and identical on both kernels: host-wake in/0, headphone amp out/0,
WL_REG_ON out/1, speaker amp out/0, touch IRQ in/0, panel enable
out/0, BT device-wake out/1, BT_REG_ON out/1.

**The software side is finished.** Everything readable is identical or
non-discriminating between a 6.1 passing boot and a port passing boot,
and between a port passing boot and a port failing boot: every stable
CRU, GRF, dw_mmc and GPIO word; every clock's rate, parent and enable
count; SDIO pinmux and pinconf; the kernel config; the `&sdio` and
`sdio_pwrseq` nodes; the probe timeline to within 1 ms; concurrent
activity; the NAND overlap (present on 6.1 too); the switched loads;
Bluetooth (seven seconds away); bus rate, timing mode, sample phase,
settling time and carried card state. What the kernel does to the SoC
is the same. What differs is what the card sees, and only an
instrument can show that. The bench, which is the whole remaining
programme:

1. A scope on SDIO CLK and CMD across the switch out of the init rate,
   on a failing port boot and a passing 6.1 boot.
2. On the same trigger, vcc_io and vcc_1v8 at the WiFi module over
   1.05 to 1.25 s, looking for droop coincident with the NAND reads.
3. Repeated real power cycles on each image. One cold boot of E passed
   first time, which at E's 1-in-6 warm rate is what chance gives once.

Until that is done, the port ships without WiFi being reliable, or it
does not ship. A and C are not acceptable substitutes: they relocate
the transaction and hide the fault.

None of A to E, nor the `initcall_debug` builds, ship. They live on
meta-rithum's local scratch branches marked diagnostic; unit 0002 is on
the unpatched port.

### 4.3 Audio codec: mainline refuses version B

`rk3308-acodec ff560000.codec: error -EINVAL: Chip version B not supported`.
The mainline driver (4ed0915f5bc) was derived from Rockchip's 4.19 driver
"with removal of some features" and gates out version B. Beyond the gate
it knows none of the bindings the board's audio topology uses
(`rockchip,detect-grf`, the headphone-detect interrupts,
`adc-grps-route`, `en-always-grps`, `loopback-grp`, `no-hp-det`,
`hp-ctl-gpios`), exposes different control names to userspace, and does
not fit the vendor multicodecs card. Switching to it would be an audio
stack rewrite on both sides of the kernel boundary for a driver that
would not probe. The vendor driver (4819 lines) came over from
rithum-6.1 with one adaptation (`remove` returns void since 6.11) and
compiles clean under `-Werror`; the acodec node in rk3308.dtsi went back
to its 6.1 form, and decompiles identically to the 6.1 DTB. Result on
hardware: "acodec version is: b", card 0 as on 6.1, playback and capture
working.

Note for future audio comparisons: absolute capture amplitude between
units is not evidence about software. Unit 0002's mic is suspect.

### 4.4 USB PHY was never broken

`rockchip-usb2phy: error -ENXIO: IRQ index 0 not found` appears on 6.1
too; the controller-level IRQ is optional and rk3308 has none. The
deferred USB controllers were waiting on the host port's `phy-supply`,
the VBUS regulator whose GPIO was one of the pin failures. Fixed by 4.1.

### 4.5 The three misses from the shallow inventory

**GT911 touch config is overwritten, and it persists.** With
`GTP_DRIVER_SEND_CFG=1` (the vendor default) and `tp-size=9110`, the gt9xx
driver writes its generic 1920x1200 table into the controller on every
probe, and the write lands in the controller's flash. Read back over
i2c at 0x8047..0x804C: `0x41 0x80 0x07 0xb0 0x04 0x0a` (1920x1200) on a
unit that has booted the bad kernel, `0x41 0xe0 0x01 0xe0 0x01 0x0a`
(480x480) on one that has not. Symptom: touches land, scaled by 480/1920
in X and 480/1200 in Y. The rithum-6.1 commit (bf08379c811) sets
`SEND_CFG=0` and archives the factory config as
`drivers/input/touchscreen/gt9xx/GT911_Rithum_480x480_Config.cfg`, a
byte-exact dump from a pristine unit. **Repair for a clobbered unit:
write those bytes to 0x8047, then 0x01 to 0x8100.** Any unit that booted
a branch tip before 27e267ccb8e needs it. Do not boot older tips on any
unit.

Done on 0002: driver unbound first so nothing could race a partial write
into the chip's flash, all 185 bytes written, read back and compared
byte-for-byte (X_max=480, Y_max=480, version 0x41, checksum 0x6b), then
re-read before and after the next flash and boot. The overwrite is
persistent, and so is the repair; after it, `SEND_CFG=0` leaves the
chip alone. `/dev/input/event0` reports ABS_MT_POSITION_X/Y max 480.

**ST7701 panel init.** The panel's controller is initialised over a
3-wire 9-bit SPI bus that the RK3308 drives directly off GPIOs. Vendor
6.12 panel-simple has only the hardware-SPI path; the board node is a
root-level `simple-panel` with `spi-scl/sdi/cs-gpios`, which needs the
GPIO bit-bang that rithum-6.1 added (0f00d47548f). Without it the VOP
scans and fb0 exists but nothing is drawn after the first modeset. With
it, on 0002: card0-DPI-1 connected and enabled at 480x480, backlight on,
and the glass shows the UI and wakes, confirmed by eye rather than by
any probe.

**mcount stub.** See 3.1.

### 4.6 Serial console spam

Thousands of `ttyS4: Frame error! / Break interrupt!` lines through
every Bluetooth firmware download. A Rockchip diagnostic in
`8250_port.c` that rithum-6.1 removed (6086eea0c699); cherry-picked.

### 4.7 Reboot can hang forever in the OP-TEE driver

**Status: trigger removed on the branch; the underlying use-after-free
is still a latent bug that the 6.1 tree already documents.** Six
consecutive reboots of the reproducer loop (ssh in, which signs with
the TEE host key, then reboot) on 555c18743d6 stranded nothing and left
no `refcount_t: underflow`, `tee_shm`, `Oops` or `blocked for more than`
in pstore. Six is not closure for a bug 6.1 saw once in months; dozens
of the same loop would be.

About one reboot in six on 6.12 never completed:

    INFO: task reboot:1449 blocked for more than 122 seconds.
      __wait_for_common from optee_cq_wait_for_completion+0xf/0x32
      optee_cq_wait_for_completion from __optee_disable_shm_cache+0x73/0xa0
      __optee_disable_shm_cache from device_shutdown+0xc5/0x11c
      device_shutdown from kernel_restart+0x9/0x4c

The shutdown itself ran to completion first (filesystems unmounted,
`rkflash_shutdown:OK`), then `device_shutdown()` reached the OP-TEE
driver, which asks secure world to hand back its cached shared memory.
OP-TEE answers that SMC with EBUSY while any secure thread is in use,
and the driver waited, unbounded, for a completion that only a returning
call posts. The hardware watchdog cannot rescue this: the driver core
stops it when a reboot begins (`watchdog_stop_on_reboot`), and its
userspace petter is already down. Every OTA ends in a reboot, so in the
field this is an engineer visit.

**This is the bug rithum-6.1 already knows about.** The shutdown script
in meta-rithum (`rithum-shutdown`, comment block at lines 55-96) records
the same event on 6.1.184 with a different symptom: a
`refcount_t: underflow; use-after-free` in
`tee_shm_fop_release -> tee_shm_put -> optee_shm_unregister ->
optee_smc_do_call_with_arg -> tee_shm_put`, in `rithum-key-sign`, timed
exactly after `rkflash_shutdown:OK`, followed by an Oops in an unrelated
process on a page full of high-entropy bytes (secure world writing into
a freed page) and a wedged reboot. `rithum-key-sign` is spawned by sshd
per signature through HostKeyAgent to sign with the TEE host key; it is
not a service, so the shutdown script's `sv d` sweep never reaps it, and
one can be mid-exit, inside its shm-unregister call, when
`device_shutdown()` starts. The reboot loop used to measure the WiFi
rate (ssh in, reboot, repeat) is precisely the reproducer that comment
asks for, which is why 6.12 hit it in six reboots where 6.1 saw it once
in months.

On both kernels the sequence is the same: shutdown disables the cache
and frees the shm objects secure world hands back, while a client's call
is still in flight and about to use one of them. On 6.1 that freed page
was reused and written, and the machine wedged on the corruption. On
6.12 the exiting task died inside its call, its secure thread was never
released, and the shutdown wait never ended. The 6.1 comment names two
candidate mechanisms (a stale cookie in secure world's RPC free, or
kernel re-entrancy on the shm under unregister), rules out draining
`/dev/tee0` before reboot, and notes that every relevant upstream and
Rockchip fix was already in the crashing kernel, so a stable bump will
not help.

**What the branch does now** (92cabc42992, then the gating commit):

- `optee_shutdown()` no longer touches the shm cache on a reboot or
  power-off. Secure world's cache only matters to a kernel that runs
  after this one without a reset, which is kexec; a reset clears secure
  world with everything else. So the disable runs only when
  `kexec_in_progress`, which this product never sets. That removes the
  trigger: no cached shm is freed under a call in flight at shutdown.
- For the kexec case the disable is bounded at five seconds and logs
  `optee: secure world still busy after 5000 ms, giving up on disabling
  the shm cache` before proceeding, so even there a stuck client costs
  a slow reboot rather than a hung one.

What this does not do: fix the use-after-free itself. If the same
mechanism can fire outside shutdown, it still can. The 6.1 comment says
telling the two mechanisms apart needs the RPC free cookie captured
beside the shm under unregister. Until that measurement exists, the
things to watch on every boot's pstore console are `refcount_t:
underflow` and any Oops naming `tee_shm`, and the reboot loop remains
the reproducer.

Not a fix, recorded so nobody reaches for them: SysRq reboot around
`device_shutdown()` (also skips `rkflash_shutdown`, trading a hang for
NAND corruption); `watchdog.stop_on_reboot=0` on the command line (a
backstop that would also hard-reset a legitimately slow shutdown;
belongs to the boot image, not the kernel).

### 4.8 /dev/fb0 could not be read

Every `read()` of `/dev/fb0` returned EINVAL while mmap and drawing
worked, so the app never noticed. The first read after boot also leaves
this in the log, once:

    WARNING: CPU: 3 PID: 1546 at drivers/video/fbdev/core/fb_chrdev.c:37 fb_read+0x47/0x6c
    fb0: fb_WARN_ON_ONCE(!info->fbops->fb_read)
    Call trace:
      warn_slowpath_fmt from fb_read+0x47/0x6c
      fb_read from vfs_read+0x83/0x122

The reader was a python3 process, one of the product diagnostics that
inspect framebuffer content to decide what is on screen. Because it is a
`WARN_ON_ONCE`, every later read fails with EINVAL and no trace, which
is why the failure looked consistent and the warning looked isolated.

Mechanism: since 6.5 the fbdev core refuses a read when the `fb_ops` has
no `fb_read`, where 6.1 fell back to copying from `screen_base` itself.
The vendor fbdev's ops carried the DMAMEM draw helpers but not the read
and write pair, and had been relying on that fallback. Fixed in
6bb9fb82405 by adding `__FB_DEFAULT_DMAMEM_OPS_RDWR`, as `drm_fbdev_dma`
does for a kernel-mapped DMA buffer. If this trace appears, the kernel
predates that commit. Verified on 0002: a full 480x480x4 read returns
921600 bytes, a written pattern reads back, no WARN. Caveat for anyone
using fb0 as a diagnostic: when screend has taken the display over DRM
(fault screen, going-down), fb0 is the idle fbdev buffer and reads back
what it holds, not what is on the glass.

### 4.9 Pre-existing noise, verified on a 6.1 boot of the same hardware

Do not chase these: `fiq_debugger: could not install nmi irq handler`,
`sip_smc_get_dram_map: request share memory error!` and BL31's
`unhandled SMC (0x82000029)`, `failed to register clock dclk_vop_frac:
-17`, the usb2phy IRQ line above, `[WLAN_RFKILL] ... err -2` (ENOENT; the
power is sequenced by `sdio_pwrseq`), and the two dtc warnings in
Rockchip's shared voice-module files (an i2c unit address and a missing
`#sound-dai-cells` on spdif-tx, both in nodes the board disables or does
not use).

## 5. Merging stable into a vendor tree

The v6.12.111 merge (2768495b95a) conflicted in thirty files; its commit
message records every resolution. The policy that emerged:

- Where Rockchip rewrote a driver (gpio-rockchip, I2S TDM, the camera
  drivers, the IOMMU, SDHCI), keep the vendor version whole; stable's
  fix targets the upstream shape and does not apply.
- Where stable supersedes a vendor backport of the same fix (tcpm
  DISCOVER_MODES, UBI header padding, the arm64 TLBI errata list), take
  stable.
- Where both sides added something real, combine by hand and say so.
- Two non-conflicting changes still broke the build and were fixed inside
  the merge so every commit builds: stable moved fb_info allocation into
  the DRM fb helper (the vendor fbdev now takes `helper->info`), and both
  sides added the same `priv` declaration to the dw_mmc init function.
- Four stable gpio-rockchip fixes that were skipped by keeping the vendor
  driver were ported afterwards as their own commits, one of which moved
  the version-ID read to after the bus clock is enabled, matching
  upstream.

Keep merging stable ourselves; Rockchip's branch lags by months.

## 6. Evidence rules learned the hard way

- The product selftest's `touch` and `display` checks only prove that a
  device enumerated. Touch was broken and the display unverified while
  both showed PASS. Read them as "probed", never as "works".
- A grep of `/proc/interrupts` for the device name can miss an IRQ
  registered under the driver name (`gt9xx`). Absence from a grep is not
  absence in fact; two early reports (a "missing" touch IRQ, and a
  selftest touch PASS taken as working touch) were both this.
- A shallow clone is not a history. Do the sweep in 2.1 before declaring
  a carry-over complete.
- Compare fully resolved configs, not defconfigs (3.3).
- Clang and GCC disagree about frame sizes and about fortify; a
  clang-only build proves less than it looks like (3.2, 3.4).

## 7. Open items

- Repair the GT911 config on every unit other than 0002 that booted a
  tip before 27e267ccb8e (4.5). 0002 is repaired and verified.
- OP-TEE shutdown (4.7): the reboot-time trigger is removed, the
  use-after-free behind it is not fixed. Watch pstore for `refcount_t:
  underflow` across the reboot loop; design the cookie capture the 6.1
  comment asks for.
- WiFi SDIO is intermittent on 6.12 (4.2): 6.1 passes 6 of 6 on the
  same unit, the port 1 of 6. The software side is exhausted: every
  readable register, clock, pin, GPIO level, config and probe timeline
  is identical between the kernels. It needs the bench (scope on CLK,
  CMD and the module's rails across the clock switch; real power
  cycles). The delay variants A and C are not fixes. This blocks
  calling the port done.
- The RS variant shares every fix here and has not been booted.
- Branch naming: this is `claude/kernel-6-12-port-kg1g39`; it wants a
  `rithum-6.12` home.
- Upstream candidates: `gpio-ranges` for rk3308.dtsi, `__NO_FORTIFY` in
  `atags_to_fdt.c`, the `uart4_rts_pin` label fix.
- Unit 0002's microphone, independent of the kernel.

## 8. Commit map (470f9dccb..HEAD)

    fd2b768965d  rkflash: port the block glue to the 6.12 block layer
    051f93bf107  rkflash: reach user memory from the thumb SFTL blob through C
    85f961a30f7  ARM: rk3308: reclaim RAM below OP-TEE via a fixed low ZRELADDR
    3c346861215  Input: gt9xx - fix dangling input_dev->phys (garbage P: Phys)
    6a4560ac5f0  ARM: dts: rockchip: carry the rithum-switch boards over from 6.1
    fcf2915fb49  ARM: dts: rockchip: rk3308: point uart4 RTS bit-bang at the label that exists
    2634f62e07e  rithum_linux_defconfig: carry over from 6.1, re-canonicalised for 6.12
    f7ee4a0347b  clk: rockchip: rk3308: make rk3308_dump_cru static
    2768495b95a  Merge tag 'v6.12.111'
    b40b9a4b9f6  gpio: rockchip: convert bank->clk to devm_clk_get_enabled()
    e16eaf90dd9  gpio: rockchip: change the GPIO version judgment logic
    d03d42d565c  gpio: rockchip: teardown bugs and resource leaks
    e7722fa482c  gpio: rockchip: fix generic IRQ chip leak on remove
    2d0ceae0721  ARM: decompressor: keep FORTIFY_SOURCE out of atags_to_fdt.c
    47227328c1f  gpio: rockchip: register the pin range by hardware pin base, not GPIO base
    ea20c527a42  ASoC: codecs: rk3308: carry the vendor codec driver over from 6.1
    4bcf324a148  arm64: dts: rockchip: rk3308: restore the vendor acodec node
    c63830b0f5e  arm64: dts: rockchip: rk3308: describe the GPIO to pinctrl ranges
    37ec8ecc376  serial: 8250: drop rockchip LSR break/frame-error diagnostic
    27e267ccb8e  input: gt9xx: stop overwriting the panel's GT911 config
    161e2f8fefc  rkflash: don't require FUNCTION_TRACER to link the ARM SFTL blobs
    4b5252bac91  drm/panel: rithum: bit-bang the ST7701 SPI init over GPIOs
    49d61b7249d  docs: record what the 6.12 port found
    6bb9fb82405  drm/rockchip: fbdev: give /dev/fb0 back its read and write file operations
