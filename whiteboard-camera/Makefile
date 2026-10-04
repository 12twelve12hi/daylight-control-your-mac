# Daylight Whiteboard Camera: every CI step is one of these targets so both workflows stay thin.
# Scripts live in scripts/ (bash, set -euo pipefail). Run `make help` for the list.
SHELL := /bin/bash
# LOOSE_ENDS H1 (8): `make fetch-tools mac-generate mac-debug DAYLIGHT_BUNDLE_ADB=0` builds without the bundled adb.
DAYLIGHT_BUNDLE_ADB ?= 1
export DAYLIGHT_BUNDLE_ADB
.DEFAULT_GOAL := help

.PHONY: help web web-test android android-emulator-build android-emulator kit-test mac-generate mac-debug mac-test mac-smoke mac-release fetch-tools embed-apk ci ci-linux ci-mac golden golden-check scripts-check doctor clean

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

web: ## npm ci + typecheck + vite build (web/dist)
	scripts/web.sh

web-test: ## unit tests (node --test) + Playwright smoke test against the built dist
	scripts/web-test.sh

android: ## ./gradlew assembleDebug testDebugUnitTest (needs an Android SDK; CI ubuntu runner has one)
	scripts/android.sh

android-emulator-build: ## assemble the debug APK and the instrumented-test APK (run before the emulator boots; needs an Android SDK)
	scripts/android-emulator.sh build

android-emulator: ## instrumented tests on a booted Android 13 emulator shaped like the DC-1; screenshots, logcat, ANR traces in build/android-emulator (docs/SCREENSHOTS.md; CI job android-emulator, not part of ci-linux)
	scripts/android-emulator.sh run

kit-test: ## swift test in mac/DaylightKit (Linux or macOS)
	scripts/kit-test.sh

mac-generate: ## xcodegen generate mac/Daylight.xcodeproj (macOS)
	scripts/mac-generate.sh

mac-debug: ## xcodebuild build, CODE_SIGNING_ALLOWED=NO, web dist copied into Resources (macOS)
	scripts/mac-debug.sh

mac-test: ## xcodebuild test, scheme DaylightTests (macOS-only XCTest bundle hosted by Daylight.app), CODE_SIGNING_ALLOWED=NO (macOS)
	scripts/mac-test.sh

mac-smoke: ## run the Release Daylight binary with --self-test --perf-log under a 120 s timeout (macOS, after mac-debug; SPEC 16 B1)
	scripts/mac-smoke.sh

mac-release: ## CI target: archive + export signed with Developer ID, notarize on request; exits 0 without secrets, 1 on a partial set (macOS, needs the eight secrets in the env)
	scripts/mac-release.sh

fetch-tools: ## download pinned adb platform-tools + scrcpy-server with sha256 check into mac/Daylight/Resources/Vendor (CI/mac only)
	scripts/fetch-tools.sh

embed-apk: ## copy the Daylight Ink debug APK (android job artifact) into mac/Daylight/Resources/Apk; warns when absent
	scripts/embed-apk.sh android/app/build/outputs/apk/debug mac/Daylight/Resources/Apk/DaylightInk.apk

golden: ## regenerate protocol/golden/solstream-v1.json and copy it into the three test trees
	scripts/golden.sh

golden-check: ## regenerate to a temp file and diff all four copies
	scripts/check-golden.sh

scripts-check: ## bash tests for the script gates (mac-release secrets gate, ci-env DEVELOPER_DIR, license text, kit-test crash retry); runs on Linux
	scripts/scripts-check.sh

doctor: ## print which tools exist here and which targets can run
	scripts/ci-env.sh

ci-linux: golden-check scripts-check web web-test kit-test android ## what the Linux jobs run

ci-mac: fetch-tools embed-apk web mac-generate kit-test mac-debug mac-test mac-smoke mac-release ## what the macOS job runs

ci: ci-linux ## alias used by CI on Linux; the mac job calls ci-mac

clean: ## remove build outputs
	rm -rf web/dist web/node_modules web/build web/test-results web/playwright-report android/build android/app/build android/.gradle mac/DaylightKit/.build mac/Daylight.xcodeproj build mac/Daylight/Resources/web mac/Daylight/Resources/Vendor mac/Daylight/Resources/Apk
