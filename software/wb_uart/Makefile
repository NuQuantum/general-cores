# SPDX-License-Identifier: CC0-1.0
#
# SPDX-FileCopyrightText: 2019 CERN

.PHONY: all clean modules install modules_install

DIR := drivers/

all: modules
install: modules_install

clean modules modules_install cppcheck flawfinder:
	@$(MAKE) -C $(DIR) $@
