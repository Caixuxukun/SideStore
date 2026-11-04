//
//  TweaksManager.swift
//  SideStore
//
//  Stores imported dylibs and remembers which ones should be injected into each app.
//  Injection copies the dylib into the app's Frameworks folder and adds an LC_LOAD_DYLIB
//  load command, so the tweak (and ElleKit, when selected) loads inside the signed app.
//

import Foundation

struct InjectedTweak: Identifiable, Hashable, Sendable {
    let filename: String
    let displayName: String
    let fileSize: Int64

    var id: String { filename }
}

enum TweaksError: LocalizedError {
    case invalidFile
    case missingSource(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Only .dylib files can be imported."
        case .missingSource(let name):
            return "The imported dylib '\(name)' is no longer available."
        }
    }
}

final class TweaksManager: @unchecked Sendable {
    static let shared = TweaksManager()

    private let defaults = UserDefaults.standard
    private let selectionKey = "dylibInjectionSelectionByApp"

    private init() {
        try? FileManager.default.createDirectory(at: tweaksDirectory, withIntermediateDirectories: true)
    }

    var tweaksDirectory: URL {
        FileManager.default.applicationSupportDirectory.appendingPathComponent("InjectedTweaks", isDirectory: true)
    }

    func allTweaks() -> [InjectedTweak] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: tweaksDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "dylib" }
            .compactMap { url -> InjectedTweak? in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return InjectedTweak(
                    filename: url.lastPathComponent,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    fileSize: Int64(size)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    func importTweak(from url: URL) throws -> InjectedTweak {
        guard url.pathExtension.lowercased() == "dylib" else {
            throw TweaksError.invalidFile
        }

        try FileManager.default.createDirectory(at: tweaksDirectory, withIntermediateDirectories: true)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = tweaksDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        debugLog("[TweaksManager] Imported dylib '\(url.lastPathComponent)' (\(size) bytes).")
        return InjectedTweak(
            filename: destination.lastPathComponent,
            displayName: destination.deletingPathExtension().lastPathComponent,
            fileSize: Int64(size)
        )
    }

    func deleteTweak(_ tweak: InjectedTweak) {
        let url = tweaksDirectory.appendingPathComponent(tweak.filename)
        try? FileManager.default.removeItem(at: url)

        let selection = selectionByApp()
        var updated: [String: [String]] = [:]
        for (appID, filenames) in selection {
            updated[appID] = filenames.filter { $0 != tweak.filename }
        }
        saveSelection(updated)
        debugLog("[TweaksManager] Deleted dylib '\(tweak.filename)'.")
    }

    func selectedTweaks(forAppBundleID appBundleID: String) -> Set<String> {
        Set(selectionByApp()[appBundleID] ?? [])
    }

    func setSelectedTweaks(_ filenames: Set<String>, forAppBundleID appBundleID: String) {
        var selection = selectionByApp()
        selection[appBundleID] = filenames.sorted()
        saveSelection(selection)
    }

    /// Copies the selected dylibs into `App.app/Frameworks` and adds an LC_LOAD_DYLIB command for
    /// each one, so the signer picks them up and seals them into the app's code signature.
    func inject(into appBundleURL: URL, mainExecutableURL: URL, appBundleID: String) throws {
        let selected = selectedTweaks(forAppBundleID: appBundleID)
        guard !selected.isEmpty else { return }

        let frameworksURL = appBundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworksURL, withIntermediateDirectories: true)

        for filename in selected.sorted() {
            let source = tweaksDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: source.path) else {
                debugLog("[TweaksManager] Skipping '\(filename)': the imported file is missing.")
                continue
            }

            let destination = frameworksURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)

            try MachOInjector.addLoadDylibCommand(
                to: mainExecutableURL,
                dylibPath: "@executable_path/Frameworks/\(filename)"
            )
            debugLog("[TweaksManager] Injected '\(filename)' into '\(appBundleID)'.")
        }
    }

    private func selectionByApp() -> [String: [String]] {
        defaults.dictionary(forKey: selectionKey) as? [String: [String]] ?? [:]
    }

    private func saveSelection(_ selection: [String: [String]]) {
        defaults.set(selection, forKey: selectionKey)
    }
}
