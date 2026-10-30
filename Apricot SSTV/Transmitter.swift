// SPDX-License-Identifier: GPL-3.0-only
//
//  Transmitter.swift
//  Apricot SSTV
//
//  Picture → SSTV audio → the iPhone's audio output (headphone adapter
//  or USB interface into the radio, keyed by VOX), or a WAV file.
//
//  The audio is encoded at the output's own sample rate, so nothing
//  resamples it on the way out. The picture itself is made by
//  PictureComposer.
//

import Foundation
import AVFAudio
import Combine
import CoreGraphics
import UIKit

@MainActor
final class Transmitter: ObservableObject {
    enum State: Equatable {
        case idle
        case encoding
        case sending
    }

    /// How the last transmission ended (for haptics and the status line).
    enum Outcome: Equatable {
        case sent       // played to the end
        case stopped    // the user stopped it
        case failed     // couldn't start, or the audio went away
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var notice: String?
    @Published private(set) var outputName: String?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var progressTask: Task<Void, Never>?
    private var runID = 0

    var isBusy: Bool { state != .idle }

    // MARK: Send

    /// `rgb`: the composed picture at the mode's size (PictureComposer).
    func send(rgb: [UInt8], mode: SSTVMode) {
        guard state == .idle else { return }
        state = .encoding
        notice = nil
        runID += 1
        let run = runID

        Task {
            do {
                try await AudioSessionControl.activate(.playback, mode: .default)
                let rate = Int(AVAudioSession.sharedInstance().sampleRate.rounded())
                outputName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName

                let samples = await Task.detached(priority: .userInitiated) {
                    SSTVEncoder.encode(rgb: rgb, mode: mode, sampleRate: rate)
                }.value
                guard run == runID, state == .encoding else { return }   // stopped meanwhile
                guard let samples else { throw TransmitError.encoder }

                try play(samples, rate: Double(rate), run: run)
            } catch {
                finish(run: run, .failed, notice: "Can't send: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard state != .idle else { return }
        finish(run: runID, .stopped, notice: "Stopped")
    }

    private func play(_ samples: [Float], rate: Double, run: Int) throws {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw TransmitError.buffer }

        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.finish(run: run, .sent, notice: "Sent")
            }
        }
        player.play()

        duration = Double(samples.count) / rate
        elapsed = 0
        state = .sending
        UIApplication.shared.isIdleTimerDisabled = true
        startProgress(rate: rate, run: run)
    }

    private func startProgress(rate: Double, run: Int) {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.runID == run, self.state == .sending else { return }
                if !self.engine.isRunning {
                    self.finish(run: run, .failed, notice: "Stopped: the audio output changed")
                    return
                }
                if let nodeTime = self.player.lastRenderTime,
                   let playerTime = self.player.playerTime(forNodeTime: nodeTime) {
                    self.elapsed = min(self.duration, max(0, Double(playerTime.sampleTime) / rate))
                }
            }
        }
    }

    private func finish(run: Int, _ outcome: Outcome, notice: String.LocalizationValue) {
        guard run == runID, state != .idle else { return }
        lastOutcome = outcome
        progressTask?.cancel()
        progressTask = nil
        player.stop()
        engine.stop()
        AudioSessionControl.deactivate()
        state = .idle
        self.notice = String(localized: notice)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Notifications

    func handleInterruption(_ notification: Notification) {
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        if state != .idle {
            finish(run: runID, .failed, notice: "Stopped: interrupted")
        }
    }

    func handleMediaServicesReset() {
        if state != .idle {
            finish(run: runID, .failed, notice: "Stopped: audio system reset")
        }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
    }

    // MARK: WAV

    /// Encodes to a 16-bit mono WAV in the temporary folder, for checking
    /// with another decoder or playing from another device. Nonisolated
    /// and detached: it never waits for, or holds, the main thread.
    nonisolated static func exportWAV(rgb: [UInt8], mode: SSTVMode, sampleRate: Int = 44100) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let samples = SSTVEncoder.encode(rgb: rgb, mode: mode, sampleRate: sampleRate) else {
                throw TransmitError.encoder
            }
            let name = mode.name.filter { $0.isLetter || $0.isNumber }
            let url = FileManager.default.temporaryDirectory
                .appending(path: "Apricot-\(name).wav")
            try? FileManager.default.removeItem(at: url)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let channel = buffer.floatChannelData?[0]
            else { throw TransmitError.buffer }

            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
            return url
        }.value
    }
}

nonisolated enum TransmitError: LocalizedError {
    case encoder, buffer

    var errorDescription: String? {
        switch self {
        case .encoder: String(localized: "the encoder failed")
        case .buffer: String(localized: "no memory for the audio")
        }
    }
}
