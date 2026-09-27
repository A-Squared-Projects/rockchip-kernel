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

There is a fourth dependency the blob has on the kernel that nothing in
the build checks: the layout of `struct file_operations`. The SFTL
blob creates `/dev/vendor_storage` itself, from a static
`file_operations` table baked into the object with the ioctl handler
at byte 40 and a second copy at 44, which is where `unlocked_ioctl`
and `compat_ioctl` sat in the kernel it was built against (6.1's
layout, and 5.10's). Every other slot is zero. **The port works only
by coincidence**: 6.6 dropped the `iterate` slot, which moves both
fields to 36 and 40, and 6.12 then added the 4-byte `fop_flags` at the
top of the struct, which moves them back to 40 and 44. The 6.12 port
never fell over it because the two mainline changes cancel. The 6.6
bisection branch did fall over it (4.2): the blob's handler landed on
`compat_ioctl`, `unlocked_ioctl` stayed NULL, every ioctl on the
device returned ENOTTY, and the SFTL still printed its init-ok line,
so the symptom was an empty serial number and a random MAC two
services later, not an error at the source. There is no way to see
this from the C side because the table is in the blob; the port pins
it instead with two `static_assert`s on the offsets in `rkflash_blk.c`
(9adeb81c34c), so the next `file_operations` change fails the build
rather than the device. Any future base needs those two numbers
checked against `include/linux/fs.h` first, and the two blob tables
shifted as on the 6.6 branch (02e174bf1be) if they moved.

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

**savedefconfig drops what is default on the source kernel, and a
different kernel may not default it.** The 6.1 defconfig named
`CONFIG_HW_RANDOM_ROCKCHIP=y`; the 6.12 canonicalisation dropped the
line because 6.12 defaults it on with `HW_RANDOM`, and the 6.6
bisection image built from the same file came up without the hardware
RNG, because 6.6 does not default it. Nothing in the build says so.
The check that catches this class is to resolve the config on both
kernels and compare every symbol that exists in both Kconfig trees
(28 such differences between the 6.12 port and the 6.6 image, two of
them real: `HW_RANDOM_ROCKCHIP` and `PHYLIB`). Options that userspace
depends on are listed explicitly in the defconfig from now on.

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

Bisection, first point: the branch before the v6.12.111 stable merge
(`f7ee4a0347b` plus `2d0ceae0721`, `161e2f8fefc`, `47227328c1f`,
`c63830b0f5e`, pushed by meta-rithum as `claude/bisect-pre-merge-6.12.69`
at 8fbd6a00c3d, verified as 6.12.69 on the device with pins working):
7 of 12, every failure the same four-retry ladder at 50 MHz. Three
ordered points on the same unit and loop:

    6.1.188                   6 of 6    no failure ever seen
    6.12.69 pre-merge tree    7 of 12   five four-retry failures
    6.12.111 port             1 of 6    five four-retry failures
                              (pooled with B, D, E and the earlier
                              gpio-ranges loops: 9 of 38)

Against the port's pooled rate, 7 of 12 is better at p about 0.01;
against 6.1's 6 of 6, it is worse at p about 0.04 (a twelve-boot 6.1
run would firm that up). So the margin was lost in at least two steps:
most of it between 6.1 and develop-6.12 at 6.12.69, and most of what
remained inside the stable span. Same fault, different probability,
which is what a margin eaten by unrelated changes looks like, and it
says the search is for what perturbs a hardware margin, not for a
misconfiguration.

The two halves are bisected separately:

