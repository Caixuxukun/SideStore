//
//  DylibInjectionView.swift
//  SideStore
//
//  Per-app picker for dylibs that should be injected while signing the app.
//

import SwiftUI
import UniformTypeIdentifiers

struct DylibInjectionView: View {
    let appBundleID: String
    let appName: String

    @Environment(\.dismiss) private var dismiss
    @State private var tweaks: [InjectedTweak] = []
    @State private var selection: Set<String> = []
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var dylibType: UTType {
        UTType(filenameExtension: "dylib") ?? .data
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(tweaks) { tweak in
                        SwiftUI.Button {
                            toggle(tweak)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tweak.displayName)
                                        .foregroundColor(.primary)
                                    Text(tweak.filename)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: selection.contains(tweak.filename) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selection.contains(tweak.filename) ? .accentColor : .secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteTweaks)

                    if tweaks.isEmpty {
                        Text("No dylibs imported yet. Tap Import to add a .dylib.")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Imported Dylibs")
                } footer: {
                    Text("Selected dylibs are copied into the app's Frameworks folder and loaded when SideStore signs it. Import libellekit.dylib and select it together with a tweak to satisfy ElleKit-based tweaks.")
                }
            }
            .navigationTitle("Dylib Injection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    SwiftUI.Button("Import") { isImporting = true }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [dylibType],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    var failures: [String] = []
                    for url in urls {
                        do {
                            let tweak = try TweaksManager.shared.importTweak(from: url)
                            selection.insert(tweak.filename)
                        } catch {
                            failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    TweaksManager.shared.setSelectedTweaks(selection, forAppBundleID: appBundleID)
                    reload()
                    if !failures.isEmpty {
                        errorMessage = failures.joined(separator: "\n")
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Dylib Import", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                SwiftUI.Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: reload)
        }
        .navigationViewStyle(.stack)
    }

    private func reload() {
        tweaks = TweaksManager.shared.allTweaks()
        selection = TweaksManager.shared.selectedTweaks(forAppBundleID: appBundleID)
    }

    private func toggle(_ tweak: InjectedTweak) {
        if selection.contains(tweak.filename) {
            selection.remove(tweak.filename)
        } else {
            selection.insert(tweak.filename)
        }
        TweaksManager.shared.setSelectedTweaks(selection, forAppBundleID: appBundleID)
    }

    private func deleteTweaks(at offsets: IndexSet) {
        for index in offsets {
            let tweak = tweaks[index]
            TweaksManager.shared.deleteTweak(tweak)
            selection.remove(tweak.filename)
        }
        TweaksManager.shared.setSelectedTweaks(selection, forAppBundleID: appBundleID)
        reload()
    }
}
