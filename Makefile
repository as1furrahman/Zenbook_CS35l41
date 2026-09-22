SHELLCHECK ?= shellcheck

.PHONY: all test lint status install reinstall uninstall help clean ci

all: test

ci: lint test

lint:
	@bash -n speakers.sh && echo "  OK  bash -n speakers.sh"
	@bash -n scripts/cs35l41-helper.sh && echo "  OK  bash -n scripts/cs35l41-helper.sh"
	@bash -n tests/helper-selftest.sh && echo "  OK  bash -n tests/helper-selftest.sh"
	@if command -v $(SHELLCHECK) >/dev/null 2>&1; then \
		$(SHELLCHECK) speakers.sh && echo "  OK  shellcheck speakers.sh"; \
		$(SHELLCHECK) scripts/cs35l41-helper.sh && echo "  OK  shellcheck scripts/cs35l41-helper.sh"; \
		$(SHELLCHECK) tests/helper-selftest.sh && echo "  OK  shellcheck tests/helper-selftest.sh"; \
	else \
		echo "  WARN shellcheck not found, skipping static analysis"; \
	fi

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

clean:
	rm -rf .selftest/ *.bak *.old* *.tmp