- The stable span, by intermediate tags. Every one of the 43 tags is
  an ancestor of v6.12.111. Three points are pushed, each the
  pre-merge tree (`claude/bisect-pre-merge-6.12.69`, now 52b828114cc
  with the GT911 guard on top) with one stable tag merged and the
  guard added on top: `claude/bisect-6.12.80` (a2c8bbcd0be),
  `claude/bisect-6.12.90` (818307b7b44) and `claude/bisect-6.12.100`
  (8b433a4890f). Their earlier tips (1a5bbe7f798, 5efa36aeaaf,
  7f574f49199) and the pre-merge base at 8fbd6a00c3d lacked the guard
  and must not be booted: that recipe left `27e267ccb8e` out as
  irrelevant to a WiFi measurement, which was wrong, because without it
  the vendor driver reprograms the touch controller's flash on every
  boot (4.5). Unit 0002 was clobbered by the pre-merge and the first
  .90 boots and has been restored; the pre-merge 7 of 12 was measured
  with a mis-flashed touch controller, which does not affect the wlan0
  numbers. Conflicts were resolved by one rule: a file stable
  never touched again after that tag takes the v6.12.111 merge's
  resolution verbatim, and a file it did touch again takes that
  resolution with the later stable commits reverse-applied (the mmc
  hosts, i2c-core-base.c, arch/arm64/Kconfig). Each point's vendor
  delta in those files was checked to equal the .111 merge's, and the
  affected drivers compile with clang for ARM. Run .90 first, then .80
  or .100 by its result. Twelve boots per point; about six points to
  a single stable release, and the candidates in that release are then
  readable. Stable commits in the
  span that plausibly move boot timing or a margin, for when the range
  narrows: the driver-core deferred-probe timeout trio (67c79e1cdbf,
  d25dadf7423, 962eae1f30e, which change when fw_devlink relaxes
  links; the port's first SDIO command sits 125 ms earlier in the boot
  than the pre-merge tree's), workqueue and driver core moving to
  `system_percpu_wq`, the regulator core's constraint clamp and
  freezable init work, cpufreq core fixes, and the pinctrl-rockchip
  pin-count reset on re-probe.
- A control for the design above: the pre-merge tree differs from the
  port not only by the stable merge but by the post-merge rithum
  commits (vendor codec and its DT node, panel bit-bang, GT911 guard,
  8250 diagnostic, fbdev ops, OP-TEE gate, the four gpio fixes).
  `claude/bisect-pre-merge-plus-rithum` (08bc7102c28) is the pre-merge
  tree with all of them and no stable, so its only difference from the
  port is the stable merge. Twelve boots at about 7 of 12 say those
  commits are neutral and the stable bisection stands; a rate near the
  port's says one of them matters and the bisection moves there.
- The 6.1 to develop-6.12 half, by Rockchip's develop-6.6 (6.6.89):
  `claude/bisect-6.6` (fbd75edae26), which is develop-6.6 plus the low
  ZRELADDR, the decompressor FORTIFY guard, the SFTL link stub and
  thumb shims, the uart4 label fix, the rithum boards, the defconfig
  re-canonicalised for 6.6 (`CONFIG_DEBUG_WX`, and the GT911 driver
  left out because the vendor driver still calls
  `of_get_named_gpio_flags`, which 6.6 removed), the
  OP-TEE reboot gate, and a block-glue signature port for rkflash
  (develop-6.6 still carries the pre-6.5 `fmode_t` signatures). The
  vendor codec and the pre-conversion gpio driver are already there.
  It builds with clang (zImage and DTBs), and the compiled Pro DTB
  matches the 6.12 one node for node on the SDIO host, `sdio-pwrseq`,
  `wireless-wlan` and `io-domains`; the whole-DTB difference is the
  codec node's spelling, the OTP node's names and the gpio-ranges the
  6.6 driver does not need. A WiFi rate on it is therefore
  commensurable with the three points above. No display on this
  image: the panel bit-bang path is not carried.

  **fbd75edae26 stranded unit 0002 with a kernel panic at 1.3 s**, in
  a reboot loop, read off the serial console: NULL dereference at
  0x118 in `kobject_get`, from `elv_register_queue` via
  `blk_register_queue` and `device_add_disk`, from `rkflash_dev_init`
  in `rksfc_probe`. Nothing in userspace ever ran; the pings and DNS
  answers that suggested a live, port-less unit came from something
  else on the range. The cause: develop-6.6's rkflash allocates the
  gendisk with `blk_mq_alloc_disk()` and then swaps in a second queue
  from `blk_mq_init_queue()`. Since 6.2 the queue's sysfs kobject
  lives in the gendisk and `elv_register_queue()` reaches it through
  `q->disk`, which only the queue `blk_mq_alloc_disk()` made has set;
  the swapped queue has `q->disk` NULL, and 0x118 is the queue kobject
  offset in a NULL gendisk plus the kref. My first 6.6 port changed
  only the fops signatures and left the swap in; the 6.12 port had
  already removed it, so the fix (9f76f114ed2) is the same shape:
  keep the disk's own queue, apply the limits to it, free the tag set
  on unregister. It compiles; it has not been booted, and this path
  only runs on hardware with the SFC NAND, so a QEMU boot cannot
  exercise it. A separate real omission found from the resolved
  config, the Rockchip hardware RNG driver being off, is fixed too
  (8c618fec6d9, see 3.3) but was not the cause.

  With the queue fix the 6.6 image boots (console-attended): rkflash
  registers, dm-verity mounts the root, init runs, and **the SDIO card
  attaches first time with no -110**: 400 kHz at 0.730 s, 50 MHz at
  0.760 s, "new high speed SDIO card" at 0.762 s, wlan0 with the chip's
  own MAC. One boot, not a rate, but on a kernel 95k commits after
  6.1 and 113k before the pre-merge tree, a first-attempt attach
  points the larger loss of margin at the 6.6-to-6.12.69 half (this did
  not survive: the twelve-boot anchor below came back 8 of 12). The
  attach sits at 0.76 s here against 1.07 s on the port; the whole
  boot is earlier. The twelve boots waited on a second blocker, now understood:
  vendor storage returned nothing, so `vendor-serial` was empty, S23
  parked the boot before ssh, the device key was not found and the
  RTL8152 got no MAC. The "flash vendor storage:20170308 ret = -1"
  console line is noise (that driver serves SFC NOR only and prints -1
  on every SFC NAND kernel, 6.12 included). The cause is in the SFTL
  blob: it creates `/dev/vendor_storage` from a static
  `struct file_operations` with the ioctl handler at byte offset 40
  and a copy at 44, which is where `unlocked_ioctl` and `compat_ioctl`
  sat in the kernel the blob was built against. 6.6 removed the
  `iterate` slot, so on 6.6 those fields are at 36 and 40: the blob's
  handler lands on `compat_ioctl`, `unlocked_ioctl` stays NULL, and
  every ioctl on the device returns ENOTTY while the SFTL init itself
  reports success. **6.12 works by coincidence**: it added a 4-byte
  `fop_flags` before `llseek`, which puts `unlocked_ioctl` back at 40.
  Fixed on the 6.6 branch by shifting the two blob tables one word
  (02e174bf1be, relocations verified at 0x24 and 0x28 in the object),
  and pinned on both branches with `static_assert`s on the two offsets
  in `rkflash_blk.c` (9adeb81c34c on the port), so the next layout
  change fails the build instead of the device. The kernel side of the
  vendor path is otherwise identical to the port's after carrying the
  SFC unaligned-access check (5d36ec40bf0) that develop-6.6 predates;
  the 8250 LSR diagnostic drop is carried too so the console is
  readable. A second boot-killer on 6.6 was the regulator debug-list race
  (4.10), which also strands the board before init, intermittently.
  The 6.6 branch is rebuilt at ff18b4898c2 with every fix (queue, RNG,
  SFC check, blob fops shift, regulator lock, 8250 diagnostic drop) and,
  per the rule below, its next boot is console-attended: expected to
  reach sshd with a serial and a MAC, not yet shown to.

  **6.6 result: 5 of 5 clean**, plus a console-attended first-attempt
  attach and a live check, seven clean boots and not one -110. Five is
  not twelve (p about 0.07 under the pre-merge rate), and the attach
  sits at 0.76 s against 1.07 s on the port, but it moves the primary
  loss of margin into the 6.6-to-6.12.69 half, 113k commits, and out
  of anything inherited from before 6.6 (superseded: pooled 6.6 is
  16 of 20, one band with 6.12.69). The sixth boot stranded on
  the vendor-storage fault above (the layer's serial fallback handled
  an empty read, not a hung one); the blob fix at 02e174bf1be removes
  the fault itself.

  The table now reads:

      point                  from 6.1     rate     failures
      6.1.188                0            12 of 12 none
      6.6.89                 95k          5 of 5   none
      6.12.69 pre-merge      209k         7 of 12  five four-retry
      6.12.111 port          + 43 tags    1 of 6   five four-retry

  **What the dumps never covered.** vdd_core on this board is a PWM
  regulator on pwm0 (`pwms = <&pwm0 0 5000 1>`, 827 to 1340 mV,
  init 1015 mV, inverted polarity), and it is also vdd_log: the SoC's
  logic rail, which sets the timing of the dw_mmc IP, the CRU dividers
  and the core side of the I/O cells. cpufreq moves it with every OPP
  change (950 mV at 408 and 600 MHz, 1025 down to 950 at 816 by
  leakage bin, 1125 at 1008). Neither the PWM duty nor the regulator
  voltage was in any comparison, and the one clock difference ever
  seen between 6.1 and the port, `clk_pwm0` enabled once against
  twice, was dismissed as cosmetic. Everything that changed between
  the passing and failing kernels in this area is real: the Rockchip
  cpufreq driver went from a module_init to a platform driver with an
  early init (so when the first OPP transition happens moved), the
  OPP voltage selection code changed (the PVTM selection result is no
  longer even printed), pwm-regulator gained a boot-on state fix, the
  PWM core was rewritten, and the stable span carries "regulator:
  core: clamp voltage constraints before applying apply_uV"
  (93b078e5942), which sits exactly on the path that applies the
  1015 mV init value to a continuous-range PWM regulator. A lower
  logic voltage, or a voltage step landing on the switch, is a
  margin loss that is independent of bus rate and timing mode, which
  is the shape of every result so far. The three kernels that pass
  (6.1; 6.6, whose attach at 0.76 s precedes any cpufreq activity;
  the port with the transaction pushed past 1.2 s) and the ones that
  fail differ in exactly the state cpufreq owns.

  Correction from meta-rithum, accepted: the stable regulator-core
  clamp commit (93b078e5942) cannot touch vdd_core. Without a
  `voltage-table` the PWM regulator is continuous-range with no
  `list_voltage`, so the block that commit moved never runs. It is
  out.

  Read on 6.6 at steady state (525 s up): vdd_core 950120 uV, pwm0
  period 5000 ns, duty 1200 ns, inverted (24 percent: 827000 +
  0.24 x 513000 = 950120, so duty and voltage agree); governor
  interactive at 408 MHz, 158 transitions, almost all time at
  408 MHz; `pvtm-volt-sel=4` at 0.913 s (so 816 MHz runs at 975 mV,
  1008 at the L4 value). The rail is not at the DT's 1015 mV init
  value once cpufreq has settled; it sits at the 950 mV floor. On 6.6
  the SDIO attach at 0.76 s precedes the PVTM read at 0.91 s and
  therefore any cpufreq activity: the switch ran at the loader's core
  voltage. Raw PWM registers cannot be read with devmem (the driver
  gates pclk when idle and the block reads back 0x13 everywhere);
  debugfs is the source.

  The transition-timing form of this did not survive the G captures:
  cpufreq initialisation completes 58 ms before the 50 MHz switch on
  6.1 (12 of 12), 64 ms before on a passing port boot and 59 ms before
  on a failing one. The smallest gap belongs to the kernel that never
  fails, the two port boots are within 1 ms of each other and diverge
  anyway, and with an 80 ms minimum sample time the interactive
  governor cannot have stepped down before the switch on any of the
  three. What separates 6.1 from the port in the timeline is absolute
  position (the port's mmc probe runs about 50 ms later and takes
  10 ms longer), not the gap. The captures show only cpufreq
  initialisation, so a later transition is not excluded by them, but
  the init-time overlap is.

  What survives is the steady-state form: at cpufreq init the rail is
  moved from the DT's 1015 mV to the OPP voltage of whatever frequency
  the loader left the CPU at, using the voltage column the OPP
  selection code picks. 6.1 printed `pvtm-volt-sel=4`; the port prints
  that only at debug level, and its OPP selection code differs from
  6.1's by about a hundred lines in the leakage, temperature and
  PVTM paths (the OTP-based table adjustment exists in both). If the port lands on a lower column, or
  adjusts the table, the switch runs at a lower core voltage on every
  boot, which is a margin loss of exactly the observed shape. Reads
  that settle it, no build: `/sys/kernel/debug/opp/cpu0/opp:*/supply-0/
  u_volt_target` on 6.1 and the port (the effective per-OPP voltages),
  the steady vdd_core `microvolts` and pwm0 duty on both, and the
  port's dmesg for `adjust opp-table by otp`, `volt-sel`, `pvtm` and
  `idc`. Then `claude/exp-no-cpufreq` (b18a364c1f3), and if it is
  clean, two bootargs-only confirmations on a byte-identical port
  binary (a FIT repack, no rebuild): `cpufreq.off=1`, which must
  reproduce the clean result, and `cpufreq.default_governor=performance`,
  which keeps transitions out but the rail at the top OPP's voltage
  and so separates "more margin" from "no transition". If the OPP
  voltages and the steady rail match 6.1's and the no-cpufreq image
  runs at the port's rate, this line is dead and the bench decides.

  **Correction on A and C (meta-rithum):** the post-power-on delay is
  the only intervention that has ever moved the rate, and it is
  dose-dependent. Total -110s across six boots: 20 with no delay, 10
  at 100 ms, 3 at 300 ms, with the delay arms 12 of 12 up against the
  port's 1 of 6, while B, D and E are identical to baseline at 1 of 6
  and 20 errors each. That is a settling effect after the pwrseq
  releases WL_REG_ON, not anything about the switch itself, and the
  errors do not vanish, so it is margin. It was recorded above as "not
  restoring a 6.1 behaviour" because 6.1 needs no delay; that is
  true and beside the point. What 6.1 does differently is still the
  question, but the delay says what kind of thing it is: something
  that makes the card need about 300 ms after reset release on the
  port and none on 6.1. Two kernel-side candidates for that have not
  been read: how long the reset was held before release (the pwrseq
  claims the line asserted at its own probe and holds it until the
  host powers up, so the pulse is "probe of sdio-pwrseq" to "allocated
  mmc-pwrseq", which the G captures hold for 6.1, the port and 6.6), and
  what the module's rails do across that pulse, which is the bench.
  pre-merge-plus-rithum is running at 5 of 6 with one four-error boot
  so far, so the post-merge rithum commits are not implicated. All of
  the above is warm reboots; cold boots may differ.

  **Control result: `pre-merge-plus-rithum` 10 of 12**, strictly
  bimodal (every failure exactly four errors, every pass zero), no
  refcount underflows. Against plain pre-merge's 7 of 12 that is no
  effect (p about 0.37), so the post-merge rithum commits, including
  the four gpio-rockchip fixes that sit on the pwrseq reset path, are
  clear. The table:

      6.1.188                          12 of 12
      6.6.89                           8 of 8, then 8 of 12 (16 of 20)
      6.12.69 pre-merge, plain         7 of 12
      6.12.69 pre-merge + rithum stack 10 of 12
      6.12.111 port                    1 of 6 (needs twelve)

  The 6.12.69-to-6.12.111 stable span is the only established step
  (below). Two candidates that
  looked good on rate ordering are excluded at source level: the
  regulator-core clamp (above) and the dw_mmc internal-phase change
  (rk3308 binds as rk3288 and keeps `clk_set_phase`). Two more that
  were raised are outside the stable span but not outside the problem:
  the rk3308 iomux route update (a8f254854858) and the dw_mmc
  tasklet-to-BH-workqueue conversion (921c87ba3893) are both v6.11-rc1
  mainline, so present throughout 6.12.69 to 6.12.111 and unable to
  explain that drop. An earlier note here said both were already in
  rithum-6.1; `merge-base --is-ancestor` says neither is in rithum-6.1
  nor in the 6.6 bisection point, so both straddle the 6.6-to-6.12.69
  half exactly (meta-rithum caught this). Of the two, the route update
  is dead on content: the vendor 6.1 tree already carries the rk3308
  and rk3308b route tables that commit upstreamed, and the tables are
  byte-identical between 6.1 and the port. The BH conversion is live:
  6.1 runs dw_mmc's request state machine, including the code that
  handles the CMD52 response timeout, from a tasklet, the port from
  `system_bh_wq`. Same softirq-level latency class, different
  scheduling and re-entry rules. `claude/exp-revert-mmc-bh`
  (7d09ea1c43d) is the 6.12.69 control point (`pre-merge-plus-rithum`,
  08bc7102c28) with dw_mmc alone put back on the tasklet; the other
  twelve hosts the commit touched are left as they are, and the stable
  span does not touch dw_mmc.c or dw_mmc.h so the change reads the same
  on either base. It is expected to reach sshd and was the only build
  prepared for the 6.6-to-6.12.69 half; it is moot now (below) and
  stays pushed unrun.

  Why the two single-commit reverts sit on different bases (meta-rithum
  caught the first cut of this one, based on the port, before it cost a
  run): a revert is measured against the baseline it can move.
  `88e338bd9b6` is inside the stable window, so the port at about 17
  percent is exactly where its effect appears, and
  `exp-revert-probe-ready` stays on the port. `921c87ba3893` can only
  explain the first drop, 8 of 8 to 17 of 24; on the port it would move
  roughly 17 to 24 percent, 2 of 12 against 3 of 12, which no number of
  boots separates behind the larger stable-window regression. On the
  6.12.69 point, the best-measured baseline in the set with 24 boots, a
  restored 12 of 12 against 17 of 24 is p about 0.03 in one run. The
  plus-rithum arm is used rather than plain pre-merge because its image
  is the one banked and, at 10 of 12, the cleaner of the two. The stable midpoint
  `claude/bisect-6.12.90` (818307b7b44) is built and waiting on the
  port's twelve boots. A and C stay bounds, not a fix: a fixed delay
  would hide a margin that a cold boot or another card lot could
  reopen.

  Reading the span for what could move boot ordering or latency on
  this board gives about 110 commits in driver core, workqueue,
  scheduler, timers, ARM mm, DMA, OF, clk, gpio, pinctrl, regulator
  and mmc core. Two stand out and are not excluded by anything read so
  far: `88e338bd9b6` "driver core: Don't let a device probe until it's
  ready" (first in v6.12.86, so the .90 point contains it and the .80
  point does not), which changes when devices may probe and is the
  kind of change that would move the port's mmc probe 50 ms later than
  6.1's, and the deferred-probe timeout trio (`67c79e1cdbf`,
  `d25dadf7423`, `962eae1f30e`). `552b9077733` (mmc fixed driver type)
  touches only the eMMC path and is out. A single-commit test is
  prepared alongside the tag bisection: `claude/exp-revert-probe-ready`
  (d9e24787603) is the port with `88e338bd9b6` and its kernel-doc
  follow-up `c5a22b92ed4` reverted, byte-identical otherwise; it builds
  to a zImage and is expected to reach sshd. If the port's twelve boots hold at its rate, .90 decides
  which side of v6.12.86 the fault sits, and the revert build decides
  whether that commit alone carries it.

  **`exp-no-cpufreq` 4 of 12** (b18a364c1f3, gated on kernel version
  before any boot counted), bimodal as ever: every failure exactly four
  errors, every pass zero, no refcount underflows. That kills the
  voltage line in both of its forms at once. With CPU_FREQ off there
  are no OPP transitions, and vdd_core sits at 1011680 uV (the DT's
  1015000 init value on the nearest duty step, 1793/5000 inverted)
  instead of the 950120 uV the interactive governor settles at. So the
  rail is 62 mV higher, the transitions are gone, and the rate is
  indistinguishable from the port's own. A clean result here would have
  been confounded between the two; a failing one is not. Neither the
  transitions nor the steady-state core voltage is the mechanism. The
  bootargs-only confirmations (`cpufreq.off=1`,
  `cpufreq.default_governor=performance`) are no longer needed.

  **The 6.6 anchor came back 8 of 12** (ff18b4898c2 as 6.6.89, gated,
  vendor storage confirmed working first, same bimodal signature, no
  underflows). That was the question the two-drops model rested on, and
  the answer is no. Pooled 6.6 is 16 of 20; against 6.12.69's 17 of 24
  that is p about 0.5, and the two 6.6 runs are consistent with each
  other (p about 0.11), so pooling is fair. The first 8 of 8 was the
  tail: at 71 percent, eight passes in a row happen about 6 percent of
  the time. There is no 6.6-to-6.12.69 regression. Everything from 6.6
  to 6.12.69 is one band that nothing separates, and the only
  established drop is 6.12.69 to 6.12.111, p about 0.015, inside the
  43 stable tags.

  Retired by that: the whole 6.6-to-6.12.69 line, `921c87ba3893` and
  `a8f254854858` as anything but already excluded, and the two
  independent drops model. `claude/exp-revert-mmc-bh` (7d09ea1c43d)
  stays pushed as built but is not to be run; the earlier instinct to
  exclude those two commits was right in effect and wrong in reason.
  Two method notes from the episode. An eight-boot anchor is not an
  anchor; twelve is the floor for any rate that a decision rests on.
  And `merge-base --is-ancestor` is the wrong instrument for a revert
  branch: `git revert` leaves the original in history, so ancestry says
  `88e338bd9b6` is present on `exp-revert-probe-ready`. Content is the
  check, and by content that branch is core.c -15, dd.c -20,
  device.h -45 against the port and nothing else.

  **"6.1 is clean" is a twelve-boot claim** and it is not established
  either: 12 of 12 against 6.6's 16 of 20 is p about 0.12. 6.1 does
  look different in kind (twelve boots with zero -110 anywhere, against
  sixteen on 6.6), but if 6.1 is really nearer 85 percent this is not a
  6.12 regression at all; it is a marginal fault every kernel on this
  board has, which something in the stable window made much worse.
  That changes what a successful probe-ready revert means: restoring
  the port to about 75 percent is "back to the band", not "fixed", and
  the remaining margin is the bench's. If 6.1 really is at 100 percent
  there are two drops after all, but the first is 6.1 to 6.6, and that
  window is not one the tag method opens. rithum-6.1 and the 6.6 point
  do not sit on a line: their merge-base is a Rockchip vendor commit
  in no tag (243363ccfdc2, on meta-rithum's full clone; this clone is
  shallow-excluded at develop-6.1 and cannot compute it), with about
  12k commits on the 6.1 side and 95k on the 6.6 side. A bisection
  across the 95k is mechanically valid but every point lacks the
  rithum stack, so each of about seventeen steps is a hand re-port for
  one boot, against about six steps for the tag window where the
  established drop is. If that reading ever needs acting on, the
  method is a subsystem swap, not a bisection: 6.1's drivers/mmc
  (132 files, about 4.5k lines each way against the 6.6 tree) onto
  the 6.6 base or the reverse, one build per hypothesis, which fits a
  bug that nothing short of a whole-subsystem or timing change has
  ever moved. Twelve more 6.1 boots decide which reading holds; the
  image is banked and it is boots, not a build. Either way the tag
  window is the right spend first.

  Vehicles built and banked by meta-rithum, independent of the deploy
  directory, so any of them can start without a build: 6.1.188
  (12 of 12), 6.12.69 pre-merge + rithum, 6.12.111 CPU_FREQ off, and
  the port itself (ready for its twelve boots and the reads). Unit 0002
  is free; the vendor-devkey test is deferred.

  Run order: the port's twelve boots first, because the port is the
  baseline the probe-ready revert is measured against and 1 of 6 is
  not a rate (the reads ride along: OPP debugfs `u_volt_target`,
  vdd_core, pwm0 duty, cpufreq state, dmesg `volt-sel`/`pvtm`/`idc`,
  and the pwrseq probe timestamps that give the reset-pulse length);
  then `exp-revert-probe-ready`; then twelve more 6.1 boots to settle
  whether 6.1 is at 100 percent or in the band; then `.90` if the
  revert does not move the rate. The port's gate has passed and its
  DVFS reads are being taken with cpufreq present, then its twelve
  boots and probe-ready's twelve run unattended. Both images report
  6.12.111, so only the VERSION_ID stamp separates them; every flash
  gates on it.

  Two rules from this. Every branch states whether it is expected to
  reach sshd, and a tree from a new vendor base does not go on a bench
  unit until it has booted somewhere: a boot on the layer's QEMU
  machine catches anything before the platform probes, and anything
  in a platform probe needs a hand-check of every block, DT and
  driver-core API the vendor base predates, which is what was missed
  here.

  Every branch now states whether it is expected to reach sshd. The
  6.12-based points (`bisect-pre-merge-6.12.69`, `.80`, `.90`, `.100`,
  `pre-merge-plus-rithum`) are the port's own config and drivers with
  only the stable span varied, and the pre-merge tree reached sshd on
  twelve boots, so they are expected to. `bisect-6.6` reached sshd at 9f76f114ed2 and ran 8 of 8; the later
  fixes on that branch (vendor storage fops shift, regulator lock,
  RNG config) change nothing on the SDIO path but its tip ff18b4898c2
  still wants a console-attended first boot before it is used for the
  extra anchor boots, per the rule above.

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
write those bytes to 0x8047, then 0x01 to 0x8100, with the version byte
raised above the one the chip holds.** The controller silently ignores
a config whose version byte is lower than the stored one: the generic
table carries 0x47, the factory file 0x41, so writing the file as-is is
accepted without error and changes nothing. Bump byte 0 (0x48 was used
on 0002 the second time) and recompute the checksum at offset 184 so
the sum of 0x8047..0x80FF is zero modulo 256; every other byte stays
factory-exact. Read 0x8047 back afterwards. A stored version above
0x47 also stops the generic table installing again on that chip; a
chip still at 0x41 is unprotected. Any unit that booted a tree without
the guard needs the repair. Do not boot such trees on any unit; see
4.2 for the bisection branches that did.

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

