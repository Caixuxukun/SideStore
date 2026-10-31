import Foundation
import SideSign
import CodeSignKit

/// Signs with imported profiles while retaining their original Apple-signed CMS bytes.
/// This path needs proper testing on devices with development, Ad Hoc and enterprise profiles.
enum ImportedProfileSigner {
    static func sign(at url: URL, certificate: ALTCertificate,
                     profiles: [String: ALTProvisioningProfile]) throws {
        guard let app = ALTApplication(fileURL: url) else {
            throw OperationError.invalidApp(reason: "Cannot read the app to sign.")
        }
        var entitlementsByBundle: [URL: String] = [:]
        for bundle in [app] + app.appExtensions {
            guard let profile = profiles[bundle.bundleIdentifier] else {
                throw OperationError.missingProvisioningProfile(reason: "No imported profile for '\(bundle.bundleIdentifier)'.")
            }
            try ProfileManager.shared.validate(profile, certificate: certificate, bundleID: bundle.bundleIdentifier, allowBundleIDMismatch: true)
            // Keep the app's own Bundle ID and embed the profile's application identifier, which is
            // what Feather-style installers do. iOS checks the entitlements against the profile.
            let entitlements = SigningProfileRules.profileEntitlements(profile.entitlements, bundleID: bundle.bundleIdentifier)
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            guard let xml = String(data: data, encoding: .utf8) else {
                throw OperationError.invalidParameters("Cannot encode signing entitlements.")
            }
            entitlementsByBundle[bundle.fileURL.resolvingSymlinksInPath()] = xml
            try profile.data.write(to: bundle.fileURL.appendingPathComponent("embedded.mobileprovision"), options: .atomic)
        }

        let root = url.resolvingSymlinksInPath()
        let entitlements = entitlementsByBundle
        try CodeSigner.sign(
            appPath: url.path,
            keyData: try certificate.exportP12(),
            entitlementProvider: { path in
                let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.isEmpty { return entitlements[root] ?? "" }
                let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
                    .resolvingSymlinksInPath()
                // Frameworks and dylibs do not inherit app entitlements.
                if target.pathExtension == "dylib" || target.pathComponents.contains(where: { $0.hasSuffix(".framework") }) {
                    return ""
                }
                let match = entitlements.keys
                    .filter { target == $0 || target.path.hasPrefix($0.path + "/") }
                    .max { $0.path.count < $1.path.count }
                return match.flatMap { entitlements[$0] } ?? ""
            },
            progress: {}
        )
    }
}
