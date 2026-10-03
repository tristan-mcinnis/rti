#!/bin/bash
# check-layout.sh — fail early, with a clear message, if the sibling
# quick-launch checkout is missing.
#
# RTI builds HouseChatCore from ../quick-launch/Packages/HouseChatCore
# (RTI/project.yml, path anchored at RTI/, so two levels up from RTI/).
# Without that sibling clone, Xcode only says the package "cannot be
# accessed", which does not tell you what to do.
#
# Required layout (the folder names matter, the parent folder does not):
#
#   <parent>/rti/           this repo
#   <parent>/quick-launch/  github.com/tristan-mcinnis/quick-launch
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$REPO_ROOT/../quick-launch/Packages/HouseChatCore/Package.swift"

if [ ! -f "$PACKAGE" ]; then
  cat >&2 <<MSG
error: HouseChatCore not found.
  expected: $(cd "$REPO_ROOT/.." && pwd)/quick-launch/Packages/HouseChatCore/Package.swift

RTI builds the shared HouseChatCore package from a sibling clone of quick-launch.
Clone both repos side by side:

  <parent>/rti/
  <parent>/quick-launch/

  git clone https://github.com/tristan-mcinnis/quick-launch.git "$(cd "$REPO_ROOT/.." && pwd)/quick-launch"

See README.md, Requirements.
MSG
  exit 1
fi
