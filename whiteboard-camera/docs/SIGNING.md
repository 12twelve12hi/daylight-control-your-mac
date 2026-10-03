# Signing and notarization

macOS loads a camera extension only from an app signed with a Developer ID and notarized. Until the owner finishes this checklist, every CI build is the unsigned `Daylight-unsigned.zip`: menu bar, preview window, web page, Allow panel, saving and hotkeys work; "Daylight Camera" never appears in Zoom or FaceTime (failure row 2, SPEC 13.3).

Nothing here needs Xcode. The Mac side is Keychain Access, a browser and the `gh` command; GitHub Actions does the building, signing, notarizing and stapling (`scripts/mac-release.sh`, run by `make mac-release` in the `mac` job of `.github/workflows/whiteboard-camera.yml`).

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

## Before you start (5 min)

- A paid Apple Developer Program membership where you hold the Account Holder role (only the Account Holder can create Developer ID certificates; up to five Developer ID Application certificates per team).
- Any Mac with Keychain Access (ships with macOS). The private key is created on the Mac that makes the request, so make the request and the export on the same Mac.
- `gh` logged in to the build repository (`gh auth status`), and a clone of it so `gh secret set` targets the right repository (or pass `-R 12twelve12hi/daylight-control-your-mac`).
- A password manager open: you will store a `.p12` with its password, two `.provisionprofile` files, a `.p8` and two ids.

## Owner checklist (about 30 minutes, no Xcode needed)

1. Team ID: developer.apple.com/account > Membership details > copy the 10-character Team ID.
2. Certificate signing request: Keychain Access > menu Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Your email, Common Name "Daylight Developer ID", CA Email empty, "Saved to disk", Continue, save the `.certSigningRequest` file.
3. Developer ID certificate: Certificates, Identifiers & Profiles > Certificates > + > under Software choose Developer ID > Continue > pick the Application type (not Installer) > Choose File (your CSR) > Continue > Download the `.cer` > double-click it so it lands in Keychain Access under My Certificates.
4. Export the `.p12`: Keychain Access > login > My Certificates > "Developer ID Application: <you> (<TEAMID>)" (open the triangle: a private key must hang under it) > right-click > Export > format `.p12` > choose a strong password. Call the file `developerID.p12`.
5. App IDs: Identifiers > + > App IDs > App > Description "Daylight" > Explicit Bundle ID `com.twelve.daylight` > tick System Extension and App Groups > Continue > Register. Repeat for `com.twelve.daylight.camera` with App Groups ticked. Do not register a `group.` app group; the Team ID form (`<TEAMID>.com.twelve.daylight`) needs none.
6. Profiles: Profiles > + > Distribution: Developer ID > Continue > App ID `com.twelve.daylight` > Continue > select the Developer ID Application certificate > Continue > Name "Daylight Developer ID" > Generate > Download. Repeat for `com.twelve.daylight.camera` with the name "Daylight Camera Developer ID". The build reads each profile's Name from the decoded file and puts that into the export options, so the names are yours to choose; this page uses these two throughout. If you ever edit an App ID's capabilities, regenerate its profile (a profile with a modified App ID becomes invalid).
7. App Store Connect API key: appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API > Team Keys > + > name "Daylight CI notarization", role Developer (Admin if Developer is refused) > Generate > Download `AuthKey_<KEYID>.p8` (one chance) > note the Key ID and the Issuer ID shown on that page. Only Team Keys work for `notarytool`, not Individual keys.
8. Secrets, from the folder with the files (`base64 -i` is the macOS spelling):
   - `gh secret set DAYLIGHT_TEAM_ID --body <TEAMID>`
   - `gh secret set DAYLIGHT_DEVELOPER_ID_P12_BASE64 < <(base64 -i developerID.p12)`
   - `gh secret set DAYLIGHT_DEVELOPER_ID_P12_PASSWORD --body '<password>'`
   - `gh secret set DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Developer_ID.provisionprofile)`
   - `gh secret set DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Camera_Developer_ID.provisionprofile)`
   - `gh secret set ASC_API_KEY_ID --body <KEYID>`
   - `gh secret set ASC_API_ISSUER_ID --body <ISSUER>`
   - `gh secret set ASC_API_PRIVATE_KEY_BASE64 < <(base64 -i AuthKey_<KEYID>.p8)`
   `gh secret list` must then show all eight names. The names are spelled exactly as `scripts/mac-release.sh` reads them; a typo is caught by the gate (below) with the missing name in the step output.
