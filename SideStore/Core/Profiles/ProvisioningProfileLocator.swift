//
//  ProvisioningProfileLocator.swift
//  SideStore
//
//  Created by SideStore contributors.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

/// Locates the provisioning profiles that can authorize an app bundle.
///
/// App extensions normally embed their own `embedded.mobileprovision`, but some
/// installers (ESign, iloader, SideInstaller and similar tools) only sign and
/// provision the main app. The extension is then still installed, and in practice
/// it is covered by the main app's profile, so callers should fall back to the
/// enclosing `.app` bundle instead of treating the extension as invalid and
/// failing to launch.
///
/// This type intentionally depends on Foundation only so it can be compiled and
/// exercised by the standalone regression tests in `scripts/tests`.
enum ProvisioningProfileLocator {
    static let filename = "embedded.mobileprovision"

    /// Profile URLs to try, most specific first: the bundle's own profile, then
    /// the profile of each enclosing `.app` bundle (innermost app first).
    ///
    /// Only `.appex` bundles inherit a parent profile; a main app without a
    /// profile is genuinely invalid and is reported as such.
    static func candidateProfileURLs(for bundleURL: URL,
                                     fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = []

        let ownProfileURL = bundleURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: ownProfileURL.path) {
            candidates.append(ownProfileURL)
        }

        guard bundleURL.pathExtension.lowercased() == "appex" else {
            return candidates
        }

        var directory = bundleURL.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if directory.pathExtension.lowercased() == "app" {
                let profileURL = directory.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: profileURL.path) {
                    candidates.append(profileURL)
                }
            }

            let parentDirectory = directory.deletingLastPathComponent()
            guard parentDirectory.path != directory.path else { break }
            directory = parentDirectory
        }

        return candidates
    }
}
