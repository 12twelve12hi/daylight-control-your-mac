# Signing and notarization

macOS loads a camera extension only from an app signed with a Developer ID and notarized. Until the owner finishes this checklist, every CI build is the unsigned `Daylight-unsigned.zip`: menu bar, preview window, web page, Allow panel, saving and hotkeys work; "Daylight Camera" never appears in Zoom or FaceTime (failure row 2, SPEC 13.3).

Writing rules: no em-dashes; LivePaper is a transflective LCD; the backlight is DC dimming.

## Owner checklist (about 30 minutes, no Xcode needed)

Prerequisites: a paid Apple Developer Program membership where you hold the Account Holder role; any Mac with Keychain Access; the `gh` CLI logged in to the build repository.

1. Team ID: developer.apple.com/account > Membership details > copy the 10-character Team ID.
2. Certificate signing request: Keychain Access > menu Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Your email, Common Name "Daylight Developer ID", CA Email empty, "Saved to disk", Continue, save the `.certSigningRequest` file.
3. Developer ID certificate: Certificates, Identifiers & Profiles > Certificates > + > under Software choose Developer ID > Continue > pick the Application type (not Installer) > Choose File (your CSR) > Continue > Download the `.cer` > double-click it so it lands in Keychain Access under My Certificates.
4. Export the `.p12`: Keychain Access > login > My Certificates > "Developer ID Application: <you> (<TEAMID>)" (open the triangle: a private key must hang under it) > right-click > Export > format `.p12` > choose a strong password.
5. App IDs: Identifiers > + > App IDs > App > Description "Daylight" > Explicit Bundle ID `com.twelve.daylight` > tick System Extension and App Groups > Continue > Register. Repeat for `com.twelve.daylight.camera` with App Groups ticked. Do not register a `group.` app group; the Team ID form needs none.
6. Profiles: Profiles > + > Distribution: Developer ID > Continue > App ID `com.twelve.daylight` > Continue > select the Developer ID Application certificate > Continue > Name "Daylight Developer ID" > Generate > Download. Repeat for `com.twelve.daylight.camera` with the name "Daylight Camera Developer ID". If you ever edit an App ID's capabilities, regenerate its profile.
7. App Store Connect API key: appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API > Team Keys > + > name "Daylight CI notarization", role Developer (Admin if Developer is refused) > Generate > Download `AuthKey_<KEYID>.p8` (one chance) > note the Key ID and the Issuer ID.
8. Secrets, from the folder with the files:
   - `gh secret set DAYLIGHT_TEAM_ID --body <TEAMID>`
   - `gh secret set DAYLIGHT_DEVELOPER_ID_P12_BASE64 < <(base64 -i developerID.p12)`
   - `gh secret set DAYLIGHT_DEVELOPER_ID_P12_PASSWORD --body '<password>'`
   - `gh secret set DAYLIGHT_APP_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Developer_ID.provisionprofile)`
   - `gh secret set DAYLIGHT_EXT_PROVISIONING_PROFILE_BASE64 < <(base64 -i Daylight_Camera_Developer_ID.provisionprofile)`
   - `gh secret set ASC_API_KEY_ID --body <KEYID>`
   - `gh secret set ASC_API_ISSUER_ID --body <ISSUER>`
   - `gh secret set ASC_API_PRIVATE_KEY_BASE64 < <(base64 -i AuthKey_<KEYID>.p8)`
9. Re-run the workflow (Actions > whiteboard-camera > Run workflow with "notarize" ticked, or push a `v*` tag such as `v0.1.0`). Download `Daylight-dmg`.
10. Keep the `.p12`, both profiles and the `.p8` in your password manager. Profiles last 18 years.

What macOS does with it: a Developer ID signed system extension loads only when notarized. The unsigned CI build is for compile checks and the preview window; it can never show "Daylight Camera" in Zoom.

## What the mac job does with the secrets (`scripts/mac-release.sh`, `make mac-release`)

