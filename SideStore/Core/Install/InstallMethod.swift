//
//  InstallMethod.swift
//  SideStore
//
//  Selects how a resigned app is handed to the device.
//

import Foundation

public enum InstallMethod: String, CaseIterable, Identifiable, Sendable {
    /// Send the app over AFC and trigger the install through the minimuxer device API.
    case deviceAPI = "device-api"

    /// Serve the resigned IPA over loopback HTTP and let iOS install it from an itms-services
    /// manifest. No pairing/minimuxer connection is required, but SideStore must stay in the
    /// foreground while iOS downloads the IPA.
    case localItms = "local-itms"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deviceAPI:
            return "Device API"
        case .localItms:
            return "Local itms-services"
        }
    }

    public var detail: String {
        switch self {
        case .deviceAPI:
            return "Install through SideStore's pairing connection (current behavior)."
        case .localItms:
            return "Serve the IPA locally and let iOS install it. Keep SideStore open until the install finishes."
        }
    }
}

public extension UserDefaults {
    var installMethod: InstallMethod {
        get {
            guard let rawValue = self.string(forKey: "installMethod"),
                  let method = InstallMethod(rawValue: rawValue) else {
                return .deviceAPI
            }
            return method
        }
        set { self.set(newValue.rawValue, forKey: "installMethod") }
    }
}
