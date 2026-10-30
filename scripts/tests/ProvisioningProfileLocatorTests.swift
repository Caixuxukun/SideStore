import Foundation

@main
struct ProvisioningProfileLocatorTests {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisioning-profile-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func createProfileFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("profile".utf8).write(to: url)
    }

    static func main() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        let appProfile = app.appendingPathComponent(ProvisioningProfileLocator.filename)
        let plugin = app.appendingPathComponent("PlugIns", isDirectory: true)
        let extensionBundle = plugin.appendingPathComponent("Widget.appex", isDirectory: true)
        let extensionProfile = extensionBundle.appendingPathComponent(ProvisioningProfileLocator.filename)

        try FileManager.default.createDirectory(at: extensionBundle, withIntermediateDirectories: true)

        // An extension without its own profile inherits the enclosing app's profile.
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: extensionBundle).isEmpty)
        try createProfileFile(at: appProfile)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: extensionBundle) == [appProfile])

        // A profile embedded in the extension itself wins over the inherited one.
        try createProfileFile(at: extensionProfile)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: extensionBundle) == [extensionProfile, appProfile])

        // A main app never inherits a profile from a parent directory.
        let standaloneApp = root.appendingPathComponent("Standalone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: standaloneApp, withIntermediateDirectories: true)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: standaloneApp).isEmpty)

        // Nested extensions (for example inside a watch app) prefer the innermost app.
        let watchApp = app
            .appendingPathComponent("Watch", isDirectory: true)
            .appendingPathComponent("ExampleWatch.app", isDirectory: true)
        let watchExtension = watchApp
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("WatchWidget.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: watchExtension, withIntermediateDirectories: true)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: watchExtension) == [appProfile])

        let watchProfile = watchApp.appendingPathComponent(ProvisioningProfileLocator.filename)
        try createProfileFile(at: watchProfile)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: watchExtension) == [watchProfile, appProfile])

        // Non-extension bundles only ever use their own profile.
        let framework = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("ExampleKit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: framework).isEmpty)

        let frameworkProfile = framework.appendingPathComponent(ProvisioningProfileLocator.filename)
        try createProfileFile(at: frameworkProfile)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: framework) == [frameworkProfile])

        // A bundle outside any app bundle has nothing to inherit.
        let looseExtension = root
            .appendingPathComponent("Loose", isDirectory: true)
            .appendingPathComponent("Loose.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: looseExtension, withIntermediateDirectories: true)
        assert(ProvisioningProfileLocator.candidateProfileURLs(for: looseExtension).isEmpty)

        print("ProvisioningProfileLocator tests passed")
    }
}
