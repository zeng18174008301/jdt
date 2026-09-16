# iOS1 isolated source tree

This directory is the isolated iOS1 application source imported from the
approved `ios-chat-jht-0903.zip` handoff. The source archive SHA-256 is
`f800aca48e5b3c6150b30d4dd60fc7a7ba0189975dd145abc564d843237e4a3a`.
It is independent from `code/apps/ios-chat`; iOS0 must not be used as a build,
install, or runtime target while validating iOS1.

## Build

Open `BlueStoneIM.xcodeproj` or build the `BlueStoneIM` scheme with a dedicated
DerivedData directory. Package resolution must use `Package.resolved`; validation
must not rewrite the source tree or shared Xcode caches.

## Codemagic

The `codemagic.yaml` workflow builds the first shared Xcode scheme,
`BlueStoneIM`, with the `Release` configuration and bundle ID
`com.wendatongqiye.app`.
Keep signing material in Codemagic, not in this source tree.

Required Codemagic signing setup:

- Create a Codemagic environment group named `appstore_credentials`.
- Add `APP_STORE_CONNECT_PRIVATE_KEY`,
  `APP_STORE_CONNECT_KEY_IDENTIFIER`, and `APP_STORE_CONNECT_ISSUER_ID`.
- The API key must be allowed to manage Bundle IDs, capabilities,
  certificates, and provisioning profiles.
- If Codemagic needs to create a distribution certificate, also add
  `CERTIFICATE_PRIVATE_KEY`; if that key is encrypted, add
  `CERTIFICATE_PRIVATE_KEY_PASSWORD`.
- The workflow enables the `Push Notifications` capability for
  `com.wendatongqiye.app`, fetches or creates an App Store provisioning
  profile, installs signing certificates into a temporary keychain, and builds
  the signed IPA without opening Xcode.
- Optional App Store Connect/TestFlight publishing is left as a commented
  block in `codemagic.yaml`; enable it only when the App Store app record is
  ready.

## Privacy Manifest

`BlueStoneIM/PrivacyInfo.xcprivacy` is included in the app target resources. It
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
`我的 → 关于 X01`.

The prelogin bootstrap test vectors are vendored under
`BlueStoneIMTests/Resources/` so this subtree can build for testing without
reaching outside the isolated source tree.

## Dedicated simulator

`scripts/run-simulator.sh` requires `SIMULATOR_UDID` to identify one existing,
available, already-booted dedicated simulator. It never chooses, creates, boots,
erases, shuts down, or uninstalls a device. It reads the built app's bundle ID,
requires `com.wendatongqiye.app`, and installs over the existing app so app
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
