// SPDX-License-Identifier: GPL-3.0-only
//
//  RawAudioRecorder.swift
//  Shared by the watch and iPhone apps.
//
//  Keeps the audio of each picture as a WAV, so it can be shared and,
//  later, decoded again with other settings.
//
//  - Rate: the input is decimated to the rate the decoder itself works
//    at (input / round(input / 11025): 12000 Hz from 48 kHz, 11025 Hz
//    from 44.1 kHz), 16-bit mono. Nothing the decoder uses is lost; a
//    test decode of a 12 kHz recording matched the 48 kHz one to within
//    0.02 dB. Or (`fullRate`, iPhone's Full Rate setting) the input's own
//    rate, as it came in, unfiltered: four times the size, with 5 minutes
//    held for the part before being 29 MB at 48 kHz.
//  - Margins: the decoder's idea of where a picture starts and ends can be
//    wrong (a missed VIS, a start from the line syncs halfway down, an end
//    called early), so a recording keeps as much again before and after
//    as the picture itself takes to send: a Martin M1 picture (114 s) is
//    kept from 114 s before it was noticed until 114 s after it ended.
//    The last 5 minutes are always held in memory (16-bit, 7 MB at
//    12 kHz) for the part before.
//  - Gaps: audio the app lost (an interruption, a stall) is written as
//    silence of the same length, so the timing stays right, and listed in
//    the reception's audio.json.
//
//  Not thread-safe: ReceiverCore calls it under its lock.
//

import Foundation
import Accelerate

nonisolated final class RawAudioRecorder {
    nonisolated struct Finished: Sendable {
        let id: String
        let url: URL
        let info: AudioInfo
    }

    let outputRate: Int

    private let decimator: AudioDecimator
    private let directory: URL

    // Pre-roll ring (output samples).
    private var ring: [Int16]
    private var ringNext = 0
    private var ringCount = 0

    // The recording in progress.
    private var writer: WAVWriter?
    private var recordingID: String?
    private var written = 0
    private var gaps: [[Int]] = []
    /// Output samples still to record after the picture ended; nil while
    /// the picture is still coming in.
    private var tailLeft: Int?

    /// Enough for the longest mode (PD290, 289 s).
    static let preRollSeconds = 300.0
    /// A runaway recording (a picture that keeps resuming) stops here; a
    /// PD290 with both margins is under 15 minutes.
    static let maxSeconds = 30.0 * 60

    init(inputRate: Double, directory: URL, fullRate: Bool = false) {
        let factor = fullRate ? 1 : max(1, Int((inputRate / 11025).rounded()))
        decimator = AudioDecimator(inputRate: inputRate, factor: factor)
        outputRate = Int((inputRate / Double(factor)).rounded())
        self.directory = directory
        ring = [Int16](repeating: 0, count: Int(Self.preRollSeconds * Double(outputRate)))
    }

    var isRecording: Bool { writer != nil }

    private var maxSamples: Int { Int(Self.maxSeconds) * outputRate }

    // MARK: Input

    /// Every input buffer goes through here, recording or not (it fills
    /// the pre-roll). Returns a recording whose tail has just run out.
    func feed(_ samples: UnsafePointer<Float>, count: Int) -> Finished? {
        let out = decimator.process(samples, count: count)
        return append(out)
    }

    /// `inputCount` samples were lost: silence of the same length (as
    /// much of it as matters: the pre-roll's worth, or what's left of the
    /// recording), added a second at a time.
    func gap(inputCount: Int) -> Finished? {
        let limit = isRecording ? max(ring.count, maxSamples - written) : ring.count
        var left = min(inputCount / decimator.factor, limit)
        guard left > 0 else { return nil }
        if isRecording { gaps.append([written, min(left, tailLeft ?? left)]) }
        decimator.reset()
        let second = [Int16](repeating: 0, count: max(1, outputRate))
        var finished: Finished?
        while left > 0 {
            let n = min(left, second.count)
            left -= n
            // A recording whose tail runs out here ends; the rest of the
            // silence still goes into the pre-roll.
            if let done = append(n == second.count ? second : Array(second.prefix(n))) {
                finished = done
            }
        }
        return finished
    }

    private func append(_ out: [Int16]) -> Finished? {
        guard !out.isEmpty else { return nil }
        pushToRing(out)

        guard let writer else { return nil }
        var chunk = out
        if let left = tailLeft {
            if left <= 0 { return finish() }
            if chunk.count > left { chunk = Array(chunk.prefix(left)) }
            tailLeft = left - chunk.count
        }
        writer.append(chunk)
        written += chunk.count

        if tailLeft == 0 || written >= maxSamples {
            return finish()
        }
        return nil
    }

    private func pushToRing(_ out: [Int16]) {
        let cap = ring.count
        guard cap > 0 else { return }
        for s in out.suffix(cap) {
            ring[ringNext] = s
            ringNext = (ringNext + 1) % cap
        }
        ringCount = min(cap, ringCount + min(out.count, cap))
    }

    // MARK: Recording

    /// Starts recording a picture, beginning with up to `before` seconds
    /// of what was heard already. A recording still in progress is
    /// finished first and returned.
    func begin(id: String, before: Double) -> Finished? {
        let previous = finish()
        let url = directory.appending(path: "\(id)-\(UUID().uuidString.prefix(8)).wav")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let w = try WAVWriter(url: url, sampleRate: outputRate)
            let preRoll = ringContents(last: Int(max(0, before) * Double(outputRate)))
            w.append(preRoll)
            writer = w
            written = preRoll.count
            recordingID = id
            gaps = []
            tailLeft = nil
        } catch {
            writer = nil
            recordingID = nil
        }
        return previous
    }

    /// The picture resumed: keep recording, no tail.
    func keepGoing() {
        if isRecording { tailLeft = nil }
    }

    /// Recording the margin after a picture that has ended.
    var isRecordingTail: Bool { isRecording && tailLeft != nil }

    /// The picture ended: record `seconds` more, then finish.
    func end(after seconds: Double) {
        guard isRecording else { return }
        tailLeft = max(0, Int(seconds * Double(outputRate)))
    }

    /// Closes the recording now, if there is one.
    func finish() -> Finished? {
        guard let w = writer, let id = recordingID else { return nil }
        w.close()
        writer = nil
        recordingID = nil
        tailLeft = nil
        return Finished(id: id, url: w.url, info: AudioInfo(sampleRate: outputRate, gaps: gaps))
    }

    /// The newest `last` samples held (or all of them, if fewer).
    private func ringContents(last: Int) -> [Int16] {
        let cap = ring.count
        let count = min(ringCount, max(0, last))
        guard count > 0 else { return [] }
        let start = (ringNext - count + cap) % cap
        if start + count <= cap {
            return Array(ring[start..<(start + count)])
        }
        return Array(ring[start..<cap]) + Array(ring[0..<ringNext])
    }
}

