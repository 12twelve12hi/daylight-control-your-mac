# Daylight Whiteboard Camera: every CI step is one of these targets so both workflows stay thin.
# Scripts live in scripts/ (bash, set -euo pipefail). Run `make help` for the list.
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help web web-test android kit-test mac-generate mac-debug mac-test mac-smoke mac-release fetch-tools embed-apk ci ci-linux ci-mac golden golden-check doctor clean

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

web: ## npm ci + typecheck + vite build (web/dist)
	scripts/web.sh

web-test: ## unit tests (node --test) + Playwright smoke test against the built dist
	scripts/web-test.sh

android: ## ./gradlew assembleDebug testDebugUnitTest (needs an Android SDK; CI ubuntu runner has one)
	scripts/android.sh

kit-test: ## swift test in mac/DaylightKit (Linux or macOS)
	scripts/kit-test.sh

mac-generate: ## xcodegen generate mac/Daylight.xcodeproj (macOS)
	scripts/mac-generate.sh

mac-debug: ## xcodebuild build, CODE_SIGNING_ALLOWED=NO, web dist copied into Resources (macOS)
	scripts/mac-debug.sh

mac-test: ## xcodebuild test, scheme DaylightTests (macOS-only XCTest bundle hosted by Daylight.app), CODE_SIGNING_ALLOWED=NO (macOS)
	scripts/mac-test.sh

mac-smoke: ## run the Release Daylight binary with --self-test --perf-log under a 120 s timeout (macOS, after mac-debug)
	scripts/mac-smoke.sh

mac-release: ## archive + export signed with Developer ID + notarize when the signing env is set; otherwise explains and exits 0 (macOS)
	scripts/mac-release.sh

fetch-tools: ## download pinned adb platform-tools + scrcpy-server with sha256 check into mac/Daylight/Resources/Vendor (CI/mac only)
	scripts/fetch-tools.sh

embed-apk: ## copy the Daylight Ink debug APK (android job artifact) into mac/Daylight/Resources/Apk; warns when absent
	scripts/embed-apk.sh android/app/build/outputs/apk/debug mac/Daylight/Resources/Apk/DaylightInk.apk

golden: ## regenerate protocol/golden/solstream-v1.json and copy it into the three test trees
	scripts/golden.sh

golden-check: ## regenerate to a temp file and diff all four copies
	scripts/check-golden.sh

doctor: ## print which tools exist here and which targets can run
	scripts/ci-env.sh

ci-linux: golden-check web web-test kit-test android ## what the Linux jobs run

ci-mac: fetch-tools embed-apk web mac-generate kit-test mac-debug mac-test mac-release ## what the macOS job runs (mac-smoke joins once --self-test exists)

ci: ci-linux ## alias used by CI on Linux; the mac job calls ci-mac

clean: ## remove build outputs
	rm -rf web/dist web/node_modules web/build web/test-results web/playwright-report android/build android/app/build android/.gradle mac/DaylightKit/.build mac/Daylight.xcodeproj build mac/Daylight/Resources/web mac/Daylight/Resources/Vendor mac/Daylight/Resources/Apk
