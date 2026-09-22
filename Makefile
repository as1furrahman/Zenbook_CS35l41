.PHONY: all test lint status install reinstall uninstall help

all: test

lint:
	@bash -n speakers.sh && echo "  OK  speakers.sh"
	@bash -n tests/helper-selftest.sh && echo "  OK  tests/helper-selftest.sh"

test: lint
	@bash tests/helper-selftest.sh

status:
	@bash speakers.sh --status

install: lint
	sudo bash speakers.sh

reinstall: lint
	sudo bash speakers.sh --reinstall

uninstall:
	sudo bash speakers.sh --uninstall

help:
	@bash speakers.sh --help