9. Re-run the workflow (Actions > whiteboard-camera > Run workflow with "notarize" ticked, or push a `v*` tag such as `v0.1.0`). Download `Daylight-dmg`.
10. Keep the `.p12`, both profiles and the `.p8` in your password manager. Profiles last 18 years.

What macOS does with it: a Developer ID signed system extension loads only when notarized. The unsigned CI build is for compile checks and the preview window; it can never show "Daylight Camera" in Zoom.

## Which secret feeds what

| Secret | Holds | Used by |
|---|---|---|
| `DAYLIGHT_TEAM_ID` | the 10-character Team ID | `DEVELOPMENT_TEAM`, the export options `teamID`, the team check against the certificate and the profile |
| `DAYLIGHT_DEVELOPER_ID_P12_BASE64` | base64 of the exported `.p12` (certificate plus private key) | `security import` into a temporary keychain |
| `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD` | the export password | `security import -P` |
| `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64` | base64 of "Daylight Developer ID" | copied into both profile folders; its Name goes into `provisioningProfiles` for `com.twelve.daylight` |
| `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64` | base64 of "Daylight Camera Developer ID" (optional, recommended) | the same for `com.twelve.daylight.camera` |
| `ASC_API_KEY_ID` | the Key ID | `notarytool --key-id` |
| `ASC_API_ISSUER_ID` | the Issuer ID (a UUID) | `notarytool --issuer` |
| `ASC_API_PRIVATE_KEY_BASE64` | base64 of `AuthKey_<KEYID>.p8` | written to a temp file for `notarytool --key`, removed on exit |

## Three ways to start a build, and what each produces

| How | Signs | Notarizes | Artifacts | Use it for |
|---|---|---|---|---|
| any push to the branch, with the eight secrets set | yes | no | `Daylight-unsigned`, `Daylight-signed`, `release-logs` | checking that signing works; never install this build (its extension fails with row 9 on a Mac) |
| `gh workflow run whiteboard-camera.yml --ref claude/daylight-whiteboard-camera-tzxfjb -f notarize=true` (or Actions > Run workflow with "notarize" ticked) | yes | yes | plus `Daylight-dmg` | anything you install |
| `git tag v0.1.0 && git push origin v0.1.0` (any `v*` tag) | yes | yes | plus `Daylight-dmg` | the release build; `VERSION` says `0.1.0`, so `v0.1.0` is the first tag |

Watch with `gh run watch`, or `gh run list --workflow whiteboard-camera --limit 3`. Download with `gh run download <run id> -n Daylight-dmg`.

## What the mac job does with the secrets (`scripts/mac-release.sh`, `make mac-release`)

- Gate first, in seconds: with no `DAYLIGHT_*` or `ASC_*` secret at all the step prints what is missing and exits 0 (the unsigned run stays green). With a partial set, a misnamed name, a `v*` tag or a notarize dispatch without the three `ASC_*` secrets, or `DO_NOTARIZE=true` with an `ASC_*` missing, it exits 1 naming the gap: a green run with the wrong artifact is the worst outcome. `scripts/scripts-check.sh` (`make scripts-check`, in the golden job) proves the gate on Linux.
- Notarization happens only on a `v*` tag or when the workflow is dispatched with `notarize: true` (SPEC D22); a plain push with all eight secrets signs and exports but does not notarize, and the extension of that build fails with `OSSystemExtensionError 8` (row 9) on a Mac. Use the tag or the dispatch for anything you install.
- The team must agree across `DAYLIGHT_TEAM_ID`, the `(TEAMID)` suffix of the certificate and `TeamIdentifier.0` of the app profile (hard error); the app profile should allowlist `com.apple.developer.system-extension.install` and name `com.twelve.daylight` (warnings in `release-logs/profile-check.txt`).
- `DaylightBuildSigned` is written as false by `project.yml` and flipped to a Bool true with `plutil -replace` on the generated `mac/Daylight/Info.plist` right after `scripts/mac-generate.sh`; the exported app is asserted to carry true and `Contents/embedded.provisionprofile`, so a signed artifact can never behave like the unsigned build.
- The bundled `Vendor/adb` is signed by hand with the hardened runtime and a timestamp before the archive (notarization wants every executable signed).
- Notarization: `notarytool submit --wait --timeout 30m` on the DMG, the log fetched whenever a submission id exists, then the DMG is stapled, the exported app is stapled and `Daylight-signed.zip` is re-created from it. The app inside the DMG is not stapled: an online Mac validates it against the notary service on first launch; an offline first launch fails Gatekeeper (LOOSE_ENDS G8).
- Secrets never reach the log: no `set -x` by default (`RUNNER_DEBUG` enables it for the codesign and xcodebuild part only, and it is off around the `.p8` decode); the decoded `.p12`, `.p8`, profiles and plists are removed on exit, the temporary keychain is deleted, and a local run restores the keychain search list.

