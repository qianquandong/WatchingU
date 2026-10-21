# TestFlight setup

The **TestFlight** GitHub Actions workflow runs manually on `main`. It checks configuration, runs the native CI checks, archives the iPhone app with its embedded Watch app, exports and verifies the signed IPA, and uploads the archive to App Store Connect using an API key. It does not publish an App Store release, invite testers, or submit an external beta review.

## One-time account setup

An active Apple Developer Program membership and an App Store Connect app record are required. No membership or paid service is purchased by this repository.

Register two explicit App IDs in the same Apple team:

| Target | Bundle identifier |
| --- | --- |
| DayTape | Your chosen `DAYTAPE_BUNDLE_PREFIX`, for example `com.yourcompany.daytape` |
| DayTapeWatch | The same prefix plus `.watchkitapp` |

Create the App Store Connect app record for the iPhone bundle identifier. The Watch application ships inside that app. Configure a real Google **iOS** OAuth client for the identical iPhone bundle identifier and enable Google Drive API in that Google project. For a Google OAuth consent screen in testing, add the Google accounts that will test Drive upload. No Google client secret belongs in the app or repository.

## GitHub Actions variables

Open repository **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `DAYTAPE_BUNDLE_PREFIX` | The registered iPhone bundle identifier |
| `GOOGLE_CLIENT_ID` | The Google iOS OAuth client ID ending in `.apps.googleusercontent.com` |
| `APPLE_SIGNING_STYLE` | `automatic` (default), or `manual` for the certificate/profile method below |

The Google reversed client ID is derived automatically. The scheduled recording/backup version uses the entitlement file without HealthKit.

## Configure from your Mac

The existing Apple team key **GitHub CI** can be reused. With GitHub CLI installed and signed in to an account with administrator access to `qianquandong/WatchingU`, run this from the cloned repository on your Mac:

```bash
bash Scripts/configure_ci_macos.sh "/path/to/AuthKey_KEYID.p8" "YOUR_REAL_GOOGLE_IOS_CLIENT_ID.apps.googleusercontent.com"
```

Supply the original `.p8` downloaded for that key and the real Google iOS client ID. The helper infers the Key ID from the original `AuthKey_KEYID.p8` filename and prompts for the team's Issuer ID; alternatively pass the Issuer ID as the third argument and Key ID as the fourth, or set `APP_STORE_CONNECT_API_ISSUER_ID` / `APP_STORE_CONNECT_API_KEY_ID` in your environment. Omitting the first two arguments prompts for them. The helper defaults to team `GB24TMUMQ5` and bundle prefix `com.aimanjack.daytape`, validates the file/configuration, and writes the three secrets and three required variables using standard input. It never prints the private key or starts the TestFlight workflow. Keep `APPLE_SIGNING_STYLE` unset or `automatic` for this setup. The App Store Connect app record must exist before running TestFlight.

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

Automatic signing passes that API key to Xcode with `-allowProvisioningUpdates` for both archive and export. Xcode may create or download signing certificates and provisioning profiles for the two targets in your Apple team. If Apple account policy or key permissions prevent this, use the manual method; the workflow does not silently switch signing methods.

## Manual signing fallback

Set `APPLE_SIGNING_STYLE` to `manual`. Export an **Apple Distribution** signing certificate together with its private key from Keychain Access as a password-protected `.p12`. Create and download two **App Store Connect distribution** provisioning profiles, one for each bundle identifier, using that certificate. Development, Ad Hoc, expired, wildcard, and profiles from another team are rejected.

Add four more repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 of the certificate/private-key `.p12` |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | The `.p12` export password |
| `APPLE_PROVISION_PROFILE_IOS_BASE64` | Base64 of the iPhone `.mobileprovision` |
| `APPLE_PROVISION_PROFILE_WATCH_BASE64` | Base64 of the Watch `.mobileprovision` |

Use the same `base64 -i /path/to/file | pbcopy` command for each file. Keep signing files out of commits and issue comments. This route installs a temporary keychain, selects a different provisioning profile for the iOS and watchOS SDKs, then deletes the imported files at the end of the job.

## Upload and install

1. Open **Actions → TestFlight → Run workflow**, select `main`, and run it. Only a manual run on `main` can reach signing and upload.
2. The workflow assigns a matching iPhone/Watch build number from `run_number.run_attempt`. If an existing App Store Connect build has a higher number, increase the project's marketing version or adjust the numbering before another upload.
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
- [Apple: export from the command line](https://help.apple.com/xcode/mac/current/en.lproj/dev23ea8b877.html)
- [fastlane: App Store Connect API authentication and TestFlight upload](https://docs.fastlane.tools/actions/upload_to_testflight/)
- [GitHub CLI: set a secret from standard input](https://cli.github.com/manual/gh_secret_set)
