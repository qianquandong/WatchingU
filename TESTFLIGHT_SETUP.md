# TestFlight setup

The **TestFlight** GitHub Actions workflow runs manually on `main`. Its `build_mode` choice defaults to **google-drive**, which requires real Google OAuth configuration. Choose **local-recording** to test recording before Google setup is ready: Watch recording, reminders, fixed stop, Watch-to-iPhone transfer, playback and manual export are available for device testing; Drive upload and cloud-based previous-day cleanup are unavailable, and recordings remain on the iPhone. Both modes use the same bundle identifiers, so a later Drive build can upgrade the local test build.

The workflow checks configuration, runs native CI checks, archives the iPhone app with its embedded Watch app and both Widget extensions, exports the IPA, verifies all four distribution signatures, Team IDs, App Groups, application identifiers and embedded App Store profiles, and uploads the archive to App Store Connect using an API key. It does not publish an App Store release, invite testers, or submit an external beta review.

## One-time account setup

An active Apple Developer Program membership and an App Store Connect app record are required. No membership or paid service is purchased by this repository.

Register four explicit App IDs in the same Apple team:

| Target | Bundle identifier |
| --- | --- |
| DayTape | Your chosen `DAYTAPE_BUNDLE_PREFIX`, for example `com.yourcompany.daytape` |
| DayTapeWatch | The same prefix plus `.watchkitapp` |
| DayTapeWidgets | The same prefix plus `.widgets` |
| DayTapeWatchWidgets | The same prefix plus `.watchkitapp.widgets` |

Enable the same App Group for all four identifiers; its default is `group.` followed by the iPhone bundle identifier. Enable HealthKit for the iPhone identifier. Health and location collection remain opt-in in the app; signing must nevertheless allow the capabilities the build contains.

Create the App Store Connect app record for the iPhone bundle identifier. The Watch application ships inside that app. Configure a real Google **iOS** OAuth client for the identical iPhone bundle identifier and enable Google Drive API in that Google project. For a Google OAuth consent screen in testing, add the Google accounts that will test Drive upload. No Google client secret belongs in the app or repository.

## GitHub Actions variables

Open repository **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `DAYTAPE_BUNDLE_PREFIX` | The registered iPhone bundle identifier |
| `DAYTAPE_APP_GROUP` | Optional; defaults to `group.` plus `DAYTAPE_BUNDLE_PREFIX`. Must be enabled on all four identifiers |
| `GOOGLE_CLIENT_ID` | A real Google iOS OAuth client ID; required for `google-drive`, unused for `local-recording` |
| `APPLE_SIGNING_STYLE` | `automatic` (default), or `manual` for the certificate/profile method below |

The Google reversed client ID is derived automatically. The iPhone uses `Phone/DayTape.entitlements` with HealthKit and the shared App Group. The Watch and Widget extensions request only the shared App Group.

## Configure from your Mac

The existing Apple team key **GitHub CI** can be reused. With GitHub CLI installed and signed in to an account with administrator access to `qianquandong/WatchingU`, run this from the cloned repository on your Mac:

```bash
bash Scripts/configure_ci_macos.sh "/path/to/AuthKey_KEYID.p8" "YOUR_REAL_GOOGLE_IOS_CLIENT_ID.apps.googleusercontent.com"
```

Supply the original `.p8` downloaded for that key and the real Google iOS client ID. The helper infers the Key ID from the original `AuthKey_KEYID.p8` filename and prompts for the team's Issuer ID; alternatively pass the Issuer ID as the third argument and Key ID as the fourth, or set `APP_STORE_CONNECT_API_ISSUER_ID` / `APP_STORE_CONNECT_API_KEY_ID` in your environment. Omitting the first two arguments prompts for them. The helper defaults to team `GB24TMUMQ5` and bundle prefix `com.aimanjack.daytape`, validates the file/configuration, and writes the three secrets and three required variables using standard input. It never prints the private key or starts the TestFlight workflow. Keep `APPLE_SIGNING_STYLE` unset or `automatic` for this setup. The App Store Connect app record must exist before running TestFlight.

To configure Apple signing first without a Google client ID:

```bash
bash Scripts/configure_ci_macos.sh --signing-only "/path/to/AuthKey_KEYID.p8"
```

This prompts for the Issuer ID, or accepts it as the next argument (and an optional Key ID after that). It writes the three Apple secrets and the Team/bundle variables only. Then select `local-recording` in the manual workflow; no workflow starts automatically. This mode forces the app's existing unconfigured Google sentinel even if a Google variable already exists. The app's backup option reports that cloud backup is unavailable; keep it off during this local test. Run the normal helper later with a real Google client ID and choose `google-drive` to test backup.

## App Store Connect API secrets

Use an App Store Connect **team API key** from **Users and Access → Integrations → App Store Connect API**. Download its `.p8` file once and keep it secure. API access and certificates/identifiers/profiles access must be enabled for automatic signing; an Admin key is the usual automatic-signing choice. A key limited to uploading builds can be used with manual signing. The key must have access to this app.