## What success looks like in the run log

Open the mac job, step "Signed and notarized build (skips itself without secrets)". In order:

1. `mac-release: signing secrets complete; notarize=true (DO_NOTARIZE=true, NOTARIZE_REQUESTED=true)` (on a plain push: `notarize=false`).
2. `mac-release: identity 'Developer ID Application: <you> (<TEAMID>)' (team <TEAMID>)`.
3. `mac-release: installed app profile 'Daylight Developer ID' (<uuid>)` and `mac-release: installed ext profile 'Daylight Camera Developer ID' (<uuid>)`.
4. `team: secret=<TEAMID> certificate=<TEAMID> app-profile=<TEAMID>`, `app profile Entitlements com.apple.developer.system-extension.install: true`, `app profile Entitlements com.apple.application-identifier: <TEAMID>.com.twelve.daylight (expected ...)`, no `WARNING` line.
5. `mac-release: mac/Daylight/Info.plist DaylightBuildSigned=true`.
6. `** ARCHIVE SUCCEEDED **` (about five minutes), then `** EXPORT SUCCEEDED **`.
7. `mac-release: exported Info.plist DaylightBuildSigned=true` and `mac-release: Contents/embedded.provisionprofile present`.
8. The `codesign -vvv --deep --strict` block ends with `valid on disk` and `satisfies its Designated Requirement`; `spctl` may still say rejected here (expected before notarization, the script says so).
9. `mac-release: notarytool submit exit 0` followed by the JSON with `"status": "Accepted"`, then the notarization log JSON with `"status": "Accepted"` and an empty `issues` list, then `stapler` reporting that the staple and validate action worked, for the DMG and for the app.
10. The artifacts `release-logs`, `Daylight-signed` and `Daylight-dmg` on the run page.

## Every failure and its remedy

Read the first `mac-release: ERROR` or `WARNING` line of the step; the `release-logs` artifact is uploaded even when the step fails.

