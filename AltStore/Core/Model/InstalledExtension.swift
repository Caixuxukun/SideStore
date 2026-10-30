//
//  InstalledExtension.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import SideSign

@objc(InstalledExtension)
public class InstalledExtension: BaseEntity, InstalledAppProtocol
{
    /* Properties */
    @NSManaged public var name: String
    @NSManaged public var bundleIdentifier: String
    @NSManaged public var resignedBundleIdentifier: String
    @NSManaged public var customBundleIdentifier: String?
    @NSManaged public var version: String
    
    @NSManaged public var refreshedDate: Date
    @NSManaged public var expirationDate: Date
    @NSManaged public var installedDate: Date
    
    /* Relationships */
    @NSManaged public var parentApp: InstalledApp?
    
    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }
    
    public init(resignedAppExtensionBundle: ALTApplication, originalBundleIdentifier: String, context: NSManagedObjectContext) throws
    {
        super.init(entity: InstalledExtension.entity(), insertInto: context)
        
        self.bundleIdentifier = originalBundleIdentifier
        
        self.refreshedDate = Date()
        self.installedDate = Date()
        
        #if targetEnvironment(simulator)
        self.expirationDate = self.refreshedDate.addingTimeInterval(60 * 60 * 24 * 7)
        #else
        // Some installers (ESign, iloader, SideInstaller, ...) only provision the main app,
        // leaving extensions without their own embedded profile. The extension is still
        // covered by the enclosing app's profile in that case, so inherit it instead of
        // refusing to launch.
        let profileURLs = ProvisioningProfileLocator.candidateProfileURLs(for: resignedAppExtensionBundle.fileURL)
        guard let effectiveProfile = profileURLs.compactMap({ try? ALTProvisioningProfile(url: $0) }).first else {
            throw ALTError.invalidApp(reason: "The app extension is missing a valid provisioning profile.")
        }
        if resignedAppExtensionBundle.provisioningProfile == nil {
            debugLog("[InstalledExtension] '\(resignedAppExtensionBundle.bundleIdentifier)' has no embedded provisioning profile; using the enclosing app's profile.")
        }
        self.refreshedDate = effectiveProfile.creationDate
        self.expirationDate = effectiveProfile.expirationDate
        #endif
        
        self.update(resignedAppExtensionBundle: resignedAppExtensionBundle)
    }
    
    public func update(resignedAppExtensionBundle: ALTApplication)
    {
        self.name = resignedAppExtensionBundle.name
        
        self.resignedBundleIdentifier = resignedAppExtensionBundle.bundleIdentifier
        self.version = resignedAppExtensionBundle.version

        if let provisioningProfile = resignedAppExtensionBundle.provisioningProfile
        {
            self.update(provisioningProfile: provisioningProfile)
        }
    }
    
    public func update(provisioningProfile: ALTProvisioningProfile)
    {
        self.refreshedDate = provisioningProfile.creationDate
        self.expirationDate = provisioningProfile.expirationDate
    }
    
    public var directoryURL: URL {
        if let parentApp = self.parentApp {
            return parentApp.directoryURL
        }
        return InstalledApp.appsDirectoryURL.appendingPathComponent(self.resignedBundleIdentifier)
    }
}

public extension InstalledExtension
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<InstalledExtension>
    {
        return NSFetchRequest<InstalledExtension>(entityName: "InstalledExtension")
    }
}
