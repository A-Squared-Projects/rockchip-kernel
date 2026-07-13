/* SPDX-License-Identifier: GPL-2.0 */
/*
 * The prebuilt SFTL blobs (rk_sftl_arm_v7*.S) were compiled with -pg
 * and call __gnu_mcount_nc, so linking them normally requires
 * CONFIG_FUNCTION_TRACER just for the symbol. Provide the no-op stub
 * when the kernel is built without the function tracer - the same
 * restore-and-return sequence the dynamic-ftrace entry point uses
 * before any site is patched (see arch/arm/kernel/entry-ftrace.S).
 */
#include <linux/linkage.h>

ENTRY(__gnu_mcount_nc)
	push	{lr}
	ldr	lr, [sp, #4]
	ldr	pc, [sp], #8
ENDPROC(__gnu_mcount_nc)