| You see | Cause | Remedy |
|---|---|---|
| `mac-release: skipping the signed build. Missing: ...` and exit 0 | no secret at all is set | expected before step 8 of the checklist |
| `mac-release: ERROR: some signing secrets are set (or HAS_SIGNING=true) but these are missing or misnamed: ...` | a typo in a secret name, or one of the four required `DAYLIGHT_*` secrets missing | `gh secret list`; re-run the `gh secret set` line for the named secret with the exact spelling |
| `mac-release: ERROR: notarization was requested (tag or dispatch) but these are missing or misnamed: ...` | a tag or notarize run without one of the three `ASC_*` secrets | set the named `ASC_*` secret; re-run |
| `mac-release: ERROR: a partial ASC_* secret set; missing or misnamed: ...` | two of three `ASC_*` secrets | set the third one |
| `security: SecKeychainItemImport: MAC verification failed during PKCS12 import` (or `security import` exits 1) | wrong `DAYLIGHT_DEVELOPER_ID_P12_PASSWORD`, or the base64 was made from the wrong file | re-set the password secret; re-export the `.p12` and re-set the base64 |
| `mac-release: no 'Developer ID Application' identity in the imported .p12` | the `.p12` holds the certificate without its private key (exported from a Mac that did not make the CSR), or a Developer ID Installer certificate was created instead of Application | export again from Keychain Access > My Certificates on the Mac that made the request, with the triangle open and the key visible; make an Application certificate if you made an Installer one |
| `mac-release: ERROR: DAYLIGHT_TEAM_ID '...' is not the team of the certificate` | a typo in the Team ID, or a certificate from another team | copy the Team ID from Membership details again |
| `mac-release: ERROR: DAYLIGHT_TEAM_ID '...' is not the TeamIdentifier of the app profile` | the profile belongs to another team | regenerate the profile on the right team |
| `mac-release: WARNING: the app profile does not allowlist com.apple.developer.system-extension.install ...` then `archive failed` with `Provisioning profile "Daylight Developer ID" doesn't include the com.apple.developer.system-extension.install entitlement` in `archive.log` | System Extension was not ticked on the App ID `com.twelve.daylight` when the profile was generated (Xcode 16 refuses restricted entitlements the profile does not allowlist) | Identifiers > `com.twelve.daylight` > tick System Extension > Save; Profiles > regenerate "Daylight Developer ID" > Download; re-set `DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64`; re-run |
| `mac-release: WARNING: the app profile is not for com.twelve.daylight` | the two profiles were swapped between the two secrets | re-set both `..._PROVISIONING_PROFILE_BASE64` secrets with the right files |
| `archive.log`: `... doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement` | App Groups not ticked on the App ID | tick App Groups on both App IDs, regenerate both profiles, re-set, re-run |
| `archive.log`: `No signing certificate "Developer ID Application" found` or `No profiles for 'com.twelve.daylight.camera' were found` | the identity or the extension profile did not reach Xcode | check steps 2 and 3 of the success list; make sure the ext profile was generated for `com.twelve.daylight.camera` and that `DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64` holds that file |
| `archive.log`: `Cloud signing permission error` | automatic signing crept in | not expected: the project is manual signing; report it with `archive.log` |
| `mac-release: export produced no Daylight.app, see export.log` | `export.log` names the bundle id and profile that did not match | the profile names in the export options come from the decoded profiles, so this points at a profile generated for a different App ID; regenerate |
| `mac-release: ERROR: the exported app still carries DaylightBuildSigned=...` or `embedded.provisionprofile is missing` | a build-script regression | report it with `signed-flag.txt` and `export.log`; nothing on the Apple side |
| `notarytool submit exit 1` with `HTTP status code: 401` or `Unable to authenticate` in `notarytool-submit.err` | `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID` swapped, the `.p8` from another key, or the key revoked | the Key ID is 10 characters, the Issuer ID is a UUID; re-set; a revoked key means a new Team Key (the `.p8` downloads once) |
| `notarytool submit exit 1` with `HTTP status code: 403` | the key's role is too low for notarization | make a new Team Key with the Admin role |
| `"status": "Invalid"` in `notarytool-submit.json` | Apple rejected the binary; `notarization-log.json` lists the `issues` | `The executable does not have the hardened runtime enabled`, `The signature does not include a secure timestamp`, `The binary is not signed with a valid Developer ID certificate`: each names the file; report the log (the project builds with the hardened runtime, a timestamp and signs the bundled adb, so a new issue is a regression) |
| `"status": "In Progress"` after 30 minutes, exit non-zero | Apple's service is slow today | re-run the workflow later; nothing is wrong with the build |
| `stapler` exits 65 (`Could not validate ticket`) | the ticket was not yet published when stapling ran | re-run the workflow; the submission itself was accepted |
| On the Mac: "macOS refused the extension's signature. This build is not notarized." (row 9) | you installed the zip of a plain push | install `Daylight.dmg` from a tag or notarize run |
| On the Mac: "The camera extension is missing an entitlement (build signing problem)." (row 6) | the app profile lacks System Extension (the warning above was ignored) | as the System Extension row above |
| On the Mac: "The extension's service name does not match its app group (build configuration)." (row 10) | `CMIOExtensionMachServiceName` not under the app group | a `project.yml` regression; report it |
| On the Mac: "Move Daylight to your Applications folder, then open it from there." (row 1 or 7) | opened from Downloads, the DMG or a translocated path | eject the DMG, open `/Applications/Daylight.app` |
| On the Mac: Gatekeeper says the app is damaged or cannot be checked, on a Mac without internet | the app inside the DMG is not stapled (LOOSE_ENDS G8) | connect to the internet for the first launch, or install from `Daylight-signed.zip`, whose app is stapled |

## How notarization behaves, and the 75 a day cap

