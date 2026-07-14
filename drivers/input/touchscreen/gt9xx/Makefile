# SPDX-License-Identifier: GPL-2.0
# The built-in config tables (gtp_dat_*) are only referenced when
# GTP_DRIVER_SEND_CFG is set; with it off (we rely on the panel's own
# flashed GT911 config) they are legitimately unused.
ccflags-y += -Wno-unused-variable

obj-$(CONFIG_TOUCHSCREEN_GT9XX)	+= goodix_gt9xx.o

#goodix_gt9xx-y		+=goodix_tool.o
goodix_gt9xx-y		+=gt9xx.o
goodix_gt9xx-y		+=gt9xx_update.o
