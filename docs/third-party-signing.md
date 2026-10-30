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
4. Keep the app's Bundle ID within the profile's permitted namespace. A `*`
   profile keeps the real app Bundle ID; an exact profile requires that exact ID.
5. Retained extensions need profiles authorized for their Bundle IDs and the same
   signing certificate. A wildcard can cover both the main app and extensions.

An unrelated Apple ID profile cannot authorize a third-party `.p12`. Missing or
mismatched pairs now fail before signing. Expired profiles, mismatched device
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

No real certificates, private keys, passwords or device identifiers are included
in the tests.

## Running SideStore without App Groups

When the signing profile does not grant SideStore access to an App Group, the main app now stores its database in Application Support/LocalDatabase. This is persistent storage, not a temporary or in-memory database. Existing shared storage remains the default when available. Once a local store is created, it remains selected across launches and signing capability changes; no automatic merge with a shared store is attempted. Extensions never create private database copies. Widget sharing and cross-app backup features still require appropriate App Group entitlements.

The local maintenance counter is stored with the local database, preventing first-run maintenance from clearing imported credentials on every launch. Startup-dependent account import and UI transitions wait for database startup. Background log cleanup and error logging skip writes when startup has failed. Real-device re-signing and reinstall behavior needs proper testing.
