# iOS1 isolated source tree

This directory is the isolated iOS1 application source imported from the
approved `ios-chat-jht-0903.zip` handoff. The source archive SHA-256 is
`f800aca48e5b3c6150b30d4dd60fc7a7ba0189975dd145abc564d843237e4a3a`.
It is independent from `code/apps/ios-chat`; iOS0 must not be used as a build,
install, or runtime target while validating iOS1.

## Build

Open `WenDaTong.xcodeproj` or build the `WenDaTong` scheme with a dedicated
DerivedData directory. Package resolution must use `Package.resolved`; validation
must not rewrite the source tree or shared Xcode caches.

The app uses `Debug` for local development and `Release` for optimized local
validation. An ordinary unsigned Release build does not establish a signed
distribution artifact.
The unconfigured App2 build configurations and scheme have been removed.
Historical `scripts/*app2*` release tooling remains for reference and is not
part of the current app build; it requires restoring an App2 scheme/configuration.

## App identity and distribution

The current unpublished iOS1 app target uses `app.xltest.com` in Debug and
Release with the existing team `A3PN7W63G3`. Shared archive schemes use the same
App target and Release configuration. Local unsigned builds do not establish a
signed distribution artifact.

<!-- WDT_IOS1_CODEMAGIC_JDT_RELEASE_20261113_BEGIN -->
`codemagic.yaml` now adapts the existing `jdt` release workflow for this project.
It builds `WenDaTong.xcodeproj` / `WenDaTong` in Release, using the production
Bundle ID `com.wendatongqiye.app` from `jdt`. `APP_VERSION` is currently `1.0.6`,
matching the user's updated project version.
Only the disposable CI checkout's app Release settings are changed; local
Debug/Release defaults above remain unchanged. Backend App IDs, bootstrap URLs,
and business configuration are not changed by this workflow.

Reuse the existing Codemagic `appstore_credentials` environment group with
`APP_STORE_CONNECT_PRIVATE_KEY`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
`APP_STORE_CONNECT_ISSUER_ID`, `APPLE_TEAM_ID`, and `CERTIFICATE_PRIVATE_KEY`.
The optional `APPLE_BUNDLE_ID_RESOURCE_ID` has the same meaning as in `jdt`.
No private keys are stored in the repository. Uploads target the existing app by
its Bundle ID; a numeric App Store Apple ID is not required by this workflow.

The workflow ID, main/master push triggers, M2 machine, signing/APNs steps and
upload-only publishing policy are retained. Both automatic review flags remain
false. `BUILD_NUMBER` still supplies the build version, as in `jdt`: when adding
a new Codemagic application instead of reusing the existing one, ensure its next
build number exceeds the build already uploaded for the chosen version. Increase
`APP_VERSION` if App Store Connect requires a new marketing version.

The workflow requires the APNs helper, the verifier and the project's existing
`Package.resolved` alongside `codemagic.yaml` to keep package versions locked.
This local setup does not initialize or modify a Git repository. If the files
are later moved to Git, include this lockfile explicitly: the existing
`.gitignore` ignores `Package.resolved` and is intentionally unchanged.
The signed archive verifier accepts the explicit CI
expectations `APP1_VERIFY_BUNDLE_ID` and `APP1_VERIFY_TEAM_ID`; all existing
signature, certificate, profile, APS and diagnostics checks remain strict.
Without those variables its original local identity defaults remain in force.
The local configuration work does not trigger a build or upload on Codemagic.
<!-- WDT_IOS1_CODEMAGIC_JDT_RELEASE_20261113_END -->

## Privacy Manifest

`WenDaTong/WDTResources/PrivacyInfo.xcprivacy` is included in the app target resources. It
declares the required reason API categories used by this source tree:
`FileTimestamp`, `SystemBootTime`, and `UserDefaults`. The current third-party
dependencies are `WebRTC`, `GRDB.swift`, and vendored `Wuffs`; they are not on
Apple's commonly used third-party SDK list that requires SDK signatures and
privacy manifests. The standalone `app_privacy_manifest_fixer` tool can still
be used against a built archive for audit/reporting, but it is intentionally
not wired into the Codemagic signing path.

Ordinary Debug, Release, App Store, APP1, APP2, and internal-validation builds
all compile the floating access-diagnostics overlay and record the same
capability marker. Formal APP1 and APP2 archive verifiers require both the
marker and metadata. The legacy `ACCESS_DIAGNOSTICS_OVERLAY_ENABLED` condition
used by `scripts/archive-internal-validation.sh` enables only additional
internal trace collectors; it is not an authorization mechanism and does not
control whether the overlay exists.

At runtime the overlay remains fail-closed. It can open only when the platform
current-policy explicitly enables `access_diagnostics_overlay_enabled` for the
exact effective AppId and the active page receives five Logo taps within three
seconds. Disabled or unavailable policy, AppId mismatch, scope change, and page
navigation reset activation. The authenticated entry is the Logo under
`我的 → 关于 问达通`.

The prelogin bootstrap test vectors are vendored under
`WenDaTongTests/Resources/` so this subtree can build for testing without
reaching outside the isolated source tree.

## Dedicated simulator

`scripts/run-simulator.sh` requires `SIMULATOR_UDID` to identify one existing,
available, already-booted dedicated simulator. It never chooses, creates, boots,
erases, shuts down, or uninstalls a device. It reads the built app's bundle ID,
requires `app.xltest.com`, and installs over the existing app so app
data is preserved.

Example, using placeholders only:

```bash
SIMULATOR_UDID='<dedicated-simulator-uuid>' \
DERIVED_DATA_PATH='/absolute/path/to/dedicated-derived-data' \
scripts/run-simulator.sh
```

Any data reset is a separate destructive action and is outside this script.
This import task does not authorize simulator lifecycle, install, launch, or
reset operations.

## Local services and authentication material

iOS1 does not own a local service launcher. When a separately authorized local
environment is required, use the repository-controlled entrypoint
`../../qa/local-infra/run-dev-stack.sh` under its own documented controls.

No account identifiers, authentication values, private keys, or tokens belong
in this README, the source tree, scripts, terminal output, or Git. Supply any
authorized runtime material through the existing protected runtime boundary and
refer to it by key name only.

## Focused checks

```bash
scripts/run-simulator-test.sh
scripts/task024-ios-p1-repair-source-smoke.sh
scripts/archive-app2-release-test.sh
```

Runtime XCTest and simulator mutation remain separate, explicitly authorized
stages.
