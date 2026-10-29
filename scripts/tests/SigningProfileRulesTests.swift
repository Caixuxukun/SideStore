import Foundation

@main
struct SigningProfileRulesTests {
    static func rejects(_ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("Expected the invalid profile or entitlement to be rejected")
        } catch {}
    }

    static func main() throws {
        assert(SigningProfileRules.matches("*", "com.example.app"))
        assert(SigningProfileRules.matches("com.example.*", "com.example.app"))
        assert(!SigningProfileRules.matches("com.example.*", "com.other.app"))
        assert(!SigningProfileRules.matches("com.example.*", "com.example"))
        assert(!SigningProfileRules.matches("com.example.*", "com.example."))
        assert(!SigningProfileRules.matches("com.*.app", "com.example.app"))
        assert(!SigningProfileRules.matches("*", "*"))
        assert(!SigningProfileRules.matches("*", ""))
        assert(!SigningProfileRules.matches("com.example.app", "com.example.other"))
        let concrete = try SigningProfileRules.bundleIdentifier(profileID: "*", requestedID: "com.example.app")
        assert(concrete == "com.example.app")
        rejects { _ = try SigningProfileRules.bundleIdentifier(profileID: "com.other.*", requestedID: "com.example.app") }

        let profile: [String: any Sendable] = [
            "application-identifier": "LEGACY.*",
            "com.apple.developer.team-identifier": "NEWTEAM",
            "keychain-access-groups": ["LEGACY.*"],
            "get-task-allow": false,
            "com.apple.security.application-groups": ["group.example.shared"],
            "aps-environment": "production"
        ]
        let application: [String: any Sendable] = [
            "application-identifier": "OLD.com.example.app",
            "keychain-access-groups": ["OLD.com.example.app"],
            "com.apple.security.application-groups": ["group.example.shared"],
            "aps-environment": "production",
            "unapproved-entitlement": true
        ]
        let result = try SigningProfileRules.entitlements(profile: profile, application: application, bundleID: "com.example.app")
        assert(result["application-identifier"] as? String == "LEGACY.com.example.app")
        assert(result["com.apple.developer.team-identifier"] as? String == "NEWTEAM")
        assert(result["keychain-access-groups"] as? [String] == ["LEGACY.com.example.app"])
        assert(result["get-task-allow"] as? Bool == false)
        assert(result["unapproved-entitlement"] == nil)
        assert(result["com.apple.security.application-groups"] as? [String] == ["group.example.shared"])

        let extensionResult = try SigningProfileRules.entitlements(profile: profile, application: [:], bundleID: "com.example.app.widget")
        assert(extensionResult["application-identifier"] as? String == "LEGACY.com.example.app.widget")
        assert(extensionResult["keychain-access-groups"] as? [String] == ["LEGACY.com.example.app.widget"])

        var explicitProfile = profile
        explicitProfile["application-identifier"] = "LEGACY.com.example.app"
        rejects { _ = try SigningProfileRules.entitlements(profile: explicitProfile, application: [:], bundleID: "com.example.app.widget") }
        var restricted = profile
        restricted["keychain-access-groups"] = ["LEGACY.com.other"]
        rejects { _ = try SigningProfileRules.entitlements(profile: restricted, application: application, bundleID: "com.example.app") }
        var forbidden = application
        forbidden["com.apple.security.application-groups"] = ["group.other"]
        rejects { _ = try SigningProfileRules.entitlements(profile: profile, application: forbidden, bundleID: "com.example.app") }
        forbidden = application
        forbidden["aps-environment"] = "development"
        rejects { _ = try SigningProfileRules.entitlements(profile: profile, application: forbidden, bundleID: "com.example.app") }

        func cms(_ plist: [String: Any]) throws -> Data {
            var data = Data([0x30, 0x82, 0x00, 0xff])
            data.append(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            data.append(Data([0xff, 0x00]))
            return data
        }
        let development = try cms(["ProvisionedDevices": ["TEST-DEVICE"]])
        try SigningProfileRules.validateDevice(profileData: development, deviceID: "test-device")
        rejects { try SigningProfileRules.validateDevice(profileData: development, deviceID: "OTHER-DEVICE") }
        rejects { try SigningProfileRules.validateDevice(profileData: development, deviceID: nil) }
        try SigningProfileRules.validateDevice(profileData: cms(["ProvisionsAllDevices": true]), deviceID: nil)
        rejects { try SigningProfileRules.validateDevice(profileData: cms(["ProvisionedDevices": []]), deviceID: nil) }
        rejects { try SigningProfileRules.validateDevice(profileData: cms(["Name": "App Store"]), deviceID: nil) }
        rejects { try SigningProfileRules.validateDevice(profileData: Data("invalid".utf8), deviceID: nil) }
        print("SigningProfileRules regression tests passed.")
    }
}
