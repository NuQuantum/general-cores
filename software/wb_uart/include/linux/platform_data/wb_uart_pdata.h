/* SPDX-License-Identifier: GPL-2.0-or-later
 * SPDX-FileCopyrightText: 2024 CERN (home.cern)
 */

#ifndef __WB_UART_PDATA_H__
#define __WB_UART_PDATA_H__

#include <linux/bitops.h>

#define WB_UART_NAME_MAX_LEN 32
#define WB_UART_BIG_ENDIAN BIT(0)

struct wb_uart_platform_data {
	unsigned long flags;
	char wb_uart_name[WB_UART_NAME_MAX_LEN];
};

#endif