Apple's notary service completes most submissions within 5 minutes and 98 percent within 15; the script waits up to 30 minutes and the job has a 60 minute budget. Apple asks teams to limit notarizations to 75 per day: every `v*` tag and every notarize dispatch is one submission, a plain push with the secrets is none (it signs only). Sign on every push if you like; notarize when you intend to install. The ticket is stapled to the DMG and to the app in `Daylight-signed.zip`; an online Mac also checks the ticket with Apple on first launch.

Certificate lifetimes: as long as the Developer ID certificate was valid when the build was made, the app keeps launching after the certificate expires; the provisioning profile must stay valid (18 years for Developer ID profiles). The API key does not expire unless revoked.

## Artifacts

| Artifact | When | Holds |
|---|---|---|
| `Daylight-unsigned` | always | the unsigned app zip (menu bar, preview, web page; no camera) |
| `xcodebuild-logs` | always | build and test logs, `app-contents.txt`, vendor facts, `self-test.log` |
| `release-logs` | whenever signing was attempted, even on failure | `archive.log`, `export.log`, `identities.txt`, `profile-check.txt`, `signed-flag.txt`, `codesign-*.txt`, `ExportOptions.plist`, `notarytool-submit.json` and `.err`, `notarization-log.json` |
| `Daylight-signed` | signed run | `Daylight-signed.zip` (stapled app on a notarized run) |
| `Daylight-dmg` | notarized run only | `Daylight.dmg`, signed, notarized and stapled |

## Day one before signing is done: the fallback

The unsigned build shows the composed camera picture in its preview window (menu bar > "Preview window"; it opens by itself on unsigned builds and the Settings > General toggle "Preview window floats above other windows" keeps it on top). Every pen gesture, the slide, the chip, saving and hotkeys work there. For a real meeting before the signed build exists, use OBS: add a macOS Screen Capture source, pick the window capture method and Daylight's preview window, click Start Virtual Camera, then choose "OBS Virtual Camera" in Zoom. The resolution and the latency are worse than the real extension, so do not judge the product from it; judge the pen.

## First light in FaceTime (signed build)

Drag Daylight to Applications and open it from there. The Welcome window asks you to approve the camera extension: click "Open System Settings", switch on Daylight Camera under General > Login Items & Extensions > Camera Extensions (on macOS 13 and 14: Privacy & Security > Security), enter your password, return to Daylight and click "Check again". Open FaceTime and choose Video > Daylight Camera: your webcam appears. If FaceTime shows a cream card reading "Daylight is not running. Open Daylight from the menu bar.", Daylight is not running or not yet connected; open it from the menu bar. If Zoom shows a black picture after an update, quit and reopen Zoom.

## 📋 Checklist rows for the first signed run (about 8 minutes)

- [ ] 🟡 Open from Downloads first: "Move Daylight to your Applications folder" (⏱️ 30 s)
- [ ] 🟢 Open from Applications: the approval prompt; "Open System Settings" lands on Camera Extensions; "Check again" turns the step green within 2 s (⏱️ 2 min)
- [ ] 🟣 `systemextensionsctl list` shows `com.twelve.daylight.camera [activated enabled]` (⏱️ 30 s)
- [ ] 📋 Paste the `directions=[a, b]` log line into LOOSE_ENDS E2 (⏱️ 30 s)
- [ ] 🟡 Quit Daylight, pick Daylight Camera in FaceTime: the cream card with the sentence (⏱️ 30 s)
- [ ] 🟢 Reopen Daylight: the webcam replaces the card within 2 s; the log says `viewers=1` (⏱️ 30 s)
- [ ] ⏱️ Close FaceTime: `viewers=0` within 1 s; LED off after 60 s; reopen: picture back within a second (⏱️ 2 min)
- [ ] 🟢 Zoom and FaceTime together: `viewers=2`, both show the picture (⏱️ 1 min)
- [ ] 🟡 Row 13 on purpose: uninstall the extension, relaunch, read both sentences 30 s apart, approve again, connected without a relaunch (⏱️ 2 min)
- [ ] 🟢 First app update over a running build: FaceTime keeps showing frames without relaunching Daylight (the sink re-validates its connection every 2 s, LOOSE_ENDS G1)
- [ ] 📋 Read `release-logs/notarytool-submit.json`, `profile-check.txt` and `signed-flag.txt` once and paste anything surprising into LOOSE_ENDS G