### 4.10 Regulator debug list corrupted by concurrent probes

Found on the 6.6 bisection image, present in this port and in
rithum-6.1. The vendor regulator core keeps a private list of debugfs
helpers (`regulator_debug_list`) and appends to it in
`rdev_init_debugfs()` with a bare `list_add()`, after
`regulator_register()` has dropped `regulator_list_mutex`.
`regulator-fixed` probes asynchronously, so on a four-core boot several
fixed regulators register at once from `events_unbound` workers and two
inserts can interleave. With list debugging on, that is:

    list_add corruption. next->prev should be prev (...), but was ...
    kernel BUG at lib/list_debug.c:29!
    Workqueue: events_unbound async_run_entry_fn
     __list_add_valid_or_report from rdev_init_debugfs
     rdev_init_debugfs from regulator_register
     regulator_register from devm_regulator_register
     devm_regulator_register from reg_fixed_voltage_probe
     ... from __driver_attach_async_helper

The dying worker is the async probe worker and it exits with IRQs off,
so the async probe chain never completes; `dm-init` then waits for
device probing forever ("waiting for all devices to be available") and
the board never reaches init. It fired at 0.19 s on one 6.6 boot in
six and would look, from outside, like every other strand. The fix
(8a97f566878 here, ff18b4898c2 on the 6.6 branch) gives the list its
own mutex around the insert and the removal loop. rithum-6.1 carries
the same code and the same exposure.

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
- A closed blob's success message is not evidence that what it set
  up works. The SFTL reported vendor storage init ok with a dead ioctl
  table; the first real check is the consumer (`vendor-serial` exit
  status, a non-random MAC), and any structure layout a blob bakes in
  gets a `static_assert` in the C that links it (3.1).


## 7. Open items

- Repair the GT911 config on every unit other than 0002 that booted a
  tip before 27e267ccb8e (4.5). 0002 is repaired and verified.
- OP-TEE shutdown (4.7): the reboot-time trigger is removed, the
  use-after-free behind it is not fixed. Watch pstore for `refcount_t:
  underflow` across the reboot loop; design the cookie capture the 6.1
  comment asks for.
- WiFi SDIO is intermittent on 6.12 (4.2): 6.1 passes 12 of 12 on the
  same unit, 6.6 16 of 20, 6.12.69 17 of 24, the port 1 of 6.
  Everything readable on the SoC side is identical between the
  kernels; DVFS, bus rate, timing mode and sample phase are excluded,
  and 6.6 to 6.12.69 is one band. The 6.12.69-to-6.12.111 stable span
  is the only established step (single-commit test
  `exp-revert-probe-ready`, midpoint `.90`). Whether 6.1 is truly clean
  or at the top of the band needs twelve more 6.1 boots. The bench
  (scope on WL_REG_ON, CLK, CMD and the module's rails across the clock
  switch; real power cycles) is next if the software bisection does
  not land. The delay variants A and C are not fixes. This blocks
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