/// What travels with audio.wav: its rate and the stretches that are
/// silence because the app lost them.
nonisolated struct AudioInfo: Codable, Sendable, Equatable {
    var format = 1
    var sampleRate: Int
    /// [first sample, sample count] pairs.
    var gaps: [[Int]]
}

// MARK: - Decimator

/// A Blackman-windowed sinc low-pass (cutoff 4.5 kHz, 16 × factor + 1
/// taps), keeping every factor-th sample. Streams: samples that don't yet
/// fill a window wait for the next buffer.
nonisolated final class AudioDecimator {
    let factor: Int
    private let taps: [Float]
    private var pending: [Float] = []

    init(inputRate: Double, factor: Int) {
        self.factor = factor
        let count = 16 * factor + 1
        let fc = 4500.0 / inputRate
        let mid = Double(count - 1) / 2
        var h = (0..<count).map { i -> Double in
            let n = Double(i) - mid
            let sinc = n == 0 ? 2 * fc : sin(2 * .pi * fc * n) / (.pi * n)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(count - 1))
                + 0.08 * cos(4 * .pi * Double(i) / Double(count - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        taps = h.map { Float($0) }
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    func process(_ x: UnsafePointer<Float>, count: Int) -> [Int16] {
        // Factor 1 (full rate): kept as it came, no filter.
        if factor == 1 {
            return UnsafeBufferPointer(start: x, count: count).map { v in
                let c: Float = v >= 1 ? 1 : v <= -1 ? -1 : v.isNaN ? 0 : v
                return Int16((c * 32767).rounded())
            }
        }
        pending.append(contentsOf: UnsafeBufferPointer(start: x, count: count))
        guard pending.count >= taps.count else { return [] }

        let outCount = (pending.count - taps.count) / factor + 1
        var out = [Float](repeating: 0, count: outCount)
        pending.withUnsafeBufferPointer { src in
            taps.withUnsafeBufferPointer { h in
                vDSP_desamp(
                    src.baseAddress!, vDSP_Stride(factor),
                    h.baseAddress!, &out,
                    vDSP_Length(outCount), vDSP_Length(taps.count)
                )
            }
        }
        pending.removeFirst(outCount * factor)

        return out.map { v in
            let c: Float = v >= 1 ? 1 : v <= -1 ? -1 : v.isNaN ? 0 : v
            return Int16((c * 32767).rounded())
        }
    }
}

// MARK: - WAV writer

/// 16-bit mono PCM WAV, written as it comes; the sizes in the header are
/// filled in on close.
nonisolated final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private var dataBytes = 0

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { buf in
            Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
        }
        // Apple platforms are little-endian, as WAV is.
        try? handle.write(contentsOf: data)
        dataBytes += data.count
    }

    func close() {
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: Self.le32(UInt32(36 + dataBytes)))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Self.le32(UInt32(dataBytes)))
        try? handle.close()
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(UInt32(36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))                          // fmt chunk size
        d.append(le16(1))                           // PCM
        d.append(le16(1))                           // mono
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(sampleRate * 2)))      // bytes per second
        d.append(le16(2))                           // block align
        d.append(le16(16))                          // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(UInt32(dataBytes)))
        return d
    }

    private static func le32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private static func le16(_ v: UInt16) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
