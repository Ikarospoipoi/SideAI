#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d build/SideAI.app ]]; then ./scripts/build.sh; fi
open build/SideAI.app
