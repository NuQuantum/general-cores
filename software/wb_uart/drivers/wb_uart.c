// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2024 CERN (home.cern)

#include "wb_uart.h"

#include <linux/version.h>
#include <linux/types.h>
#include <linux/tty.h>
#include <linux/tty_flip.h>
#include <linux/platform_device.h>
#include <linux/platform_data/wb_uart_pdata.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/interrupt.h>
#include <linux/mod_devicetable.h>
#include <linux/io.h>

#define MAX_NBR_OF_BYTES_PER_IRQ 32
#define wbu_MEM_BASE 0

struct wbu_memory_ops {
#if KERNEL_VERSION(5, 8, 0) <= LINUX_VERSION_CODE
	u32 (*read)(const void *addr);
#else
	u32 (*read)(void *addr);
#endif
	void (*write)(u32 value, void *addr);
};

struct wbu_channel {
	spinlock_t	lock;
	struct tty_port tty_port;
	unsigned int	open_count;
	unsigned int	nb_bytes;
	unsigned int	ptr_read;
	unsigned int	ptr_write;
};

struct wbu_desc {
	struct tty_driver	*tty_driver;
	void			*base_addr;
	struct wbu_memory_ops	memops;
	struct wbu_channel	channel;
};

enum wbu_irq_resource {
	wbu_IRQ = 0,
};

static inline void wbu_write_reg(struct wbu_desc *wbuart, u32 val, u32 offset)
{
	wbuart->memops.write(val, wbuart->base_addr + offset);
}

static inline u32 wbu_read_reg(struct wbu_desc *wbuart, u32 offset)
{
	return wbuart->memops.read(wbuart->base_addr + offset);
}

static inline int wbu_is_bigendian(struct platform_device *pdev)
{
	struct wb_uart_platform_data *wbu_pd =
		(struct wb_uart_platform_data *) pdev->dev.platform_data;

	return !!(wbu_pd->flags & WB_UART_BIG_ENDIAN);
}

static inline int wbu_check_type(struct wbu_desc *wbuart)
{
	if (wbu_read_reg(wbuart, UART_REG_SR) & UART_SR_PHYSICAL_UART)
		return 0;

	return -EINVAL;
}

static inline void wbu_enable_rx_interrupts(struct wbu_desc *wbuart)
{
	u32 cr = wbu_read_reg(wbuart, UART_REG_CR);

	cr |= UART_CR_RX_INTERRUPT_ENABLE;
	wbu_write_reg(wbuart, cr, UART_REG_CR);
}

static inline void wbu_disable_rx_interrupts(struct wbu_desc *wbuart)
{
	u32 cr = wbu_read_reg(wbuart, UART_REG_CR);

	cr &= ~UART_CR_RX_INTERRUPT_ENABLE;
	wbu_write_reg(wbuart, cr, UART_REG_CR);
}

static inline void wbu_enable_tx_interrupts(struct wbu_desc *wbuart)
{
	u32 cr = wbu_read_reg(wbuart, UART_REG_CR);

	cr |= UART_CR_TX_INTERRUPT_ENABLE;
	wbu_write_reg(wbuart, cr, UART_REG_CR);
}

static inline void wbu_disable_tx_interrupts(struct wbu_desc *wbuart)
{
	u32 cr = wbu_read_reg(wbuart, UART_REG_CR);

	cr &= ~UART_CR_TX_INTERRUPT_ENABLE;
	wbu_write_reg(wbuart, cr, UART_REG_CR);
}

static void wbu_port_shutdown(struct tty_port *port)
{
	struct wbu_desc *wbuart = dev_get_drvdata(port->tty->dev->parent);

	wbu_disable_rx_interrupts(wbuart);
	wbu_disable_tx_interrupts(wbuart);
}

static int wbu_port_activate(struct tty_port *port, struct tty_struct *tty)
{
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);

	wbu_enable_rx_interrupts(wbuart);
	return 0;
}

static const struct tty_port_operations wbu_port_ops = {
	.shutdown = wbu_port_shutdown,
	.activate = wbu_port_activate
};

