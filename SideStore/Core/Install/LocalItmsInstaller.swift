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
import SafariServices
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

        let host = Self.candidateHosts().first ?? "127.0.0.1"
        let baseURL = "http://\(host):\(server.port)"
        let payloadURL = "\(baseURL)/itms.ipa"
        self.server = server

        let startedKeepAlive = !UserDefaults.standard.isBackgroundServiceEnabled && BackgroundAudioService.shared.start()
        self.beginBackgroundTask()
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            server.stop()
            self.server = nil
            self.endBackgroundTask()
            if startedKeepAlive {
                BackgroundAudioService.shared.stop()
            }
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
        }

        // iOS 18+ blocks itms-services launched directly by third-party apps without special
        // entitlements. Follow Feather: host the manifest on a public HTTPS endpoint and let a local
        // HTML page inside a Safari view redirect to itms-services. Needs proper testing.
        guard let manifestURL = Self.externalManifestURL(
            bundleIdentifier: bundleIdentifier,
            version: version,
            title: displayName,
            payloadURL: payloadURL
        ) else {
            throw InstallError.cannotOpenInstallURL
        }
        let itmsURL = "itms-services://?action=download-manifest&url=\(Self.percentEncode(manifestURL))"
        server.installPageHTML = Self.installPageHTML(itmsURL: itmsURL)

        guard let pageURL = URL(string: "\(baseURL)/install.html") else {
            throw InstallError.cannotOpenInstallURL
        }
        guard await Self.presentInstallPage(pageURL) else {
            throw InstallError.installURLRejected
        }

        try await server.waitForDownload(timeout: 600)
        // installd still has to verify and move the app into place after the download finishes.
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }

    private static func externalManifestURL(bundleIdentifier: String,
                                            version: String,
                                            title: String,
                                            payloadURL: String) -> String? {
        var components = URLComponents(string: "https://api.palera.in/genPlist")
        components?.queryItems = [
            URLQueryItem(name: "bundleid", value: bundleIdentifier),
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "fetchurl", value: payloadURL)
        ]
        return components?.url?.absoluteString
    }

    private static func installPageHTML(itmsURL: String) -> Data {
        let escaped = itmsURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script>window.location.href = "\(escaped)";</script>
        </head>
        <body style="background:#000;color:#fff;font-family:-apple-system;padding:24px">
        Starting installation…
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    @MainActor
    private static func presentInstallPage(_ url: URL) async -> Bool {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else {
            return await Self.open(url)
        }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }

        // Presenting on an alert (or a controller that is already presenting) throws an ObjC
        // exception, so fall back to Safari when another presentation is in flight.
        guard !(top is UIAlertController), top.presentedViewController == nil else {
            return await Self.open(url)
        }

        let safari = SFSafariViewController(url: url)
        top.present(safari, animated: true)
        return true
    }

    private static func candidateHosts() -> [String] {
        var wifiAddress: String?
        var cellularAddress: String?

        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer {
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

                // Feather only advertises en0/pdp_ip0: VPN/utun addresses are not reachable by installd.
                if name == "en0" {
                    wifiAddress = wifiAddress ?? candidate
                } else if name == "pdp_ip0" {
                    cellularAddress = cellularAddress ?? candidate
                }
            }
        }

        var hosts: [String] = []
        for host in [wifiAddress, cellularAddress, "127.0.0.1"].compactMap({ $0 }) where !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
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
    var installPageHTML = Data()

    init(ipaURL: URL) {
        self.ipaURL = ipaURL
    }

    deinit {
        stop()
    }

    func start() throws {
        // installd aborts some HTTP requests early; never let the resulting SIGPIPE kill SideStore.
        signal(SIGPIPE, SIG_IGN)

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

        // Without this, a client that closes early (installd does a HEAD first) makes send()
        // raise SIGPIPE, which kills SideStore in the middle of the install.
        var noSigPipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

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
        let headerLines = header.components(separatedBy: "\r\n")
        let requestLine = headerLines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        var requestHeaders: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                requestHeaders[name] = value
            }
        }

        switch path {
        case "/install.html":
            sendResponse(clientFD, method: method, status: "200 OK", contentType: "text/html; charset=utf-8", body: installPageHTML)
        case "/itms.ipa":
            sendIPA(clientFD, method: method, headers: requestHeaders)
        default:
            sendResponse(clientFD, method: method, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    private func sendResponse(_ clientFD: Int32, method: String, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        if method != "HEAD" {
            responseData.append(body)
        }
        _ = sendAll(clientFD, responseData)
    }

    private func sendIPA(_ clientFD: Int32, method: String, headers: [String: String]) {
        guard let fileData = try? Data(contentsOf: ipaURL, options: .mappedIfSafe) else {
            sendResponse(clientFD, method: method, status: "404 Not Found", contentType: "text/plain", body: Data("Missing IPA".utf8))
            return
        }

        let total = fileData.count
        var start = 0
        var end = total - 1
        var isPartial = false

        if let rangeHeader = headers["range"]?.lowercased(), rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if spec.count == 2 {
                let startText = String(spec[0]).trimmingCharacters(in: .whitespaces)
                let endText = String(spec[1]).trimmingCharacters(in: .whitespaces)
                if startText.isEmpty {
                    if let suffix = Int(endText) {
                        start = max(0, total - suffix)
                        end = total - 1
                        isPartial = true
                    }
                } else if let requestedStart = Int(startText) {
                    start = max(0, min(requestedStart, total - 1))
                    end = endText.isEmpty ? total - 1 : max(start, min(Int(endText) ?? total - 1, total - 1))
                    isPartial = true
                }
            }
        }

        let length = end - start + 1
        var header = "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\n"
        if isPartial {
            header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        guard sendAll(clientFD, Data(header.utf8)) else { return }
        guard method != "HEAD" else { return }

        guard sendSlice(clientFD, data: fileData, start: start, length: length) else { return }
        if end == total - 1 {
            downloadState.markCompleted()
        }
    }

    @discardableResult
    private func sendSlice(_ socketFD: Int32, data: Data, start: Int, length: Int) -> Bool {
        guard length > 0 else { return true }
        let end = start + length
        var sent = start

        let success: Bool = data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return true }
            while sent < end {
                let written = send(socketFD, baseAddress.advanced(by: sent), end - sent, 0)
                if written <= 0 {
                    return false
                }
                sent += written
            }
            return true
        }
        return success
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
