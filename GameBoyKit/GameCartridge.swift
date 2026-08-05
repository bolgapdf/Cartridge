//
//  GameCartridge.swift
//  GameBoyKit
//

import Foundation

/// A loaded game: the header, the ROM image, and the mapper chip that was
/// soldered onto the board next to it.
///
/// Named `GameCartridge` rather than `Cartridge` because the application module
/// is itself called Cartridge, and a type sharing its module's name turns every
/// qualified reference into a guessing game.
public final class GameCartridge {

    /// The 80 bytes at 0x0100 that describe the board.
    ///
    /// The console itself barely reads this — the boot ROM checks the logo and
    /// the checksum and nothing else. It matters here because it's the only way
    /// to know which mapper to emulate.
    public struct Header: Sendable, Equatable {
        public let title: String
        public let typeCode: UInt8
        public let romBanks: Int
        public let ramBytes: Int
        public let hasBattery: Bool
        /// Set on cartridges that use Game Boy Color features. They still run
        /// here — CGB games almost all fall back to a DMG-compatible mode — but
        /// the extra colours won't appear.
        public let supportsColor: Bool
        public let mapperName: String

        public var description: String {
            "\(title.isEmpty ? "Untitled" : title) · \(mapperName) · "
            + "\(romBanks * 16) KB ROM"
            + (ramBytes > 0 ? " · \(ramBytes / 1024) KB RAM" : "")
            + (hasBattery ? " · battery" : "")
        }
    }

    public let header: Header
    private let mapper: Mapper

    public init(rom: [UInt8]) throws {
        // 0x0150 is the end of the header. Anything shorter can't be a ROM, and
        // parsing it would read past the end of the array.
        guard rom.count >= 0x0150 else { throw SystemError.romTooSmall }

        let header = try Self.parseHeader(rom)
        self.header = header
        self.mapper = try Self.makeMapper(for: header, rom: rom)
    }

    // MARK: - Bus access

    /// 0x0000–0x7FFF.
    @inline(__always)
    func read(_ address: UInt16) -> UInt8 { mapper.readROM(address) }

    /// 0xA000–0xBFFF.
    @inline(__always)
    func readRAM(_ address: UInt16) -> UInt8 { mapper.readRAM(address) }

    @inline(__always)
    func writeRAM(_ address: UInt16, _ value: UInt8) { mapper.writeRAM(address, value) }

    /// Writes into ROM space don't store anything — they're how the program
    /// talks to the mapper chip, which is wired to watch the address bus.
    @inline(__always)
    func writeControl(_ address: UInt16, _ value: UInt8) { mapper.writeControl(address, value) }

    // MARK: - Persistence

    /// Cartridge RAM, when there's a battery on the board to have kept it.
    ///
    /// Without a battery the RAM is genuinely volatile — the game expects to
    /// find garbage in it at power-on — so persisting it would be wrong rather
    /// than merely wasteful.
    public var batteryRAM: [UInt8]? {
        get { header.hasBattery ? mapper.ram : nil }
        set {
            guard header.hasBattery, let newValue, newValue.count == mapper.ram.count else { return }
            mapper.ram = newValue
        }
    }

    var state: MapperState {
        get { mapper.state }
        set { mapper.state = newValue }
    }

    // MARK: - Header parsing

    private static func parseHeader(_ rom: [UInt8]) throws -> Header {
        // The title field ran into the fields that came after it as the format
        // grew: later cartridges use its last five bytes for a manufacturer
        // code and the colour flag. Stopping at the first non-printable byte
        // handles both eras without needing to know which one this is.
        let titleBytes = rom[0x0134..<0x0144].prefix { $0 >= 0x20 && $0 < 0x7F }
        let title = String(decoding: titleBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        let typeCode = rom[0x0147]

        // ROM size is a power-of-two count of 16 KB banks. The handful of
        // "1.1/1.2/1.5 MB" codes in the docs were never produced.
        let sizeCode = rom[0x0148]
        guard sizeCode <= 0x08 else {
            throw SystemError.unsupportedCartridge(
                String(format: "ROM size code %02X", sizeCode)
            )
        }
        let romBanks = 2 << Int(sizeCode)

        let ramBytes: Int
        switch rom[0x0149] {
        case 0x00: ramBytes = 0
        // Code 1 meant 2 KB and appears in no released game; treating it as a
        // full bank costs 6 KB and avoids a special case in every mapper.
        case 0x01, 0x02: ramBytes = 8 * 1024
        case 0x03: ramBytes = 32 * 1024
        case 0x04: ramBytes = 128 * 1024
        case 0x05: ramBytes = 64 * 1024
        default: ramBytes = 0
        }

        let batteryTypes: Set<UInt8> = [
            0x03, 0x06, 0x09, 0x0D, 0x0F, 0x10, 0x13, 0x1B, 0x1E, 0x22, 0xFF,
        ]

        return Header(
            title: title,
            typeCode: typeCode,
            romBanks: romBanks,
            ramBytes: ramBytes,
            hasBattery: batteryTypes.contains(typeCode),
            supportsColor: rom[0x0143] & 0x80 != 0,
            mapperName: mapperName(for: typeCode)
        )
    }

    private static func mapperName(for typeCode: UInt8) -> String {
        switch typeCode {
        case 0x00, 0x08, 0x09: "ROM only"
        case 0x01...0x03: "MBC1"
        case 0x05, 0x06: "MBC2"
        case 0x0F...0x13: "MBC3"
        case 0x19...0x1E: "MBC5"
        default: String(format: "type %02X", typeCode)
        }
    }

    private static func makeMapper(for header: Header, rom: [UInt8]) throws -> Mapper {
        // MBC2's RAM is built into the chip rather than described by the header,
        // so it's the one mapper whose size isn't read from 0x0149.
        switch header.typeCode {
        case 0x00, 0x08, 0x09:
            return NoMapper(rom: rom, ramBytes: header.ramBytes)
        case 0x01...0x03:
            return MBC1(rom: rom, banks: header.romBanks, ramBytes: header.ramBytes)
        case 0x05, 0x06:
            return MBC2(rom: rom, banks: header.romBanks)
        case 0x0F...0x13:
            return MBC3(rom: rom, banks: header.romBanks, ramBytes: header.ramBytes)
        case 0x19...0x1E:
            return MBC5(rom: rom, banks: header.romBanks, ramBytes: header.ramBytes)
        default:
            throw SystemError.unsupportedCartridge(
                String(format: "mapper type %02X", header.typeCode)
            )
        }
    }
}