static void wbu_memops_detect(struct platform_device *pdev)
{
	struct wbu_desc *wbuart = platform_get_drvdata(pdev);

	if (wbu_is_bigendian(pdev)) {
		wbuart->memops.read = ioread32be;
		wbuart->memops.write = iowrite32be;
	} else {
		wbuart->memops.read = ioread32;
		wbuart->memops.write = iowrite32;
	}
}

static int wbu_tty_tx_send(struct wbu_desc *wbuart, const char c)
{
	uint32_t reg = wbu_read_reg(wbuart, UART_REG_SR);

	if (reg & UART_SR_TX_BUSY)
		return -EBUSY;
	wbu_write_reg(wbuart, c, UART_REG_TDR);
	return 0;
}

static void wbu_tty_handler_tx(struct wbu_desc *wbuart)
{
	struct wbu_channel *channel = &wbuart->channel;
	int max_count = MAX_NBR_OF_BYTES_PER_IRQ;

	if (channel->nb_bytes == 0)
		return;

	spin_lock(&channel->lock);

	do {
		u8 c = channel->tty_port.xmit_buf[channel->ptr_read];
		int ret = wbu_tty_tx_send(wbuart, c);

		if (ret < 0)
			break;

		channel->ptr_read = (channel->ptr_read + 1) % PAGE_SIZE;
		channel->nb_bytes--;
		max_count--;
	} while (channel->nb_bytes && max_count);

	if (channel->nb_bytes == 0) {
		wbu_disable_tx_interrupts(wbuart);
		tty_port_tty_wakeup(&channel->tty_port);
	}

	spin_unlock(&channel->lock);
}

static void wbu_tty_handler_rx(struct wbu_desc *wbuart)
{
	struct wbu_channel *channel = &wbuart->channel;
	int max_count = MAX_NBR_OF_BYTES_PER_IRQ;

	if (!(wbu_read_reg(wbuart, UART_REG_SR) & UART_SR_RX_RDY))
		return;

	do {
		u8 c = (wbu_read_reg(wbuart, UART_REG_RDR) & 0xFF);

		tty_insert_flip_char(&channel->tty_port, c, TTY_NORMAL);
	} while ((wbu_read_reg(wbuart, UART_REG_SR) & UART_SR_RX_RDY) &&
		 (--max_count >  0));

	tty_flip_buffer_push(&channel->tty_port);
}

static irqreturn_t wbu_tty_handler(int irq, void *arg)
{
	struct wbu_desc *wbuart = arg;

	if (!(wbu_read_reg(wbuart, UART_REG_SR) & UART_SR_RX_RDY) &&
	    wbuart->channel.nb_bytes == 0)
		return IRQ_NONE;

	wbu_tty_handler_rx(wbuart);
	wbu_tty_handler_tx(wbuart);

	return IRQ_HANDLED;
}

static void wbu_channel_init(struct wbu_channel *channel)
{
	spin_lock_init(&channel->lock);
	channel->open_count = 0U;
	channel->nb_bytes = 0U;
	channel->ptr_read = 0U;
	channel->ptr_write = 0U;
}

static int wbu_tty_port_init(struct platform_device *pdev)
{
	struct wbu_desc *wbuart = platform_get_drvdata(pdev);
	struct wbu_channel *channel = &wbuart->channel;
	struct device *tty_dev;

	wbu_channel_init(channel);

	tty_port_init(&(channel->tty_port));
	tty_port_alloc_xmit_buf(&channel->tty_port);
	channel->tty_port.ops = &wbu_port_ops;

	tty_dev = tty_port_register_device(&(channel->tty_port),
					   wbuart->tty_driver,
					   0,
					   &(pdev->dev));

	if (IS_ERR_OR_NULL(tty_dev)) {
		tty_port_put(&channel->tty_port);
		return PTR_ERR(tty_dev);
	}

	return 0;
}

