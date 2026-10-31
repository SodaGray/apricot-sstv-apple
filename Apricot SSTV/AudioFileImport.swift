// SPDX-License-Identifier: GPL-3.0-only
//
//  AudioFileImport.swift
//  Apricot SSTV
//
//  Decode Audio File: pictures from a recording made elsewhere (a WAV from
//  a radio or a computer, a voice memo, anything AVAudioFile reads), as if
//  it were played to Receive. Not to be confused with Settings → Import
//  Library, which takes back a folder this app exported.
//
//  The whole file is decoded (any mode, starting without VIS too), and
//  every picture found is saved as if received here, fragments included,
//  each with its own stretch of the recording as raw audio (the same
//  margins as when listening, at 12 kHz or Full Rate as set), so it can go
//  to the darkroom. The file itself is only read: it stays where it is,
//  untouched.
//
//  When it was received: the file doesn't say, so it's taken from the
//  file's date (when it was last written: usually when the recording
//  ended), less its length, plus where the picture is in it. Each
//  picture's note says which file it came from, and where in it.
//

import SwiftUI
import AVFAudio
import UniformTypeIdentifiers

// MARK: - Decoding

nonisolated enum AudioFileImport {
    struct Result: Sendable {
        var pictures = 0
        var fragments = 0
        var skipped = 0
    }

    enum Failure: LocalizedError {
        case unreadable, tooLowRate

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This file can't be read as audio.")
            case .tooLowRate: String(localized: "This recording's sample rate is too low to decode SSTV.")
            }
        }
    }

    /// A picture found: its image and status, and where it is in the file
    /// (frames).
    private struct Found: @unchecked Sendable {
        let image: CGImage
        let status: SSTVStatus
        let startFrame: Int64
        let endFrame: Int64
        let rows: Int
    }

    /// Decodes the file and saves what it finds. `progress` gets 0…1.
    static func decode(
        _ url: URL,
        fullRate: Bool,
        progress: @Sendable (Double) -> Void
    ) throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate >= 8000 else { throw Failure.tooLowRate }
        guard let decoder = SSTVDecoder(sampleRate: Int(rate.rounded())) else { throw Failure.unreadable }
        decoder.setMode(vis: nil)
        decoder.setAutosync(true)

        let total = max(1, file.length)
        let found = try scan(file, decoder: decoder, total: total, progress: progress)

        // When the recording started, as well as can be told.
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let fileDate = values?.contentModificationDate ?? values?.creationDate ?? .now
        let recordingStart = fileDate.addingTimeInterval(-Double(total) / rate)
        let name = url.lastPathComponent

        var result = Result()
        for f in found {
            try Task.checkCancellation()
            let startSeconds = Double(f.startFrame) / rate
            let startedAt = recordingStart.addingTimeInterval(startSeconds)
            let endedAt = recordingStart.addingTimeInterval(Double(f.endFrame) / rate)
            let mode = f.status.mode ?? "?"
            let id = ReceptionStore.makeID(startedAt: startedAt, mode: mode)
            if FileManager.default.fileExists(atPath: ReceptionStore.folder(for: id).path) {
                result.skipped += 1
                continue
            }
            let meta = ReceptionMeta(
                id: id,
                mode: mode,
                visCode: f.status.start == .vis ? f.status.lastVIS : nil,
                start: f.status.start == .vis ? "vis" : "sync",
                end: endName(f.status.end),
                startedAt: startedAt,
                endedAt: endedAt,
                rows: f.rows,
                height: f.status.height,
                imageWidth: f.image.width,
                imageHeight: f.image.height,
                ppm: f.status.ppm,
                ppmValid: f.status.ppmValid,
                offsetHz: f.status.offsetHz,
                syncGood: f.status.syncGood,
                syncSeen: f.status.syncSeen,
                relocks: f.status.relocks,
                sampleRate: Int(rate.rounded()),
                device: "file"
            )
            try ReceptionStore.save(f.image, meta: meta)

            // Its stretch of the recording, with the usual margins.
            let margin = ReceiverCore.sendSeconds(mode: mode)
            let from = max(0, f.startFrame - Int64(margin * rate))
            let to = min(total, f.endFrame + Int64(margin * rate))
            if let cut = try? writeStretch(of: url, from: from, to: to, fullRate: fullRate) {
                _ = try? ReceptionStore.attachAudio(id: id, from: cut.url, info: AudioInfo(sampleRate: cut.rate, gaps: []))
            }

            // Where it came from, in its note (kept with any event's).
            var notes = EventStore.notes(for: id) ?? PictureNotes()
            let at = Duration.seconds(startSeconds).formatted(.time(pattern: .hourMinuteSecond))
            notes.note = String(localized: "Decoded from the audio file “\(name)”, at \(at) into it.")
            EventStore.saveNotes(notes, for: id)

            if meta.isFragment { result.fragments += 1 } else { result.pictures += 1 }
        }
        return result
    }

    /// Feeds the whole file, keeping every picture as it ends (or is
    /// replaced by the next).
    private static func scan(
        _ file: AVAudioFile,
        decoder: SSTVDecoder,
        total: Int64,
        progress: @Sendable (Double) -> Void
    ) throws -> [Found] {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let capacity: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.unreadable
        }
        var mono = [Float](repeating: 0, count: Int(capacity))
        var found: [Found] = []
        var prev = decoder.status
        var fed: Int64 = 0
        var lastReport = -1

        func keep(_ status: SSTVStatus, rows: Int) {
            guard rows >= 1, let image = decoder.makeImage() else { return }
            let start = max(0, Int64((status.startSeconds * file.processingFormat.sampleRate).rounded()))
            found.append(Found(image: image, status: status, startFrame: start, endFrame: max(start, fed), rows: rows))
        }

        while file.framePosition < total {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: capacity)
            } catch {
                break                           // a damaged end: keep what was read
            }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono[i] = sum / Float(channels)
            }
            // In small steps, so a picture's end is caught where it happens.
            var at = 0
            try mono.withUnsafeBufferPointer { buf in
                while at < n {
                    let step = min(2048, n - at)
                    decoder.feed(buf.baseAddress! + at, count: step)
                    at += step
                    fed += Int64(step)
                    let st = decoder.status
                    if prev.receiving && st.receiving && st.line < prev.line {
                        keep(prev, rows: prev.line)            // replaced by the next
                    }
                    decoder.updatePicture()
                    if prev.receiving && !st.receiving {
                        keep(st, rows: max(st.line, prev.line))
                    }
                    prev = st
                }
                if Task.isCancelled { throw CancellationError() }
            }
            let pct = Int(Double(fed) / Double(total) * 100)
            if pct != lastReport {
                lastReport = pct
                progress(min(1, Double(fed) / Double(total)))
            }
        }
        if prev.receiving {
            decoder.abort()
            decoder.updatePicture()
            keep(prev, rows: prev.line)
        }
        return found
    }

    /// Frames `from..<to` of the file, mono 16-bit, as a WAV in the
    /// temporary folder (decimated to about 12 kHz unless `fullRate`).
    private static func writeStretch(of url: URL, from: Int64, to: Int64, fullRate: Bool) throws -> (url: URL, rate: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let decimator = AudioDecimator(
            inputRate: format.sampleRate,
            factor: fullRate ? 1 : max(1, Int((format.sampleRate / 11025).rounded()))
        )
        let outRate = Int((format.sampleRate / Double(decimator.factor)).rounded())
        let out = FileManager.default.temporaryDirectory.appending(path: "decode-\(UUID().uuidString).wav")
        let writer = try WAVWriter(url: out, sampleRate: outRate)
        defer { writer.close() }

        let capacity: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.unreadable
        }
        var mono = [Float](repeating: 0, count: Int(capacity))
        file.framePosition = from
        var left = to - from
        while left > 0 {
            let want = AVAudioFrameCount(min(Int64(capacity), left))
            try file.read(into: buffer, frameCount: want)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono[i] = sum / Float(channels)
            }
            let samples = mono.withUnsafeBufferPointer { decimator.process($0.baseAddress!, count: n) }
            writer.append(samples)
            left -= Int64(n)
        }
        return (out, outRate)
    }

    private static func endName(_ end: SSTVStatus.End) -> String {
        switch end {
        case .complete: "complete"
        case .lost: "lost"
        case .aborted: "aborted"
        case .newVIS: "new VIS"
        case .noMemory: "no memory"
        case .none: "none"
        }
    }
}