Add these under **Settings → Secrets and variables → Actions → Secrets**:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | The key's 10-character Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | The team's Issuer ID UUID |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | Base64 of the downloaded `.p8` file |

On your Mac, copy a file's base64 directly to the clipboard, then paste it into the GitHub secret form:

```bash
base64 -i /path/to/AuthKey_KEYID.p8 | pbcopy
```

With automatic signing, the archive is built with signing disabled. Before export, the workflow expands each target's declared entitlements and applies private temporary ad-hoc signatures from the innermost extension to the containing apps. This preserves App Group and HealthKit claims through export; the temporary signatures are never distributed. App Store Connect export and upload then use the API key, `-allowProvisioningUpdates`, and `signingStyle: automatic` to obtain real distribution signing for all four targets. Final verification independently checks every distribution signature and profile before upload. This avoids requiring development devices just to distribute a TestFlight build. If Apple account policy or key permissions prevent provisioning the declared capabilities, the workflow fails rather than silently omitting them. Manual signing uses the supplied Apple Distribution certificate and four App Store profiles.

## Manual signing fallback

Set `APPLE_SIGNING_STYLE` to `manual`. Export an **Apple Distribution** signing certificate together with its private key from Keychain Access as a password-protected `.p12`. Create and download four **App Store Connect distribution** provisioning profiles, one for each bundle identifier, using that certificate. All four profiles must include the shared App Group, and the iPhone profile must include HealthKit. Development, Ad Hoc, expired, wildcard, and profiles from another team are rejected. Two app profiles without the two Widget profiles cannot export this build and are rejected before archiving.

Add six more repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 of the certificate/private-key `.p12` |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | The `.p12` export password |
| `APPLE_PROVISION_PROFILE_IOS_BASE64` | Base64 of the iPhone `.mobileprovision` |
| `APPLE_PROVISION_PROFILE_WATCH_BASE64` | Base64 of the Watch `.mobileprovision` |
| `APPLE_PROVISION_PROFILE_IOS_WIDGET_BASE64` | Base64 of the iPhone Widget `.mobileprovision` |
| `APPLE_PROVISION_PROFILE_WATCH_WIDGET_BASE64` | Base64 of the Watch Widget `.mobileprovision` |

Use the same `base64 -i /path/to/file | pbcopy` command for each file. Keep signing files out of commits and issue comments. This route installs a temporary keychain, selects a separate provisioning profile for each of the four targets, then deletes the imported files at the end of the job.

## Upload and install

The default `feature_set` is `full`: four targets, HealthKit and the shared App Group remain mandatory and independently verified. An explicit `core-testing` fallback is available only for automatic signing when Apple capability registration is externally blocked. It contains the iPhone and Watch apps with empty capability entitlements, no Widget extensions, no HealthKit API calls and no widget sharing. The app and workflow summary label these omissions. Core recording, paired synchronization, transcription, AI, marks, location, speaker identification, export and desktop access remain in the source. This switch is independent from the Google Drive `build_mode`; it must never be used to call a limited build fully accepted. `verify_core_export.py` still requires real App Store signatures, matching identifiers/versions and distribution profiles, and rejects a core executable claiming Group or HealthKit. Selecting `full` restores the four-target generation and its existing strict checks.

1. Open **Actions → TestFlight → Run workflow**, select `main`, choose `google-drive` (default) or `local-recording`, and run it. Only a manual run on `main` can reach signing and upload.
2. The workflow assigns a matching app/Widget build number from `run_number.run_attempt`. If an existing App Store Connect build has a higher number, increase the project's marketing version or adjust the numbering before another upload.
3. After upload, open the app's **App Store Connect → TestFlight** page and wait for Apple's processing. A green workflow reports upload acceptance; it does not prove Apple processing succeeded.
4. Complete any export-compliance or test-information requests, add yourself to an internal testing group, and install with TestFlight on the paired iPhone. Enable/install the companion app in the iPhone Watch app if needed. External testing may require Apple's beta review.

The standard `macos-15` runner selects the newest installed stable Xcode 26 or newer and verifies that both the iOS and watchOS SDK versions are at least 26 before building. This meets Apple's upload requirement effective April 28, 2026; deployment targets remain iOS 17 and watchOS 10. The CI artifact contains test results and redacted build logs. Signing files, the signed IPA and archive stay outside the artifact directory and are removed when the job exits. A fresh GitHub-hosted runner is required; the upload script intentionally refuses local execution.

## Official references

- [GitHub: sign Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub macOS 15 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [Apple: create an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)
- [Apple: upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: current SDK upload requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Apple: distribute for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Apple WWDC21: API-key automation and cloud distribution signing](https://developer.apple.com/videos/play/wwdc2021/10204/)
- [Apple: inspect code signing profiles and entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple: export from the command line](https://help.apple.com/xcode/mac/current/en.lproj/dev23ea8b877.html)
- [fastlane: App Store Connect API authentication and TestFlight upload](https://docs.fastlane.tools/actions/upload_to_testflight/)
- [GitHub CLI: set a secret from standard input](https://cli.github.com/manual/gh_secret_set)