static void wbu_tty_port_exit(struct platform_device *pdev)
{
	struct wbu_desc *wbuart = platform_get_drvdata(pdev);
	struct wbu_channel *channel = &wbuart->channel;

	tty_unregister_device(wbuart->tty_driver, 0);
	tty_port_free_xmit_buf(&channel->tty_port);
	tty_port_destroy(&channel->tty_port);
}

static int wbu_tty_open(struct tty_struct *tty, struct file *file)
{
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);
	struct wbu_channel *channel = &wbuart->channel;

	channel->open_count++;

	if (channel->open_count > 1)
		return -EBUSY;

	return tty_port_open(&channel->tty_port, tty, file);
}

static void wbu_tty_close(struct tty_struct *tty, struct file *file)
{
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);
	struct wbu_channel *channel = &wbuart->channel;

	channel->open_count--;

	if (channel->open_count == 0)
		tty_port_close(&channel->tty_port, tty, file);
}

static int wbu_tty_write(struct tty_struct *tty, const unsigned char *buf, int count)
{
	int buf_pos = 0;
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);
	struct wbu_channel *channel = &wbuart->channel;
	unsigned long flags;

	spin_lock_irqsave(&channel->lock, flags);

	while (count > 0 && channel->nb_bytes < PAGE_SIZE) {
		channel->tty_port.xmit_buf[channel->ptr_write] = buf[buf_pos++];
		channel->ptr_write = (channel->ptr_write + 1) % PAGE_SIZE;
		channel->nb_bytes++;
		count--;
	}

	spin_unlock_irqrestore(&channel->lock, flags);

	if (channel->nb_bytes > 0)
		wbu_enable_tx_interrupts(wbuart);

	return buf_pos;
}

#if KERNEL_VERSION(5, 14, 0) <= LINUX_VERSION_CODE
static unsigned int wbu_tty_write_room(struct tty_struct *tty)
#else
static int wbu_tty_write_room(struct tty_struct *tty)
#endif
{
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);
	struct wbu_channel *channel = &wbuart->channel;

	return (PAGE_SIZE - channel->nb_bytes);
}

#if KERNEL_VERSION(5, 14, 0) <= LINUX_VERSION_CODE
static unsigned int wbu_tty_chars_in_buffer(struct tty_struct *tty)
#else
static int wbu_tty_chars_in_buffer(struct tty_struct *tty)
#endif
{
	struct wbu_desc *wbuart = dev_get_drvdata(tty->dev->parent);
	struct wbu_channel *channel = &wbuart->channel;

	return channel->nb_bytes;
}

const struct tty_operations wbu_tty_ops = {
	.open = wbu_tty_open,
	.close = wbu_tty_close,
	.write = wbu_tty_write,
	.write_room = wbu_tty_write_room,
	.chars_in_buffer = wbu_tty_chars_in_buffer
};

static int wbu_tty_driver_init(struct tty_driver *tty_driver,
			       struct wb_uart_platform_data *wbu_pd)
{
	tty_driver->owner = THIS_MODULE;
	tty_driver->driver_name = kasprintf(GFP_KERNEL, "wbu-%s-tty",
					    wbu_pd->wb_uart_name);
	tty_driver->name = kasprintf(GFP_KERNEL, "ttywbu-%s-",
				     wbu_pd->wb_uart_name);

	if (!tty_driver->driver_name || !tty_driver->name)
		return -ENOMEM;

	tty_driver->type = TTY_DRIVER_TYPE_SERIAL;
	tty_driver->subtype = SERIAL_TYPE_NORMAL;
	tty_driver->flags = TTY_DRIVER_REAL_RAW |
			    TTY_DRIVER_DYNAMIC_DEV |
			    TTY_DRIVER_RESET_TERMIOS;

	tty_driver->init_termios = tty_std_termios;
	tty_driver->init_termios.c_iflag = IGNBRK | IGNPAR | IXANY;
	tty_driver->init_termios.c_oflag = 0;
	tty_driver->init_termios.c_cflag = CS8 | CREAD | CLOCAL;
	tty_driver->init_termios.c_lflag = 0;
	tty_set_operations(tty_driver, &wbu_tty_ops);

