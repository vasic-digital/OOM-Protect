# Makefile — oom-toolkit
#
# Convenience targets that wrap oom-hardening.sh, oom-runner.sh, build-docs.sh,
# and verify.sh. All commands are idempotent and safe to re-run. Targets that
# need root call sudo themselves; everything else runs as your user.
#
# Quick start:
#   make help         show this list
#   make dry-run      preview hardening, change nothing
#   make install      apply hardening (calls sudo)
#   make docs         rebuild all HTML + PDF outputs
#   make verify       run a comprehensive health check
#   make test         brief functional test of oom-runner

SHELL := /bin/bash
ROOT  := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))

HARDEN  := $(ROOT)/oom-hardening.sh
RUNNER  := $(ROOT)/oom-runner.sh
BUILD   := $(ROOT)/build-docs.sh
VERIFY  := $(ROOT)/verify.sh

# Discover all .md files dynamically (top-level + manuals/ + reports/) so the
# pipeline still works after the user reorganises the directory.
MARKDOWN := $(wildcard $(ROOT)/*.md $(ROOT)/manuals/*.md $(ROOT)/reports/*.md)

HTML := $(MARKDOWN:.md=.html)
PDF  := $(MARKDOWN:.md=.pdf)

# Colors (only when stdout is a TTY)
ifneq ($(strip $(MAKE_TERMOUT)),)
    G := \033[32m
    Y := \033[33m
    R := \033[31m
    B := \033[1m
    C := \033[0m
endif

.DEFAULT_GOAL := help
.PHONY: help install dry-run uninstall rollback verify verify-stress \
        docs docs-clean test list status logs kill clean-units \
        presets package clean all check

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
help:
	@printf "$(B)oom-toolkit — make targets$(C)\n\n"
	@printf "  $(B)Apply / verify$(C)\n"
	@printf "    make dry-run        Preview hardening (no changes, no root)\n"
	@printf "    make install        Apply hardening (sudo)\n"
	@printf "    make verify         Run health checks (no root)\n"
	@printf "    make verify-stress  Verify + 16G stress test\n"
	@printf "    make uninstall      Remove drop-ins this script wrote (sudo)\n"
	@printf "    make rollback BACKUP=DIR   Rollback from a backup dir (sudo)\n"
	@printf "\n"
	@printf "  $(B)Documentation$(C)\n"
	@printf "    make docs           Rebuild all HTML + PDF\n"
	@printf "    make docs-clean     Delete all generated HTML + PDF\n"
	@printf "\n"
	@printf "  $(B)Runner control$(C)\n"
	@printf "    make presets        List oom-runner presets\n"
	@printf "    make list           List active oom-runner units\n"
	@printf "    make status UNIT=x  Show one unit's status (live mem usage)\n"
	@printf "    make logs UNIT=x    Tail one unit's journal\n"
	@printf "    make kill UNIT=x    Stop one unit\n"
	@printf "    make clean-units    Stop ALL oom-runner units\n"
	@printf "\n"
	@printf "  $(B)Project$(C)\n"
	@printf "    make test           Quick functional test (no sudo)\n"
	@printf "    make package        Bundle as oom-toolkit.tar.gz\n"
	@printf "    make all            docs + verify (typical CI)\n"
	@printf "    make check          Lint shell scripts\n"
	@printf "    make clean          Remove generated files (HTML, PDF, tarball)\n"

# -----------------------------------------------------------------------------
# Apply / verify
# -----------------------------------------------------------------------------
dry-run:
	@bash "$(HARDEN)" --dry-run

install:
	@printf "$(B)Applying hardening (will prompt for sudo and confirmation).$(C)\n"
	@sudo bash "$(HARDEN)"

uninstall:
	@sudo bash "$(HARDEN)" --uninstall

rollback:
	@if [ -z "$(BACKUP)" ]; then \
	    echo "Usage: make rollback BACKUP=/root/oom-hardening-backup-YYYYMMDD-HHMMSS"; \
	    exit 1; \
	fi
	@sudo bash "$(HARDEN)" --rollback "$(BACKUP)"

verify:
	@bash "$(VERIFY)"

verify-stress:
	@bash "$(VERIFY)" --stress

# -----------------------------------------------------------------------------
# Documentation
# -----------------------------------------------------------------------------
docs: $(HTML) $(PDF)
	@printf "$(G)docs built: %d HTML, %d PDF$(C)\n" \
	    $(words $(HTML)) $(words $(PDF))

%.html %.pdf: %.md $(ROOT)/assets/style.css $(BUILD)
	@bash "$(BUILD)"

docs-clean:
	@rm -f $(HTML) $(PDF)
	@printf "$(G)docs cleaned$(C)\n"

# -----------------------------------------------------------------------------
# Runner control (proxies to oom-runner.sh subcommands)
# -----------------------------------------------------------------------------
presets:
	@bash "$(RUNNER)" presets

list:
	@bash "$(RUNNER)" list

status:
	@if [ -z "$(UNIT)" ]; then echo "Usage: make status UNIT=<name>"; exit 1; fi
	@bash "$(RUNNER)" status "$(UNIT)"

logs:
	@if [ -z "$(UNIT)" ]; then echo "Usage: make logs UNIT=<name>"; exit 1; fi
	@bash "$(RUNNER)" logs "$(UNIT)" -f

kill:
	@if [ -z "$(UNIT)" ]; then echo "Usage: make kill UNIT=<name>"; exit 1; fi
	@bash "$(RUNNER)" kill "$(UNIT)"

clean-units:
	@bash "$(RUNNER)" clean

# -----------------------------------------------------------------------------
# Project quality
# -----------------------------------------------------------------------------
test:
	@printf "$(B)Functional test: $(RUNNER)$(C)\n"
	@bash "$(RUNNER)" --no-inherit-env -m 256M --no-pty -- /bin/echo "OK from inside scope"
	@printf "\n$(B)Functional test: $(BUILD)$(C)\n"
	@bash "$(BUILD)" >/dev/null && echo "  docs build: OK"
	@printf "\n$(G)tests passed$(C)\n"

check:
	@printf "Linting shell scripts...\n"
	@for f in $(HARDEN) $(RUNNER) $(BUILD) $(VERIFY); do \
	    bash -n "$$f" && printf "  $(G)bash -n$(C) $$(basename $$f)\n"; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
	    for f in $(HARDEN) $(RUNNER) $(BUILD) $(VERIFY); do \
	        shellcheck -S warning "$$f" || true; \
	    done; \
	else \
	    printf "  (install shellcheck for deeper linting)\n"; \
	fi

# Bundle current state into a single tarball, excluding generated outputs.
package: docs
	@TS=$$(date +%Y%m%d-%H%M%S); \
	OUT="$(ROOT)/oom-toolkit-$${TS}.tar.gz"; \
	tar -czf "$${OUT}" \
	    -C "$(ROOT)" \
	    Makefile README.md README.html README.pdf \
	    Crash_Report.md Crash_Report.html Crash_Report.pdf \
	    oom-hardening.sh oom-runner.sh build-docs.sh verify.sh \
	    assets manuals \
	    2>/dev/null; \
	printf "$(G)packaged:$(C) %s\n" "$${OUT}"; \
	ls -lh "$${OUT}"

all: docs verify

clean: docs-clean
	@rm -f $(ROOT)/oom-toolkit-*.tar.gz
	@printf "$(G)clean$(C)\n"
