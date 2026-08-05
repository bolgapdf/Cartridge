//
//  SM83SuiteTests.swift
//  GameBoyKitTests
//

import Testing
import Foundation

// The kit's sources are compiled straight into this target rather than linked
// as a module, so there's nothing to import — same arrangement the app uses.

/// Runs the CPU against the SingleStepTests SM83 suite.
///
/// Each case gives an exact starting state — every register, the flags, the
/// interrupt flag, and the bytes in memory — and the exact state afterwards.
/// That makes "is the CPU correct" an objective question rather than a matter
/// of whether some game happens to boot, which is the usual and much weaker
/// standard for an emulator.
///
/// Fetch the suite with `./scripts/fetch-tests.sh`; it isn't committed.
struct SM83Suite {

    // MARK: - Fixtures

    /// Flat 64 KB of memory, which is what the suite assumes: no cartridge, no
    /// hardware registers, no mirroring.
    final class FlatMemory: Bus {
        var bytes = [UInt8](repeating: 0, count: 0x10000)
        /// Every access in order, for comparing against the expected cycle count.
        private(set) var accesses = 0

        func read(_ address: UInt16) -> UInt8 {
            accesses += 1
            return bytes[Int(address)]
        }

        func write(_ address: UInt16, _ value: UInt8) {
            accesses += 1
            bytes[Int(address)] = value
        }
    }

    struct Case: Decodable {
        struct State: Decodable {
            let pc: UInt16
            let sp: UInt16
            let a, b, c, d, e, f, h, l: UInt8
            let ime: UInt8?
            let ie: UInt8?
            /// `[address, value]` pairs.
            let ram: [[Int]]
        }

        let name: String
        let initial: State
        let final: State
        /// One entry per M-cycle of bus activity.
        let cycles: [[JSONValue]]
    }

    /// The cycle entries mix numbers and strings, so they're decoded loosely —
    /// only the count is used.
    enum JSONValue: Decodable {
        case number(Int), string(String), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Int.self) { self = .number(value) }
            else { self = .string(try container.decode(String.self)) }
        }
    }

    // MARK: - Loading

    static let suiteDirectory: URL? = {
        // Resources are copied next to the test bundle.
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: "sm83", withExtension: nil) { return url }

        // Falling back to the source tree keeps this working when the bundle
        // hasn't picked the folder up.
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Resources/sm83")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }()

    private final class BundleToken {}

    static func opcodeFiles() throws -> [URL] {
        guard let directory = suiteDirectory else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func cases(in file: URL) throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
    }

    // MARK: - Running

    /// Runs one case and returns a description of the first mismatch, or nil.
    static func run(_ test: Case) -> String? {
        let memory = FlatMemory()
        for entry in test.initial.ram {
            memory.bytes[entry[0]] = UInt8(entry[1])
        }

        var registers = Registers()
        registers.a = test.initial.a
        registers.b = test.initial.b
        registers.c = test.initial.c
        registers.d = test.initial.d
        registers.e = test.initial.e
        registers.f = test.initial.f
        registers.h = test.initial.h
        registers.l = test.initial.l
        registers.pc = test.initial.pc
        registers.sp = test.initial.sp

        let cpu = CPU(registers: registers)
        cpu.ime = test.initial.ime == 1
        cpu.interruptEnable = test.initial.ie ?? 0

        let cycles = cpu.step(memory)

        var problems: [String] = []
        func check(_ label: String, _ actual: some Equatable, _ expected: some Equatable) {
            if "\(actual)" != "\(expected)" {
                problems.append("\(label) was \(actual), expected \(expected)")
            }
        }

        check("A", cpu.registers.a, test.final.a)
        check("B", cpu.registers.b, test.final.b)
        check("C", cpu.registers.c, test.final.c)
        check("D", cpu.registers.d, test.final.d)
        check("E", cpu.registers.e, test.final.e)
        check("F", cpu.registers.f, test.final.f)
        check("H", cpu.registers.h, test.final.h)
        check("L", cpu.registers.l, test.final.l)
        check("PC", cpu.registers.pc, test.final.pc)
        check("SP", cpu.registers.sp, test.final.sp)

        for entry in test.final.ram where memory.bytes[entry[0]] != UInt8(entry[1]) {
            problems.append(
                String(format: "memory[%04X] was %02X, expected %02X",
                       entry[0], memory.bytes[entry[0]], entry[1])
            )
        }

        // One bus access per M-cycle, so the expected cycle count is simply how
        // many accesses the reference implementation made.
        if cycles != test.cycles.count {
            problems.append("took \(cycles) M-cycles, expected \(test.cycles.count)")
        }

        guard !problems.isEmpty else { return nil }
        return "\(test.name): " + problems.joined(separator: "; ")
    }
}

// MARK: - Tests

@Suite("SM83 instruction set")
struct SM83SuiteTests {

    @Test("The test suite is present")
    func suiteExists() throws {
        let files = try SM83Suite.opcodeFiles()
        #expect(
            !files.isEmpty,
            "No test data. Run ./scripts/fetch-tests.sh to download it."
        )
        // 500 rather than 512: eleven opcodes don't exist on the SM83 and one
        // is the CB prefix itself.
        #expect(files.count == 500)
    }

    /// Every opcode, every sampled case. Reported as one failure per opcode so
    /// a broken instruction names itself rather than drowning in output.
    @Test("Every opcode matches the reference implementation")
    func allOpcodes() throws {
        let files = try SM83Suite.opcodeFiles()
        try #require(!files.isEmpty, "Run ./scripts/fetch-tests.sh first")

        var failures: [String] = []
        var passed = 0

        for file in files {
            let opcode = file.deletingPathExtension().lastPathComponent
            var firstFailure: String?
            var failureCount = 0

            for test in try SM83Suite.cases(in: file) {
                if let problem = SM83Suite.run(test) {
                    failureCount += 1
                    if firstFailure == nil { firstFailure = problem }
                } else {
                    passed += 1
                }
            }

            if let firstFailure {
                failures.append("[\(opcode)] \(failureCount) failed — \(firstFailure)")
            }
        }

        if !failures.isEmpty {
            // Cap the output: a systemic mistake fails hundreds of opcodes and
            // the first few are the ones worth reading.
            let shown = failures.prefix(25).joined(separator: "\n")
            Issue.record(
                """
                \(failures.count) of \(files.count) opcodes failed (\(passed) cases passed):
                \(shown)
                """
            )
        }
        #expect(failures.isEmpty)
    }
}
