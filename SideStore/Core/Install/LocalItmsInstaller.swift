#if !os(tvOS)
//
//  LocalItmsInstaller.swift
//  SideStore
//
//  Installs a resigned IPA through iOS's own installer: the IPA is served over loopback HTTP and
//  an itms-services manifest URL is opened, so installd downloads and installs the app without the
//  minimuxer/pairing connection. Needs proper testing across iOS versions.
//

import Foundation
import Network
import UIKit

final class LocalItmsInstaller: @unchecked Sendable {
    static let shared = LocalItmsInstaller()

    enum InstallError: LocalizedError {
        case ipaMissing
        case serverFailed(String)
        case cannotOpenInstallURL
        case installURLRejected
        case downloadTimedOut

        var errorDescription: String? {
            switch self {
            case .ipaMissing:
                return "The resigned IPA is missing, so the local installer has nothing to serve."
            case .serverFailed(let reason):
                return "Could not start the local install server: \(reason)"
            case .cannotOpenInstallURL:
                return "Could not build the itms-services install URL."
            case .installURLRejected:
                return "iOS refused to open the itms-services install URL."
            case .downloadTimedOut:
                return "iOS did not download the IPA from SideStore in time. Keep SideStore open while the install runs and try again."
            }
        }
    }

    private var server: LocalItmsHTTPServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func install(ipaURL: URL, bundleIdentifier: String, version: String, displayName: String) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw InstallError.ipaMissing
        }

        let server = LocalItmsHTTPServer(ipaURL: ipaURL)
        try server.start()
        server.manifestData = Self.manifestData(
            bundleIdentifier: bundleIdentifier,
            version: version,
            title: displayName,
            ipaURL: server.ipaServerURL
        )
        self.server = server

        self.beginBackgroundTask()
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            server.stop()
            self.server = nil
            self.endBackgroundTask()
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
        }

        let manifestURLString = Self.percentEncode(server.manifestURL.absoluteString)
        guard let installURL = URL(string: "itms-services://?action=download-manifest&id=\(bundleIdentifier)&url=\(manifestURLString)") else {
            throw InstallError.cannotOpenInstallURL
        }

        debugLog("[LocalItmsInstaller] Serving '\(ipaURL.lastPathComponent)' on 127.0.0.1:\(server.port) for \(bundleIdentifier).")
        guard await Self.open(installURL) else {
            throw InstallError.installURLRejected
        }

        try await server.waitForDownload(timeout: 600)
        debugLog("[LocalItmsInstaller] installd downloaded the IPA; waiting for the install to settle.")
        // installd still has to verify and move the app into place after the download finishes.
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }

    private static func manifestData(bundleIdentifier: String, version: String, title: String, ipaURL: URL) -> Data {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [
                    [
                        "kind": "software-package",
                        "url": ipaURL.absoluteString
                    ]
                ],
                "metadata": [
                    "bundle-identifier": bundleIdentifier,
                    "bundle-version": version,
                    "kind": "software",
                    "title": title
                ]
            ]]
        ]

        return (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=?")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func beginBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocalItmsInstall") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
}

/// Minimal HTTP/1.1 server that serves the itms manifest and the resigned IPA on 127.0.0.1.
final class LocalItmsHTTPServer: @unchecked Sendable {
    enum ServerError: LocalizedError {
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let reason):
                return reason
            }
        }
    }

    private final class DownloadState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        var isCompleted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        func markCompleted() {
            lock.lock()
            completed = true
            lock.unlock()
        }
    }

    private let ipaURL: URL
    private let queue = DispatchQueue(label: "io.sidestore.LocalItmsHTTPServer", qos: .userInitiated)
    private let downloadState = DownloadState()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var manifestData = Data()

    init(ipaURL: URL) {
        self.ipaURL = ipaURL
    }

    var manifestURL: URL {
        URL(string: "http://127.0.0.1:\(port)/manifest.plist")!
    }

    var ipaServerURL: URL {
        URL(string: "http://127.0.0.1:\(port)/itms.ipa")!
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init("127.0.0.1"), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        let deadline = Date().addingTimeInterval(5)
        while listener.port == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let boundPort = listener.port?.rawValue, boundPort != 0 else {
            listener.cancel()
            self.listener = nil
            throw ServerError.listenerFailed("The local installer could not bind a loopback port.")
        }
        port = boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func waitForDownload(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if downloadState.isCompleted {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LocalItmsInstaller.InstallError.downloadTimedOut
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(to: connection, requestHeader: header)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, accumulated: buffer)
        }
    }

    private func respond(to connection: NWConnection, requestHeader: String) {
        let requestLine = requestHeader.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        var path = String(parts[1])
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        switch path {
        case "/manifest.plist":
            send(connection, status: "200 OK", contentType: "application/xml", body: manifestData)
        case "/itms.ipa":
            sendFile(connection)
        default:
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendFile(_ connection: NWConnection) {
        guard let fileHandle = try? FileHandle(forReadingFrom: ipaURL) else {
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Missing IPA".utf8))
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path))?[.size] as? NSNumber
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(fileSize?.int64Value ?? 0)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            self.stream(connection, fileHandle: fileHandle)
        })
    }

    private func stream(_ connection: NWConnection, fileHandle: FileHandle) {
        let chunk: Data
        do {
            chunk = try fileHandle.read(upToCount: 512 * 1024) ?? Data()
        } catch {
            try? fileHandle.close()
            connection.cancel()
            return
        }

        if chunk.isEmpty {
            try? fileHandle.close()
            downloadState.markCompleted()
            connection.cancel()
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? fileHandle.close()
                connection.cancel()
                return
            }
            self.stream(connection, fileHandle: fileHandle)
        })
    }
}

#endif
