import Foundation

/// Rules shared by profile selection and signing. A wildcard is a permission,
/// never a concrete CFBundleIdentifier or application-identifier.
enum SigningProfileRules {
    struct InvalidProfile: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func matches(_ pattern: String, _ identifier: String) -> Bool {
        guard !identifier.isEmpty, !identifier.contains("*") else { return false }
        if !pattern.contains("*") { return pattern == identifier }
        guard pattern.last == "*", pattern.filter({ $0 == "*" }).count == 1 else { return false }
        let prefix = String(pattern.dropLast())
        return identifier.hasPrefix(prefix) && identifier.count > prefix.count
    }

    static func bundleIdentifier(profileID: String, requestedID: String) throws -> String {
        guard matches(profileID, requestedID) else {
            throw InvalidProfile(reason: "Profile '\(profileID)' does not allow bundle ID '\(requestedID)'. Select a matching profile or customize the app's bundle ID.")
        }
        return requestedID
    }

    static func validateDevice(profileData: Data, deviceID: String?) throws {
        guard let start = profileData.range(of: Data("<?xml".utf8)),
              let end = profileData.range(of: Data("</plist>".utf8), in: start.lowerBound..<profileData.endIndex),
              let plist = try PropertyListSerialization.propertyList(
                from: profileData[start.lowerBound..<end.upperBound], options: [], format: nil
              ) as? [String: Any] else {
            throw InvalidProfile(reason: "Cannot read device permissions from the profile.")
        }
        if plist["ProvisionsAllDevices"] as? Bool == true { return }
        guard let devices = plist["ProvisionedDevices"] as? [String], !devices.isEmpty else {
            throw InvalidProfile(reason: "This profile does not allow direct device installation. Import a development, Ad Hoc, or enterprise profile.")
        }
        guard let deviceID, devices.contains(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame }) else {
            throw InvalidProfile(reason: "This device is not included in the imported provisioning profile.")
        }
    }

    static func entitlements(profile: [String: any Sendable],
                             application: [String: any Sendable],
                             bundleID: String) throws -> [String: any Sendable] {
        guard let permittedAppID = profile["application-identifier"] as? String,
              let separator = permittedAppID.firstIndex(of: ".") else {
            throw InvalidProfile(reason: "The profile has no valid application-identifier.")
        }
        // App ID prefixes can differ from TeamIdentifier for older accounts.
        let prefix = String(permittedAppID[..<separator])
        let appID = prefix + "." + bundleID
        guard matches(permittedAppID, appID) else {
            throw InvalidProfile(reason: "The profile does not authorize '\(appID)'.")
        }

        var result: [String: any Sendable] = [:]
        for (key, allowed) in profile {
            if key == "application-identifier" {
                result[key] = appID
            } else if key == "com.apple.developer.team-identifier" || key == "get-task-allow" {
                result[key] = allowed
            } else if key == "keychain-access-groups" {
                guard let permitted = allowed as? [String] else { continue }
                let requested = application[key] as? [String] ?? [appID]
                let groups = try requested.map { group -> String in
                    guard let dot = group.firstIndex(of: ".") else {
                        throw InvalidProfile(reason: "Invalid keychain access group '\(group)'.")
                    }
                    let remapped = prefix + String(group[dot...])
                    guard permitted.contains(where: { matches($0, remapped) }) else {
                        throw InvalidProfile(reason: "The profile does not allow keychain access group '\(remapped)'.")
                    }
                    return remapped
                }
                result[key] = groups
            } else if let requested = application[key] {
                // Keep only capabilities authorized by the selected profile.
                // Arrays must be subsets; scalar/dictionary values must match.
                if let values = requested as? [String], let permitted = allowed as? [String] {
                    guard values.allSatisfy({ value in permitted.contains { matches($0, value) } }) else {
                        throw InvalidProfile(reason: "The profile does not allow the requested '\(key)' entitlement.")
                    }
                    result[key] = values
                } else if let value = requested as? String, let pattern = allowed as? String, matches(pattern, value) {
                    result[key] = value
                } else {
                    guard NSDictionary(dictionary: ["value": requested]).isEqual(to: ["value": allowed]) else {
                        throw InvalidProfile(reason: "The profile does not allow the requested '\(key)' entitlement.")
                    }
                    result[key] = requested
                }
            }
        }
        return result
    }
}
