SHELLCHECK ?= shellcheck

.PHONY: all test lint status install reinstall uninstall help clean ci

all: test

ci: lint test

lint:
	@bash -n speakers.sh && echo "  OK  bash -n speakers.sh"
	@bash -n scripts/cs35l41-helper.sh && echo "  OK  bash -n scripts/cs35l41-helper.sh"
	@bash -n tests/helper-selftest.sh && echo "  OK  bash -n tests/helper-selftest.sh"
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { echo "ERROR: shellcheck not found on PATH"; exit 1; }
	@$(SHELLCHECK) speakers.sh scripts/cs35l41-helper.sh tests/helper-selftest.sh && echo "  OK  shellcheck (all files)"

test: lint
	@bash tests/helper-selftest.sh

status:
	@bash speakers.sh --status

install:
	sudo bash speakers.sh

reinstall:
	sudo bash speakers.sh --reinstall

uninstall:
	sudo bash speakers.sh --uninstall

help:
	@bash speakers.sh --help

clean:
	rm -rf .selftest/ *.bak *.old* *.tmp
