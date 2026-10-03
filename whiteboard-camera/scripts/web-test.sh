#!/usr/bin/env bash
# make web-test: protocol golden unit tests (node --test) and the Playwright smoke test.
# Uses the preinstalled Chromium when PLAYWRIGHT_BROWSERS_PATH points at one; otherwise installs it.
set -euo pipefail
cd "$(dirname "$0")/../web"
[[ "${CI:-}" == "true" ]] && set -x
[[ -d node_modules ]] || npm ci --no-audit --no-fund
[[ -d dist ]] || npm run build
npm run test:unit
if [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" && -d "${PLAYWRIGHT_BROWSERS_PATH}" ]] && ls "${PLAYWRIGHT_BROWSERS_PATH}" | grep -q '^chromium'; then
  echo "using preinstalled Chromium in ${PLAYWRIGHT_BROWSERS_PATH}"
else
  npx playwright install --with-deps chromium
fi
npx playwright test
