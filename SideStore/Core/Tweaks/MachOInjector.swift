//
//  MachOInjector.swift
//  SideStore
//
//  Adds an LC_LOAD_DYLIB command to a thin 64-bit Mach-O executable by writing into the
//  zero padding that exists between the load commands and the first section. No bytes are
//  shifted, so every existing offset stays valid; the code signature is rebuilt afterwards
//  by the signer.
//

import Foundation

enum MachOInjector {
    enum InjectionError: LocalizedError {
        case unsupportedFormat(String)
        case insufficientHeaderPadding(available: Int, needed: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let reason):
                return "Cannot inject dylib: \(reason)"
            case .insufficientHeaderPadding(let available, let needed):
                return "Not enough Mach-O header padding to inject a dylib (\(available) bytes available, \(needed) needed)."
            }
        }
    }

    private static let machHeaderSize = 32
    private static let magic64: UInt32 = 0xFEED_FACF
    private static let lcSegment64: UInt32 = 0x19
    private static let lcLoadDylib: UInt32 = 0x0C
    private static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    private static let lcReexportDylib: UInt32 = 0x8000_001F
    private static let lcSegment64SectionSize = 80
    private static let lcSegment64SectionsOffset = 72

    static func addLoadDylibCommand(to binaryURL: URL, dylibPath: String) throws {
        var data = try Data(contentsOf: binaryURL)

        func readUInt32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        func writeUInt32(_ offset: Int, _ value: UInt32) {
            guard offset + 4 <= data.count else { return }
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        }

        guard data.count >= machHeaderSize else {
            throw InjectionError.unsupportedFormat("the executable is too small")
        }
        guard readUInt32(0) == magic64 else {
            throw InjectionError.unsupportedFormat("only thin 64-bit Mach-O executables are supported")
        }

        let commandCount = Int(readUInt32(16))
        let commandBytes = Int(readUInt32(20))
        var commandOffset = machHeaderSize
        var firstSectionOffset = Int.max

        for _ in 0..<commandCount {
            guard commandOffset + 8 <= data.count else {
                throw InjectionError.unsupportedFormat("the load commands are truncated")
            }
            let command = readUInt32(commandOffset)
            let commandSize = Int(readUInt32(commandOffset + 4))
            guard commandSize >= 8, commandOffset + commandSize <= data.count else {
                throw InjectionError.unsupportedFormat("a load command has an invalid size")
            }

            if command == lcLoadDylib || command == lcLoadWeakDylib || command == lcReexportDylib {
                let nameOffset = Int(readUInt32(commandOffset + 8))
                if nameOffset >= 8, nameOffset < commandSize {
                    let nameRange = (commandOffset + nameOffset)..<(commandOffset + commandSize)
                    if let existingPath = String(bytes: data[nameRange], encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                       existingPath == dylibPath {
                        // Already injected, for example when re-signing an installed app.
                        return
                    }
                }
            }

            if command == lcSegment64 {
                let sectionCount = Int(readUInt32(commandOffset + 64))
                let sectionsStart = commandOffset + lcSegment64SectionsOffset
                if sectionCount > 0, sectionsStart + sectionCount * lcSegment64SectionSize <= commandOffset + commandSize {
                    for index in 0..<sectionCount {
                        let sectionOffset = sectionsStart + index * lcSegment64SectionSize
                        let fileOffset = Int(readUInt32(sectionOffset + 48))
                        if fileOffset > 0 {
                            firstSectionOffset = min(firstSectionOffset, fileOffset)
                        }
                    }
                }
            }

            commandOffset += commandSize
        }

        guard firstSectionOffset != Int.max else {
            throw InjectionError.unsupportedFormat("no section offsets were found")
        }

        var pathBytes = Array(dylibPath.utf8)
        pathBytes.append(0)
        let unpaddedSize = 24 + pathBytes.count
        let commandSize = (unpaddedSize + 7) / 8 * 8
        pathBytes.append(contentsOf: repeatElement(0, count: commandSize - unpaddedSize))

        var command = Data(capacity: commandSize)
        let headerFields: [UInt32] = [lcLoadDylib, UInt32(commandSize), 24, 0, 0, 0]
        for value in headerFields {
            command.append(UInt8(value & 0xFF))
            command.append(UInt8((value >> 8) & 0xFF))
            command.append(UInt8((value >> 16) & 0xFF))
            command.append(UInt8((value >> 24) & 0xFF))
        }
        command.append(contentsOf: pathBytes)

        let insertOffset = machHeaderSize + commandBytes
        let available = firstSectionOffset - insertOffset
        guard available >= command.count else {
            throw InjectionError.insufficientHeaderPadding(available: max(0, available), needed: command.count)
        }

        data.replaceSubrange(insertOffset..<(insertOffset + command.count), with: command)
        writeUInt32(16, UInt32(commandCount + 1))
        writeUInt32(20, UInt32(commandBytes + command.count))

        try data.write(to: binaryURL, options: .atomic)
    }
}