// MARK: - Screen

/// The sheet while a file is decoded, and what came of it.
struct DecodeAudioFileView: View {
    let url: URL
    let fullRate: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var result: AudioFileImport.Result?
    @State private var errorMessage: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "waveform")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(verbatim: url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                if let result {
                    summary(result)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView(value: progress)
                    Text("Decoding the whole recording, as if it were played to Receive. The file itself isn't changed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Decode Audio File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result == nil && errorMessage == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            job?.cancel()
                            dismiss()
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(result == nil && errorMessage == nil)
        .task { start() }
    }

    private func summary(_ r: AudioFileImport.Result) -> some View {
        VStack(spacing: 8) {
            if r.pictures == 0 && r.fragments == 0 && r.skipped == 0 {
                Text("No SSTV picture was found in this recording.")
            } else {
                Text("Found \(r.pictures) pictures and \(r.fragments) fragments.")
                if r.skipped > 0 {
                    Text("\(r.skipped) were already in Pictures and were left as they are.")
                        .foregroundStyle(.secondary)
                }
                Text("They're in Pictures, each with its stretch of the recording as raw audio, to develop again in the darkroom. When they were received is worked out from the file's date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func start() {
        guard job == nil else { return }
        let url = url, fullRate = fullRate
        job = Task {
            let work = Task.detached(priority: .userInitiated) {
                Result {
                    try AudioFileImport.decode(url, fullRate: fullRate) { p in
                        Task { @MainActor in progress = p }
                    }
                }
            }
            let outcome = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let r): result = r
            case .failure(let error):
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
}
