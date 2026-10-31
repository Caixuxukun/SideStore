# Third-party signing in this fork

This fork supports importing a matching `.p12` and `.mobileprovision` pair.
It retains SideStore's existing sign-in, pairing and device connection setup.

1. Import the `.p12` (with its password) in Settings → Certificates.
2. Import the `.mobileprovision` in Settings → Profile Management → + → Import from Files.
   Confirm Import. The profile should display a matching signing certificate.
3. For an existing app, select its provisioning profile and choose **Set & Resign**.
   For a new app, enable provisioning-profile customization and choose the imported
   profile during installation. Alternatively, activate the matching certificate:
   a compatible local profile is selected automatically.
4. The app keeps its own Bundle ID. When the profile's App ID differs, SideStore
   signs Feather-style: the profile's `application-identifier` is embedded in the
   entitlements and iOS accepts it, even though the Info.plist Bundle ID does not
   match. A `*` profile is concretised to the app's Bundle ID.
5. Retained extensions need profiles authorized for their Bundle IDs and the same
   signing certificate. A wildcard can cover both the main app and extensions.

An unrelated Apple ID profile cannot authorize a third-party `.p12`: the profile
must contain the selected certificate. App ID mismatches are allowed for imported
profiles (they are signed with the profile's application identifier), while an
Apple-ID-issued profile still has to match. Expired profiles, mismatched device
lists, App Store-only profiles and incompatible extensions produce errors.
The original Apple-signed profile bytes are embedded without modification.
Certificate revocation checking retains the existing OCSP behavior.

## Verification

Run the standalone policy regression tests with a Swift 6 toolchain:

```sh
swiftc -swift-version 6 SideStore/Core/Profiles/SigningProfileRules.swift scripts/tests/SigningProfileRulesTests.swift -o /tmp/profile-tests
/tmp/profile-tests
```

The dedicated GitHub Actions workflow runs these tests on macOS. It does not
build the iOS app or verify installation on a device.

Before distributing an IPA, build the complete project with its required Xcode
version and submodules, then verify on a test device:

- Import from both local Files and a cloud file provider; confirm success or a visible error.
- Import a matching certificate/profile pair in either order.
- Install and launch an app with a wildcard profile; inspect the signed
  `application-identifier` and `CFBundleIdentifier` for concrete IDs.
- Install an app with extensions using both a shared wildcard and separate exact profiles.
- Reject an unrelated certificate, expired profile, unauthorized UDID, App Store
  profile, unrelated wildcard prefix and extension without a matching profile.
- Refresh/re-sign the installed app; when changing certificates, require re-signing.
- Install and refresh with the normal Apple ID signing path.
- Sign the IPA with an external tool that provisions only the main app, then
  launch SideStore; the widget extension should inherit the main profile instead
  of blocking the first launch.
- Install with a matching imported profile while signed out: no App ID should be
  registered, no Team ID should be appended, and the app should be signed with the
  imported certificate.

No real certificates, private keys, passwords or device identifiers are included
in the tests.

## Running SideStore without App Groups

When the signing profile does not grant SideStore access to an App Group, the main app now stores its database in Application Support/LocalDatabase. This is persistent storage, not a temporary or in-memory database. Existing shared storage remains the default when available. Once a local store is created, it remains selected across launches and signing capability changes; no automatic merge with a shared store is attempted. Extensions never create private database copies. Widget sharing and cross-app backup features still require appropriate App Group entitlements.

The local maintenance counter is stored with the local database, preventing first-run maintenance from clearing imported credentials on every launch. Startup-dependent account import and UI transitions wait for database startup. Background log cleanup and error logging skip writes when startup has failed. Real-device re-signing and reinstall behavior needs proper testing.

## Installing with another signer

Tools such as ESign or iloader sometimes provision only the main app and leave
`AltWidgetExtension.appex` without its own `embedded.mobileprovision`. SideStore
now falls back to the enclosing app's profile for an extension that has no
readable profile, so the first launch no longer stops with
`SignerError.invalidApp(cause: "The app extension is missing a valid provisioning profile.")`.
The extension inherits the main app's creation and expiration dates. Extensions
that embed their own profile are unaffected, and a main app without a profile is
still rejected as before. The fallback covers launch and install bookkeeping
only; signing still requires a profile for every retained extension.

## Imported certificate with Apple ID signing

Apple only issues profiles for certificates that belong to the profile's team, so
an imported third-party `.p12` can never sign an Apple-ID-issued profile. The
automatic matching only considers imported profiles whose App ID covers the app's
Bundle ID; the manual picker lists every imported profile and marks the rest as
“App ID mismatch”, which are signed Feather-style as described above.

When the active certificate belongs to another team and no imported profile is
selected for the app, the install stops in `VerifyCertificateOperation`, before any
App ID is registered, with a message that lists the imported profiles and why each
one cannot be used. Select an imported profile for the app (see above) to sign with
the third-party certificate, or activate a certificate from the signed-in Apple ID
team and install normally.

A certificate from the signed-in team that is missing from a freshly downloaded
profile (for example after a renewal) is recovered by signing with the certificate
the profile authorizes, instead of producing a signature iOS rejects with
`0xe8008015`.

When an imported profile covers the app's Bundle ID and contains the active
certificate, it is resolved before customization and the install runs without an
Apple ID: the team ID suffix is not appended, preflight and installation skip the
team lookup, and no App ID is registered on the portal. A signed-in Apple ID is
still required when no usable imported profile is found.


