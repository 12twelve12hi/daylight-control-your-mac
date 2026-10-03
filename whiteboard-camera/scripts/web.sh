#!/usr/bin/env bash
# make web: install, typecheck and build the web whiteboard into web/dist.
set -euo pipefail
cd "$(dirname "$0")/../web"
[[ "${CI:-}" == "true" ]] && set -x
npm ci --no-audit --no-fund
npm run typecheck
npm run build
ls -la dist
