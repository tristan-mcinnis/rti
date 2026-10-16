#!/bin/bash
# check-layout.sh — fail early, with a clear message, if the sibling
# house-chat-core checkout is missing.
#
# RTI builds HouseChatCore from ../house-chat-core
# (RTI/project.yml, path anchored at RTI/, so two levels up from RTI/).
# Without that sibling clone, Xcode only says the package "cannot be
# accessed", which does not tell you what to do.
#
# Required layout (the folder names matter, the parent folder does not):
#
#   <parent>/rti/              this repo
#   <parent>/house-chat-core/  github.com/tristan-mcinnis/house-chat-core
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$REPO_ROOT/../house-chat-core/Package.swift"

if [ ! -f "$PACKAGE" ]; then
  cat >&2 <<MSG
error: HouseChatCore not found.
  expected: $(cd "$REPO_ROOT/.." && pwd)/house-chat-core/Package.swift

RTI builds the shared HouseChatCore package from a sibling clone of house-chat-core.
Clone both repos side by side:

  <parent>/rti/
  <parent>/house-chat-core/

  git clone https://github.com/tristan-mcinnis/house-chat-core.git "$(cd "$REPO_ROOT/.." && pwd)/house-chat-core"

See README.md, Requirements.
MSG
  exit 1
fi
