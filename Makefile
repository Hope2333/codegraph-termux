# CodeGraph for Termux - local build orchestrator
# Ported from opencode-termux's build system.
#
# PKG defaults to both (deb + pacman), matching upstream opencode-termux.
# On a Termux-Pacman machine the package of choice is pacman: install the
# generated .pkg.tar.xz with `pacman -U`; the deb is optional (dpkg Termux).
#
# This machine is a Termux-Pacman system: pacman is the package manager,
# so PKG defaults to pacman (.pkg.tar.zst/xz, per makepkg.conf). The deb target stays available
# for dpkg-based Termux.

SHELL := /data/data/com.termux/files/usr/bin/bash
.DEFAULT_GOAL := help

VER ?= latest
VERS ?=
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
MORE ?=
ODIR ?=
MIX ?= 0

# Release upload target variables
TAG ?= Push$(shell date +%y%m%d)
REPO ?= Hope2333/codegraph-termux

OUTPUT_ROOT := $(if $(ODIR),$(ODIR),$(CURDIR)/packing)

.PHONY: help all runtime stage deb pacman batch clean status test release-upload

help:
	@echo "CodeGraph Termux build helper"
	@echo
	@echo "Scope:"
	@echo "  - Local Termux packaging workflow (pacman primary, deb optional)"
	@echo "  - Build pipeline: produce (download+patch) -> stage -> package"
	@echo
	@echo "Primary commands:"
	@echo "  make all VER=1.5.0 PKG=pacman"
	@echo "  make all VER=1.5.0                 # default PKG=both (deb + pacman)"
	@echo "  make all VER=latest PKG=pacman"
	@echo "  make all VER=1.5.0 PKG=pacman ODIR=~/cg-out"
	@echo "  make all VER=1.5.0 PKG=both ODIR=~/cg-out MIX=1"
	@echo "  make runtime VER=latest"
	@echo "  make stage"
	@echo "  make pacman"
	@echo "  make deb"
	@echo
	@echo "Batch commands:"
	@echo "  make batch VERS='1.5.0 1.5.1' PKG=pacman"
	@echo "  make batch VERS='1.5.[0-9]' PKG=pacman ODIR=~/cg-out"
	@echo "  make batch VERS='1.5.[0-9]' PKG=both ODIR=~/cg-out MIX=1"
	@echo
	@echo "Version resolution in tools/produce-local.sh:"
	@echo "  1) explicit version argument"
	@echo "  2) latest GitHub release if omitted (releases/latest redirect)"
	@echo "  3) CODEGRAPH_TARBALL=/path/to/codegraph-linux-arm64.tar.gz for offline builds"
	@echo
	@echo "Install the result with pacman:"
	@echo "  pacman -U packing/pacman/codegraph-<ver>-1-aarch64.pkg.tar.*"
	@echo
	@echo "Output policy:"
	@echo "  - Default root: ./packing"
	@echo "  - With ODIR: write to ODIR only (do not use ./packing)"
	@echo "  - Default layout: pacman/ (and deb/ if built) subfolders"
	@echo "  - MIX=1: flatten all artifacts into one directory"
	@echo
	@echo "Debug/introspection:"
	@echo "  make status"
	@echo "  make test"

all: clean runtime stage
	@V="$(VER)"; \
	if [ "$$V" = "latest" ]; then V=""; fi; \
	if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb VERSION=$$V PKG=deb MIX='$(MIX)' ODIR='$(ODIR)'; \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman VERSION=$$V PKG=pacman MIX='$(MIX)' ODIR='$(ODIR)'; \
	else \
		$(MAKE) pacman VERSION=$$V PKG=pacman MIX='$(MIX)' ODIR='$(ODIR)' && $(MAKE) deb VERSION=$$V PKG=deb MIX='$(MIX)' ODIR='$(ODIR)'; \
	fi

