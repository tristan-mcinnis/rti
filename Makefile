# One entry point for agents and humans. Each target wraps the commands in
# CLAUDE.md and scripts/. Warnings are errors (RTI/project.yml sets
# SWIFT_TREAT_WARNINGS_AS_ERRORS for every target), so `build` is the strict check.

# macOS ships GNU make 3.81 (no .SHELLFLAGS), so each pipe sets pipefail itself.
SHELL := /bin/bash

PROJECT := RTI/RTI.xcodeproj
SCHEME := RTI
DERIVED := .deriveddata
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	-destination 'platform=macOS' -derivedDataPath $(DERIVED)

# Quiet, agent-readable output when xcbeautify exists; raw output otherwise.
XCBEAUTIFY := $(shell command -v xcbeautify 2>/dev/null || ls /opt/homebrew/bin/xcbeautify 2>/dev/null)
ifeq ($(XCBEAUTIFY),)
PRETTY := cat
else
PRETTY := $(XCBEAUTIFY) --quiet
endif

.PHONY: build check test test-render generate scrub install

generate:
	cd RTI && xcodegen generate >/dev/null

build: generate
	set -o pipefail; $(XCODEBUILD) build 2>&1 | $(PRETTY)

# Strict compile of every target, test bundles included, without running tests.
check: generate
	set -o pipefail; $(XCODEBUILD) build-for-testing 2>&1 | $(PRETTY)

scrub:
	scripts/scrub.sh

# Unit tests (CLAUDE.md: scrub first, then RTITests).
test: scrub generate
	set -o pipefail; $(XCODEBUILD) test -only-testing:RTITests 2>&1 | $(PRETTY)

# Offscreen render proofs (PNGs land in /tmp/rti-render-proof/).
test-render: generate
	set -o pipefail; $(XCODEBUILD) test -only-testing:RTIRenderTests 2>&1 | $(PRETTY)

# Release build, stable signing, replace /Applications/RTI.app.
install:
	scripts/install-local.sh
