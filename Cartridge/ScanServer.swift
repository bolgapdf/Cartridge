//
//  ScanServer.swift
//  Cartridge
//

import Foundation
import Network

/// A loopback socket that hands out snapshots of the running console.
///
/// This exists for cheat searching: finding the address behind a number means
/// comparing memory a few seconds apart, and doing that through save files
/// means stopping to save one between every round. Over a socket the same
/// search is a handful of keystrokes while the game keeps running.
///
/// The wire format for a snapshot is just `saveState()`. Inventing a leaner one
/// would mean a second serialiser to keep in step with the first, and the
/// difference — a few hundred kilobytes over loopback — buys nothing.
///
/// Off unless switched on in Settings, and bound to 127.0.0.1 so it is never
/// reachable from another machine. It is a debugging port into a running
/// program; it should take a deliberate act to open one.
final class ScanServer {

    enum Status: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    /// Produces a save state, or nil when no game is loaded. Called on the
    /// server's queue, so the implementation is responsible for hopping to
    /// wherever the core actually lives.
    typealias SnapshotProvider = @Sendable () -> (title: String, data: Data)?

    /// Replaces the set of held addresses. Empty clears them.
    typealias CheatSetter = @Sendable ([Cheat]) -> Void

    private let provider: SnapshotProvider
    private let setCheats: CheatSetter
    private let preferredPort: UInt16
    private let queue = DispatchQueue(label: "me.jacobsilva.Cartridge.scanserver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Read from the main actor for display; written on `queue`.
    private(set) var status: Status = .stopped

    var onStatusChange: (@Sendable (Status) -> Void)?

    init(
        port: UInt16 = 8484,
        provider: @escaping SnapshotProvider,
        setCheats: @escaping CheatSetter
    ) {
        self.preferredPort = port
        self.provider = provider
        self.setCheats = setCheats
    }

    /// What the client last asked to be held, so CLEAR and re-FREEZE are the
    /// only two things it has to think about.
    private var held: [Cheat] = []

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }

            let parameters = NWParameters.tcp
            // Loopback only. `requiredInterfaceType = .loopback` is the part
            // that makes this a local debugging aid rather than a service.
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true

            guard let port = NWEndpoint.Port(rawValue: preferredPort),
                  let listener = try? NWListener(using: parameters, on: port)
            else {
                set(.failed("could not listen on port \(preferredPort)"))
                return
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    set(.listening(port: listener.port?.rawValue ?? preferredPort))
                case .failed(let error):
                    set(.failed(error.localizedDescription))
                    stop()
                case .cancelled:
                    set(.stopped)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            set(.stopped)
        }
    }

    private func set(_ new: Status) {
        guard status != new else { return }
        status = new
        onStatusChange?(new)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.connections[ObjectIdentifier(connection)] = nil }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Commands are newline-terminated, so a read can end mid-command and the
    /// remainder has to be carried into the next one.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            // A client that never sends a newline shouldn't be able to grow
            // this without limit.
            guard buffer.count <= 4096 else {
                send("ERR command too long", on: connection)
                connection.cancel()
                return
            }

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line: String(decoding: line, as: UTF8.self), on: connection)
            }

            receive(on: connection, buffer: buffer)
        }
    }

    private func handle(line: String, on connection: NWConnection) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ").map(String.init)
        let command = (words.first ?? "").uppercased()

        switch command {
        case "FREEZE":
            // FREEZE <hex address> <bank> <value>
            guard words.count == 4,
                  let address = UInt16(words[1].replacingOccurrences(of: "$", with: ""), radix: 16),
                  let bank = Int(words[2]),
                  let value = UInt8(words[3])
            else {
                send("ERR usage: FREEZE <hex address> <bank> <value>", on: connection)
                return
            }
            held.removeAll { $0.address == address && $0.bank == bank }
            held.append(Cheat(address: address, bank: bank, value: value))
            setCheats(held)
            send("OK \(held.count)", on: connection)

        case "CLEAR":
            held.removeAll()
            setCheats([])
            send("OK 0", on: connection)

        case "HELD":
            send("OK " + held.map { "\($0.code)@\($0.bank)" }.joined(separator: " "), on: connection)

        case "PING":
            send("PONG", on: connection)

        case "INFO":
            if let snapshot = provider() {
                send("OK \(snapshot.title)", on: connection)
            } else {
                send("ERR no game loaded", on: connection)
            }

        case "SNAP":
            guard let snapshot = provider() else {
                send("ERR no game loaded", on: connection)
                return
            }
            // Length first so the client knows when it has the whole thing;
            // a save state is binary and contains newlines of its own.
            send("OK \(snapshot.data.count)", on: connection)
            connection.send(content: snapshot.data, completion: .idempotent)

        case "BYE":
            send("OK", on: connection)
            connection.cancel()

        case "":
            break

        default:
            send("ERR unknown command", on: connection)
        }
    }

    private func send(_ line: String, on connection: NWConnection) {
        connection.send(content: Data("\(line)\n".utf8), completion: .idempotent)
    }
}