- Gate first, in seconds: with no `DAYLIGHT_*` or `ASC_*` secret at all the step prints what is missing and exits 0 (the unsigned run stays green). With a partial set, a misnamed name, a `v*` tag or a notarize dispatch without the three `ASC_*` secrets, or `DO_NOTARIZE=true` with an `ASC_*` missing, it exits 1 naming the gap: a green run with the wrong artifact is the worst outcome. `scripts/scripts-check.sh` (`make scripts-check`, in the golden job) proves the gate on Linux.
- Notarization happens only on a `v*` tag or when the workflow is dispatched with `notarize: true` (SPEC D22); a plain push with all eight secrets signs and exports but does not notarize, and the extension of that build fails with `OSSystemExtensionError 8` (row 9) on a Mac. Use the tag or the dispatch for anything you install.
- The team must agree across `DAYLIGHT_TEAM_ID`, the `(TEAMID)` suffix of the certificate and `TeamIdentifier.0` of the app profile (hard error); the app profile should allowlist `com.apple.developer.system-extension.install` and name `com.twelve.daylight` (warnings in `release-logs/profile-check.txt`).
- `DaylightBuildSigned` is written as false by `project.yml` and flipped to a Bool true with `plutil -replace` on the generated `mac/Daylight/Info.plist` right after `scripts/mac-generate.sh`; the exported app is asserted to carry true and `Contents/embedded.provisionprofile`, so a signed artifact can never behave like the unsigned build.
- Notarization: `notarytool submit --wait --timeout 30m` on the DMG, the log fetched whenever a submission id exists, then the DMG is stapled, the exported app is stapled and `Daylight-signed.zip` is re-created from it. The app inside the DMG is not stapled: an online Mac validates it against the notary service on first launch; an offline first launch fails Gatekeeper (LOOSE_ENDS G8).
- Secrets never reach the log: no `set -x` by default (`RUNNER_DEBUG` enables it for the codesign and xcodebuild part only, and it is off around the `.p8` decode); the decoded `.p12`, `.p8`, profiles and plists are removed on exit, the temporary keychain is deleted, and a local run restores the keychain search list.

## Artifacts

| Artifact | When | Holds |
|---|---|---|
| `Daylight-unsigned` | always | the unsigned app zip (menu bar, preview, web page; no camera) |
| `xcodebuild-logs` | always | build and test logs, `app-contents.txt`, vendor facts |
| `release-logs` | whenever signing was attempted, even on failure | `archive.log`, `export.log`, `identities.txt`, `profile-check.txt`, `signed-flag.txt`, `codesign-*.txt`, `ExportOptions.plist`, `notarytool-submit.json` and `.err`, `notarization-log.json` |
| `Daylight-signed` | signed run | `Daylight-signed.zip` (stapled app on a notarized run) |
| `Daylight-dmg` | notarized run only | `Daylight.dmg`, signed, notarized and stapled |

## First light in FaceTime (signed build)

Drag Daylight to Applications and open it from there. The Welcome window asks you to approve the camera extension: click "Open System Settings", switch on Daylight Camera under General > Login Items & Extensions > Camera Extensions (on macOS 13 and 14: Privacy & Security > Security), enter your password, return to Daylight and click "Check again". Open FaceTime and choose Video > Daylight Camera: your webcam appears. If FaceTime shows a cream card reading "Daylight is not running. Open Daylight from the menu bar.", Daylight is not running or not yet connected; open it from the menu bar. If Zoom shows a black picture after an update, quit and reopen Zoom.

## Checklist rows for the first signed run (about 8 minutes)

- Open from Downloads first: "Move Daylight to your Applications folder" (30 s)
- Open from Applications: the approval prompt; "Open System Settings" lands on Camera Extensions; "Check again" turns the step green within 2 s (2 min)
- `systemextensionsctl list` shows `com.twelve.daylight.camera [activated enabled]` (30 s)
- Paste the `directions=[a, b]` log line into LOOSE_ENDS E2 (30 s)
- Quit Daylight, pick Daylight Camera in FaceTime: the cream card with the sentence (30 s)
- Reopen Daylight: the webcam replaces the card within 2 s; the log says `viewers=1` (30 s)
- Close FaceTime: `viewers=0` within 1 s; LED off after 60 s; reopen: picture back within a second (2 min)
- Zoom and FaceTime together: `viewers=2`, both show the picture (1 min)
- Row 13 on purpose: uninstall the extension, relaunch, read both sentences 30 s apart, approve again, connected without a relaunch (2 min)
- First app update over a running build: FaceTime keeps showing frames without relaunching Daylight (the sink re-validates its connection every 2 s, LOOSE_ENDS G1)
- Read `release-logs/notarytool-submit.json`, `profile-check.txt` and `signed-flag.txt` once and paste anything surprising into LOOSE_ENDS G
