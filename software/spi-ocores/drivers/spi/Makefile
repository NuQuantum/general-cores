# SPDX-License-Identifier: CC0-1.0
#
# Copyright (C) 2019 CERN

TOPDIR ?= $(shell pwd)/../../../../
GCORES ?= $(abspath $(TOPDIR))

#
# External variables and targets
#
-include Makefile.specific
-include $(REPO_PARENT)/parent_common.mk
include $(GCORES)/common.mk

#
# Local variables
#
KVERSION ?= $(shell uname -r)
KERNELSRC ?= /lib/modules/$(KVERSION)/build

#
# Local targets
#

all: modules
install: modules_install

clean coccicheck modules:
	$(MAKE) -C $(KERNELSRC) M=$(shell /bin/pwd) \
		GIT_VERSION=$(GIT_VERSION) \
		CONFIG_SPI_OCORES=m \
		$@
modules_install: modules
	$(MAKE) -C $(KERNELSRC) M=$(shell /bin/pwd) INSTALL_MOD_PATH=$(PREFIX) $@


.PHONY: all clean coccicheck modules modules_install install
