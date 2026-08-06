//
//  AudioOutput.swift
//  Cartridge
//

import AVFoundation
import Synchronization

/// Plays the samples the core produces.
///
/// Two clocks are involved and they don't agree: the emulator is paced by a
/// dispatch timer, the audio hardware by its own crystal. Neither can be told
/// to follow the other, so a buffer sits between them and absorbs the
/// difference — silence when the emulator falls behind, dropped samples when it
/// runs ahead. At normal speed the drift is small enough that neither happens
/// often; during fast-forward the dropping is what keeps playback current
/// instead of falling minutes behind.
final class AudioOutput {

    private let engine = AVAudioEngine()
    private let ring: AudioRing
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false

    /// Roughly 200 ms of stereo. Large enough to ride out a scheduling hiccup,
    /// small enough that input-to-sound latency stays imperceptible.
    private static let ringCapacity = Int(48_000 * 0.2) * 2

    init() {
        ring = AudioRing(capacity: Self.ringCapacity)
        configureSession()
        buildGraph()
    }

    private func configureSession() {
        #if os(iOS)
        // `.playback` so the ring/silent switch doesn't mute a game, and
        // `.mixWithOthers` so it plays over whatever else is going on rather
        // than stopping it.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.mixWithOthers]
        )
        #endif
    }

    private func buildGraph() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            return
        }

        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // The standard format is non-interleaved, so left and right arrive
            // as separate buffers and the interleaved ring has to be split.
            ring.render(frames: Int(frameCount), into: buffers)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do {
            try engine.start()
            isRunning = true
        } catch {
            // Losing audio shouldn't cost the game. Silence is a survivable
            // failure; refusing to run isn't.
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.pause()
        ring.reset()
        isRunning = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    /// Called from the emulation queue, once per frame.
    func enqueue(_ samples: [Float]) {
        ring.write(samples)
    }
}

/// A single-producer, single-consumer ring buffer.
///
/// The consumer is a real-time audio thread, which must never wait on anything:
/// no locks, no allocation, no `Array`. Two atomic indices into a fixed
/// allocation give the producer and consumer disjoint regions without either
/// blocking the other.
final class AudioRing: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    func reset() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
    }

    /// Producer side. Interleaved stereo.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        var write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)

        for sample in samples {
            let next = (write + 1) % capacity
            if next == read {
                // Full. Dropping the newest keeps the buffer coherent and, at
                // normal speed, this simply doesn't happen; during
                // fast-forward it's what stops audio lagging further behind
                // every second.
                break
            }
            storage[write] = sample
            write = next
        }

        writeIndex.store(write, ordering: .releasing)
    }

    /// Consumer side, called on the audio thread.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left

        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)

        for frame in 0..<frames {
            // Two samples per frame, and both must be present — handing back
            // half a frame would swap the channels for everything after it.
            let available = (write - read + capacity) % capacity
            guard available >= 2 else {
                left?[frame] = 0
                right?[frame] = 0
                continue
            }

            left?[frame] = storage[read]
            right?[frame] = storage[(read + 1) % capacity]
            read = (read + 2) % capacity
        }

        readIndex.store(read, ordering: .releasing)
    }
}
