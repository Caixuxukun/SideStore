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
import UIKit
import Darwin

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
        let host = Self.preferredHost()
        let baseURL = "http://\(host):\(server.port)"
        server.manifestData = Self.manifestData(
            bundleIdentifier: bundleIdentifier,
            version: version,
            title: displayName,
            ipaURL: URL(string: "\(baseURL)/itms.ipa")!
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

        debugLog("[LocalItmsInstaller] Serving '\(ipaURL.lastPathComponent)' on \(baseURL) for \(bundleIdentifier).")
        let manifestURLString = Self.percentEncode("\(baseURL)/manifest.plist")
        guard let installURL = URL(string: "itms-services://?action=download-manifest&id=\(bundleIdentifier)&url=\(manifestURLString)") else {
            throw InstallError.cannotOpenInstallURL
        }

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

    private static func preferredHost() -> String {
        var wifiAddress: String?
        var otherAddress: String?

        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return "127.0.0.1"
        }
        defer { freeifaddrs(interfacePointer) }

        for interface in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address,
                                     socklen_t(address.pointee.sa_len),
                                     &hostname,
                                     socklen_t(hostname.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard result == 0 else { continue }

            let candidate = String(cString: hostname)
            guard !candidate.isEmpty, !candidate.hasPrefix("169.254.") else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            if name.hasPrefix("en") {
                wifiAddress = wifiAddress ?? candidate
            } else {
                otherAddress = otherAddress ?? candidate
            }
        }

        return wifiAddress ?? otherAddress ?? "127.0.0.1"
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
/// Uses plain BSD sockets because NWListener refused to bind a loopback endpoint on device.
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
    private let downloadState = DownloadState()
    private let connectionQueue = DispatchQueue(label: "io.sidestore.LocalItmsHTTPServer.connections", qos: .userInitiated, attributes: .concurrent)
    private var listeningSocket: Int32 = -1
    private var acceptThread: Thread?
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

    deinit {
        stop()
    }

    func start() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw ServerError.listenerFailed("socket() failed with errno \(errno)")
        }

        var reuse: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        // Listen on every interface: installd refused to reach 127.0.0.1 on some iOS versions, so
        // the manifest URL uses the device's own LAN address instead. Needs proper testing.
        address.sin_addr = in_addr(s_addr: 0)

        let bindResult: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(socketFD)
            throw ServerError.listenerFailed("bind() failed with errno \(code)")
        }

        guard listen(socketFD, 8) == 0 else {
            let code = errno
            close(socketFD)
            throw ServerError.listenerFailed("listen() failed with errno \(code)")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &boundLength)
            }
        }

        port = UInt16(bigEndian: boundAddress.sin_port)
        guard port != 0 else {
            close(socketFD)
            throw ServerError.listenerFailed("The local installer did not bind a loopback port.")
        }
        listeningSocket = socketFD

        let thread = Thread { [weak self] in
            self?.acceptConnections(on: socketFD)
        }
        thread.name = "io.sidestore.LocalItmsHTTPServer.accept"
        acceptThread = thread
        thread.start()
    }

    func stop() {
        let socketFD = listeningSocket
        listeningSocket = -1
        if socketFD >= 0 {
            close(socketFD)
        }
        acceptThread = nil
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

    private func acceptConnections(on socketFD: Int32) {
        while listeningSocket == socketFD {
            var clientAddress = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(socketFD, $0, &clientLength)
                }
            }

            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                break
            }

            connectionQueue.async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { close(clientFD) }

        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let headerTerminator = Data("\r\n\r\n".utf8)

        while requestData.range(of: headerTerminator) == nil {
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                recv(clientFD, raw.baseAddress, raw.count, 0)
            }
            guard received > 0 else { return }
            requestData.append(contentsOf: buffer[0..<received])
            if requestData.count > 64 * 1024 { return }
        }

        guard let headerEnd = requestData.range(of: headerTerminator) else { return }
        let header = String(decoding: requestData[..<headerEnd.lowerBound], as: UTF8.self)
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        var path = String(parts[1])
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        switch path {
        case "/manifest.plist":
            _ = sendAll(clientFD, response(status: "200 OK", contentType: "application/xml", body: manifestData))
        case "/itms.ipa":
            sendIPA(clientFD)
        default:
            _ = sendAll(clientFD, response(status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8)))
        }
    }

    private func response(status: String, contentType: String, body: Data) -> Data {
        var responseData = Data()
        responseData.append(Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        responseData.append(body)
        return responseData
    }

    private func sendIPA(_ clientFD: Int32) {
        guard let fileData = try? Data(contentsOf: ipaURL, options: .mappedIfSafe) else {
            _ = sendAll(clientFD, response(status: "404 Not Found", contentType: "text/plain", body: Data("Missing IPA".utf8)))
            return
        }

        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(fileData.count)\r\nConnection: close\r\n\r\n".utf8)
        guard sendAll(clientFD, header) else { return }
        guard sendAll(clientFD, fileData) else { return }
        downloadState.markCompleted()
    }

    @discardableResult
    private func sendAll(_ socketFD: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var sent = 0
        let total = data.count

        let success: Bool = data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return true }
            while sent < total {
                let written = send(socketFD, baseAddress.advanced(by: sent), total - sent, 0)
                if written <= 0 {
                    return false
                }
                sent += written
            }
            return true
        }
        return success
    }
}

#endif