batch:
	@if [ -z "$(VERS)" ]; then \
		echo "Error: VERS is empty. Example: make batch VERS='1.5.0 1.5.1' PKG=pacman"; \
		exit 1; \
	fi
	@expanded=(); \
	for token in $(VERS); do \
		if [[ "$$token" =~ ^([0-9]+\.[0-9]+)\.\[([0-9]+)-([0-9]+)\]$$ ]]; then \
			base="$${BASH_REMATCH[1]}"; start="$${BASH_REMATCH[2]}"; end="$${BASH_REMATCH[3]}"; \
			for ((i=start; i<=end; i++)); do expanded+=("$$base.$$i"); done; \
		else \
			expanded+=("$$token"); \
		fi; \
	done; \
	for v in "$${expanded[@]}"; do \
		echo "=== Batch build for version $$v ==="; \
		$(MAKE) all VER=$$v PKG=$(PKG) MORE="$(MORE)" PACKAGER_NAME='$(PACKAGER_NAME)' ODIR='$(ODIR)' MIX='$(MIX)' || exit 1; \
	done

runtime:
	@if [ "$(VER)" = "latest" ]; then \
		./tools/produce-local.sh $(MORE); \
	else \
		./tools/produce-local.sh $(VER) $(MORE); \
	fi

stage:
	./scripts/build.sh

pacman:
	rm -rf packaging/pacman/pkg packaging/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' VERSION='$(VERSION)' ./scripts/package/package_pacman.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packaging/pacman/codegraph-*.pkg.* "$(OUTPUT_ROOT)/"; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/pacman" && cp -f packaging/pacman/codegraph-*.pkg.* "$(OUTPUT_ROOT)/pacman/"; \
	fi

deb:
	rm -rf packaging/dpkg/work
	MAINTAINER='$(PACKAGER_NAME)' VERSION='$(VERSION)' ./scripts/package/package_deb.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packaging/dpkg/codegraph_*.deb "$(OUTPUT_ROOT)/"; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/deb" && cp -f packaging/dpkg/codegraph_*.deb "$(OUTPUT_ROOT)/deb/"; \
	fi

status:
	@echo "Staged runtime:"; \
	if [ -x artifacts/staged/prefix/bin/codegraph ]; then \
		artifacts/staged/prefix/bin/codegraph --version; \
	else \
		echo "<missing — run: make stage>"; \
	fi

test:
	bash scripts/test.sh

clean:
	rm -rf artifacts/staged packaging/dpkg/work packaging/pacman/pkg packaging/pacman/src
	@echo "Clean complete"

# ── Release upload (not shown in help) ──────────────────────────────────
# Automates: batch build → upload all assets to existing or new release tag.
# Usage:
#   make release-upload TAG=Push260801 VERS='1.5.[0-9]'
#   make release-upload TAG=Push260801 VERS='1.5.[0-9]' PKG=deb
#   make release-upload VERS='1.5.[0-9]' REPO=Hope2333/codegraph-termux
#
# Defaults:
#   TAG     = Push<YYMMDD> (auto-generated)
#   VERS    = (required)
#   PKG     = pacman
#   REPO    = Hope2333/codegraph-termux
release-upload:
	@if [ -z "$(VERS)" ]; then \
		echo "Error: VERS is required. Example: make release-upload VERS='1.5.[0-9]' TAG=Push260801"; \
		exit 1; \
	fi
	@echo "=== Release upload: TAG=$(TAG) VERS=$(VERS) PKG=$(PKG) REPO=$(REPO) ==="
	$(MAKE) batch VERS='$(VERS)' PKG='$(PKG)' ODIR='/tmp/cg-release-$(TAG)' MIX=1
	@echo "=== Uploading to release $(TAG) ==="; \
	upload_failed=0; \
	if ! gh release view "$(TAG)" --repo "$(REPO)" >/dev/null 2>&1; then \
		echo "Creating release $(TAG)..."; \
		gh release create "$(TAG)" --repo "$(REPO)" --title "$(TAG)" --notes "Automated build $$(date -u +%Y-%m-%d)" 2>&1 || exit 1; \
	fi; \
	for f in /tmp/cg-release-$(TAG)/codegraph_*.deb /tmp/cg-release-$(TAG)/codegraph-*.pkg.*; do \
		if [ -f "$$f" ]; then \
			echo "  uploading $$(basename $$f)..."; \
			if ! gh release upload "$(TAG)" "$$f" --repo "$(REPO)" --clobber 2>&1; then upload_failed=1; fi; \
		fi; \
	done; \
	if [ "$$upload_failed" -ne 0 ]; then echo "Error: one or more release assets failed to upload" >&2; exit 1; fi; \
	echo "=== Done: https://github.com/$(REPO)/releases/tag/$(TAG) ==="