	return 0;
}

static int wbu_probe(struct platform_device *pdev)
{
	int err = 0;
	struct wbu_desc *wbuart;
	struct tty_driver *tty_driver;
	struct resource *r;
	struct wb_uart_platform_data *wbu_pd;

	if (pdev->dev.platform_data != NULL)
		wbu_pd = (struct wb_uart_platform_data *) pdev->dev.platform_data;
	else
		return -ENXIO;

	wbuart = devm_kzalloc(&pdev->dev, sizeof(struct wbu_desc), GFP_KERNEL);
	if (!wbuart)
		return -ENOMEM;

	platform_set_drvdata(pdev, wbuart);

	r = platform_get_resource(pdev, IORESOURCE_MEM, wbu_MEM_BASE);
	if (!r) {
		dev_err(&pdev->dev,
			"wb uart need base address\n");
		return -ENXIO;
	}
	wbuart->base_addr = devm_ioremap_resource(&pdev->dev, r);

	wbu_memops_detect(pdev);

	err = wbu_check_type(wbuart);
	if (err < 0) {
		dev_err(&(pdev->dev),
			"wb uart driver supports only physical uart\n");
		return err;
	}

	tty_driver = tty_alloc_driver(1, 0);
	if (IS_ERR(tty_driver))
		return PTR_ERR(tty_driver);

	err = wbu_tty_driver_init(tty_driver, wbu_pd);
	if (err < 0)
		goto err_tty;

	err = tty_register_driver(tty_driver);
	if (err < 0)
		goto err_tty;

	wbuart->tty_driver = tty_driver;

	err = wbu_tty_port_init(pdev);
	if (err < 0)
		goto err_port;

	r = platform_get_resource(pdev, IORESOURCE_IRQ, wbu_IRQ);
	if (!r) {
		dev_err(&(pdev->dev),
			"disable console: invalid interrupt source\n");
		err = -ENXIO;
		goto err_irq;
	}

	err = request_any_context_irq(r->start, wbu_tty_handler, 0,
				      r->name, wbuart);
	if (err < 0) {
		dev_err(&(pdev->dev),
			"Cannot request IRQ %lld\n",
			r->start);
		goto err_irq;
	}

	dev_info(&pdev->dev, "%s: tty name: %s\n",
		 __func__, tty_driver->name);

	return 0;
err_irq:
err_port:
	wbu_tty_port_exit(pdev);
	tty_unregister_driver(tty_driver);
err_tty:
	kfree(tty_driver->driver_name);
	kfree(tty_driver->name);
	tty_driver_kref_put(tty_driver);
	return err;
}

static int wbu_remove(struct platform_device *pdev)
{
	struct wbu_desc *wbuart = platform_get_drvdata(pdev);

	if (!wbuart->tty_driver)
		return 0;

	free_irq(platform_get_irq(pdev, wbu_IRQ), wbuart);
	wbu_tty_port_exit(pdev);

	tty_unregister_driver(wbuart->tty_driver);

	kfree(wbuart->tty_driver->driver_name);
	kfree(wbuart->tty_driver->name);
	tty_driver_kref_put(wbuart->tty_driver);

	return 0;
}

static const struct platform_device_id wbu_id_table[] = {
	{
		.name = "wb-uart",
	},
	{ .name = "" }, /* last */
};

static struct platform_driver wbu_driver = {
	.driver = {
		.name = "wb-uart",
		.owner = THIS_MODULE,
	},
	.id_table = wbu_id_table,
	.probe = wbu_probe,
	.remove = wbu_remove,
};

module_platform_driver(wbu_driver);

MODULE_AUTHOR("Piotr Klasa <piotr.klasa@cern.ch>");
MODULE_DESCRIPTION("Wishbone Simple UART CERN Linux Driver");
MODULE_LICENSE("GPL");
MODULE_VERSION(GIT_VERSION);
MODULE_DEVICE_TABLE(platform, wbu_id_table);
