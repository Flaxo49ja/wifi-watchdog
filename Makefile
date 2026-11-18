PREFIX ?= $(HOME)/.local

.PHONY: check install uninstall help

help:
	@echo "make check      run the hardware-free test suite"
	@echo "make install    install and enable the systemd user service"
	@echo "make uninstall  remove files, keep the config"

check:
	@bash tests/smoke.sh

install:
	@./install.sh

uninstall:
	@./uninstall.sh
