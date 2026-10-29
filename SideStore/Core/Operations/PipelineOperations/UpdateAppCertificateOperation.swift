//
//  UpdateAppCertificateOperation.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

final class UpdateAppCertificateOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[UpdateAppCertificateOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[UpdateAppCertificateOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let targetBundleID = self.context.installedApp?.bundleIdentifier ?? self.context.targetBundleIdentifier
        let profileToUse = self.context.overrideProvisioningProfile ?? ProfileManager.shared.getAssignedProfile(for: targetBundleID)

        if let assignedProfile = profileToUse {
            debugLog("[UpdateAppCertificateOperation] Target bundle '\(targetBundleID)' using assigned profile: '\(assignedProfile.name)' (\(assignedProfile.uuid))")
            self.context.overrideProvisioningProfile = assignedProfile

            if let matchingCert = ProfileManager.shared.getMatchingCertificate(for: assignedProfile) {
                debugLog("[UpdateAppCertificateOperation] Loaded matching certificate '\(matchingCert.serialNumber)' for assigned profile. Setting context.overrideSigningCertificate.")
                self.context.overrideSigningCertificate = matchingCert
            } else {
                throw OperationError.missingProvisioningProfile(reason: "Import the matching .p12 with private key for profile '\(assignedProfile.name)'.")
            }
        } else if let installedApp = self.context.installedApp, let serialNumber = installedApp.certificateSerialNumber {
            debugLog("[UpdateAppCertificateOperation] InstalledApp '\(installedApp.name)' has custom certificate serial: '\(serialNumber)'")
            if let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                debugLog("[UpdateAppCertificateOperation] Loaded custom certificate '\(customCert.serialNumber)' for app '\(installedApp.name)'. Setting context.overrideSigningCertificate.")
                self.context.overrideSigningCertificate = customCert
            } else {
                debugLog("[UpdateAppCertificateOperation] WARNING: Signable certificate with serial '\(serialNumber)' not found for app '\(installedApp.name)'.")
            }
        }
        
        if self.context.overrideProvisioningProfile == nil,
           let certificate = self.context.targetSigningCertificate,
           let profile = ProfileManager.shared.matchingProfile(for: self.context.targetBundleIdentifier, certificate: certificate) {
            self.context.overrideProvisioningProfile = profile
        }
        if let profile = self.context.overrideProvisioningProfile,
           let certificate = self.context.targetSigningCertificate {
            try ProfileManager.shared.validate(profile, certificate: certificate, bundleID: self.context.targetBundleIdentifier)
            self.context.appendTeamID = false
        }
        self.setProgress(100)
    }
}
