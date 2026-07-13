# SPDX-License-Identifier: GPL-2.0

obj-$(CONFIG_RK_NANDC_NAND) += rkflash_blk.o rkflash_debug.o rknandc_base.o nand_boot.o flash.o nandc.o
obj-$(CONFIG_RK_SFC_NAND) += rkflash_blk.o rkflash_debug.o rksfc_base.o sfc_nand_boot.o sfc_nand.o sfc.o
obj-$(CONFIG_RK_SFC_NAND_MTD) += sfc_nand_mtd.o sfc_nand_mtd_bbt.o
obj-$(CONFIG_RK_SFC_NOR) += rkflash_blk.o rkflash_debug.o rksfc_base.o sfc_nor_boot.o sfc_nor.o sfc.o
obj-$(CONFIG_RK_SFC_NOR_MTD) += sfc_nor_mtd.o

obj-$(CONFIG_RK_SFTL) += rksftl.o

# The prebuilt ARM SFTL blobs call __gnu_mcount_nc (-pg); satisfy the
# reference with a no-op stub when the function tracer is disabled.
ifndef CONFIG_FUNCTION_TRACER
rksftl-$(CONFIG_ARM) += mcount_stub.o
endif

ifdef CONFIG_CC_IS_CLANG
ifdef CONFIG_THUMB2_KERNEL
rksftl-$(CONFIG_THUMB2_KERNEL) += rk_sftl_arm_v7_thumb.o
else
rksftl-$(CONFIG_ARM64) += rk_sftl_arm_v8_clang.o
rksftl-$(CONFIG_ARM) += rk_sftl_arm_v7.o
endif

else

ifdef CONFIG_THUMB2_KERNEL
rksftl-$(CONFIG_THUMB2_KERNEL) += rk_sftl_arm_v7_thumb.o
else
rksftl-$(CONFIG_ARM64) += rk_sftl_arm_v8.o
rksftl-$(CONFIG_ARM) += rk_sftl_arm_v7.o
endif
endif
