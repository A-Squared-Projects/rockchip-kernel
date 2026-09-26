# Porting the Rithum Switch kernel from 6.1 to 6.12

What was learned bringing the RK3308 Rithum Switch kernel from the
rithum-6.1 tree (Rockchip develop-6.1 plus upstream stable) onto Rockchip's
develop-6.12, and what it cost. Written after the port booted and passed
the same selftest as 6.1 on RithumSwitch-0002 (Switch Pro, RK3308 rev B
silicon). Branch: `claude/kernel-6-12-port-kg1g39`, verified on hardware at
49d61b7249d, based on develop-6.12 (470f9dccb, 6.12.69) with v6.12.111
merged on top.

The short version: the port is 32-bit ARM, Thumb-2, same rkflash/SFTL
NAND stack, same boot image layout. No AArch64 switch was ever needed.
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

### 4.2 WiFi SDIO timeouts were the same bug in disguise

With the driver-side fix alone, SDIO still failed: init at 400 kHz
succeeded, then every CMD52 at 50 MHz timed out (`-110`), on every retry
frequency. No pin error was logged. The `gpio-ranges` commit fixed it
without any MMC change. The ranges the fallback produced were numerically
identical to the DT ones, so the difference is *when* they exist: the
fallback registers the range after `gpiochip_add_data` has already
published the chip, and a consumer whose deferred probe fires in that
window (the WiFi power sequence's reset GPIO is the obvious candidate)
requests its line with no range in place and skips the pinctrl side of
the request. The DT path registers during chip setup and closes the
window. Not proven on hardware, but it is the reason `gpio-ranges` is
load-bearing rather than cosmetic.

Lesson recorded by the test side: "no pin-not-registered messages" was
not sufficient evidence that pin mapping was correct.

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

### 4.7 /dev/fb0 could not be read

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
predates that commit.

### 4.8 Pre-existing noise, verified on a 6.1 boot of the same hardware

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
- Confirm `/dev/fb0` reads on hardware after the fbdev read/write fix
  (4.7); it has only been compiled.
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
