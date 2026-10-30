// SPDX-License-Identifier: GPL-3.0-only
//
//  Receiver.swift
//  Shared by the watch and iPhone apps.
//
//  Microphone → SSTV decoder → saved pictures.
//
//  ReceiverCore runs on the audio tap's thread: it feeds the decoder,
//  tracks lost samples, notices when a picture starts, resumes and ends,
//  and saves finished pictures on its own queue. None of that depends on
//  the UI, so it keeps working with the wrist down.
//
//  Receiver (main actor) owns the audio engine and polls the core for
//  the UI, the haptics and the saved count.
//
//  Platform differences are marked #if os(watchOS): haptics, the device
//  name in meta.json, and handing saved pictures to WatchSync.
//

import Foundation
import AVFAudio
import Accelerate
import Combine
import CoreGraphics
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

// MARK: - Core (tap thread)

nonisolated enum ReceiverEvent: Sendable {
    case started(mode: String, viaVIS: Bool)
    case resumed(mode: String)
    /// updated: the same picture saved again after it resumed.
    case finished(mode: String, saved: Bool, updated: Bool)
    /// A VIS for a mode this build doesn't decode, or not the chosen one.
    case skipped(mode: String, vis: Int)
    case saveFailed(String)
}

nonisolated struct ReceiverSnapshot: @unchecked Sendable {
    var status: SSTVStatus
    /// Only set when the picture changed since the last snapshot that asked for it.
    var image: CGImage?
    var levelDB: Double
    var clipping: Bool
    var lostSamples: Int64
    var lastBufferUptime: Double
}

nonisolated private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}

nonisolated final class ReceiverCore: @unchecked Sendable {
    let sampleRate: Double
    /// "watch" or "phone", written into meta.json.
    let device: String

    private let lock = NSLock()
    private let decoder: SSTVDecoder
    private let saveQueue = DispatchQueue(label: "Apricot.save", qos: .utility)

    // Everything below is guarded by `lock`.
    private var prev: SSTVStatus
    private var current: Reception?
    private var expectedSampleTime: Int64?
    private var restarted = false
    private var lastBufferEnd: Double = 0
    private var lost: Int64 = 0
    private var levelDB = -120.0
    private var clipUntil: Double = 0
    private var pictureChanged = false
    private var events: [ReceiverEvent] = []
    private var savedIDs: Set<String> = []

    nonisolated private struct Reception {
        var id: String
        var startedAt: Date
        var mode: String
        var visCode: Int?
    }

    init?(sampleRate: Double, device: String) {
        guard let decoder = SSTVDecoder(sampleRate: Int(sampleRate.rounded())) else {
            return nil
        }
        self.sampleRate = sampleRate
        self.device = device
        self.decoder = decoder
        self.prev = decoder.status
    }

    /// Built here, outside the main actor, because the engine calls it
    /// on its own thread.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, when in
            process(buffer, when)
        }
    }

    /// The engine was stopped and started again: sample times start over,
    /// so the next buffer measures the gap from the clock instead.
    func engineRestarted() {
        lock.withLock { restarted = true }
    }

    /// Ends the picture in progress (saving it if it's worth keeping).
    func finish() {
        lock.withLock {
            decoder.abort()
            checkTransitions()
            if decoder.updatePicture() { pictureChanged = true }
        }
    }

    /// Start on a run of line syncs when no VIS was heard.
    func setAutosync(_ on: Bool) {
        lock.withLock { decoder.setAutosync(on) }
    }

    /// Receive only this mode (VIS code); nil = any mode.
    func setMode(vis: Int?) {
        lock.withLock { decoder.setMode(vis: vis) }
    }

    /// Ends a picture in progress (saving it if it's worth keeping) and
    /// blanks the picture. The blank isn't published: the UI shows its
    /// placeholder until the next picture starts drawing.
    func clearPicture() {
        lock.withLock {
            // End it first, while the decoder still holds the picture:
            // sstv_clear would blank it before the save could copy it.
            decoder.abort()
            checkTransitions()
            decoder.updatePicture()

            decoder.clear()
            decoder.updatePicture()
            pictureChanged = false
        }
    }

    func snapshot(includeImage: Bool) -> ReceiverSnapshot {
        lock.withLock {
            var image: CGImage?
            if includeImage && pictureChanged {
                image = decoder.makeImage()
                pictureChanged = false
            }
            let now = ProcessInfo.processInfo.systemUptime
            return ReceiverSnapshot(
                status: prev,
                image: image,
                levelDB: levelDB,
                clipping: now < clipUntil,
                lostSamples: lost,
                lastBufferUptime: lastBufferEnd
            )
        }
    }

    func drainEvents() -> [ReceiverEvent] {
        lock.withLock {
            let drained = events
            events.removeAll()
            return drained
        }
    }

    // MARK: Per buffer

    private func process(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let count = Int(buffer.frameLength)
        guard count > 0, let samples = buffer.floatChannelData?[0] else { return }
        let now = ProcessInfo.processInfo.systemUptime

        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))

        lock.withLock {
            // Lost audio: from sample times, or from the clock after a restart.
            var gap: Int64 = 0
            if restarted {
                let bufferStart = now - Double(count) / sampleRate
                let missing = (bufferStart - lastBufferEnd) * sampleRate
                if lastBufferEnd > 0, missing > sampleRate * 0.1 {
                    gap = Int64(missing)
                }
                restarted = false
            } else if when.isSampleTimeValid,
                      let expected = expectedSampleTime,
                      when.sampleTime > expected {
                gap = when.sampleTime - expected
            }
            expectedSampleTime = when.isSampleTimeValid
                ? when.sampleTime + Int64(count)
                : nil

            if gap > 0 {
                decoder.gap(Int(gap))
                lost += gap
            }
            decoder.feed(samples, count: count)
            lastBufferEnd = now

            levelDB = rms > 0 ? max(-120, 20 * log10(Double(rms))) : -120
            if peak >= 0.99 { clipUntil = now + 2 }

            checkTransitions()
            if decoder.updatePicture() { pictureChanged = true }
        }
    }

    // MARK: Picture start / resume / end (lock held)

    private func checkTransitions() {
        let s = decoder.status
        defer { prev = s }

        if let vis = s.lastVIS, vis != prev.lastVIS, !s.lastVISSupported {
            events.append(.skipped(mode: SSTVDecoder.modeName(vis: vis) ?? "VIS \(vis)", vis: vis))
        }

        let newPicture = s.receiving && (
            !prev.receiving
            || s.line < prev.line
            || (prev.mode != nil && s.mode != prev.mode)
        )

        // A new VIS replaced the picture inside the core. The RGBA copy
        // still holds the old one (it hasn't been updated yet): save that.
        if newPicture && prev.receiving {
            var ended = prev
            ended.end = .newVIS
            save(ended)
        }

        // Ended on its own (complete, lost, aborted): bring the copy up to
        // date first, so the last rows and the final re-timing are in it.
        if !s.receiving && prev.receiving {
            decoder.updatePicture()
            pictureChanged = true
            save(s)
        }

        if newPicture {
            let mode = s.mode ?? "?"
            let resumed = !prev.receiving && s.relocks > prev.relocks && current != nil
            if resumed {
                events.append(.resumed(mode: mode))
            } else {
                let started = Date()
                current = Reception(
                    id: ReceptionStore.makeID(startedAt: started, mode: mode),
                    startedAt: started,
                    mode: mode,
                    visCode: s.start == .vis ? s.lastVIS : nil
                )
                events.append(.started(mode: mode, viaVIS: s.start == .vis))
            }
        }
    }

    /// Saves the picture in the RGBA copy as the current reception.
    /// A resumed picture is saved again over the same folder.
    private func save(_ s: SSTVStatus) {
        guard let r = current else { return }

        // Too little to keep (and false sync starts end up here).
        let minRows = max(16, s.height / 8)
        guard s.line >= minRows, let image = decoder.makeImage() else {
            events.append(.finished(mode: r.mode, saved: false, updated: false))
            return
        }

        let meta = ReceptionMeta(
            id: r.id,
            mode: r.mode,
            visCode: r.visCode,
            start: s.start == .vis ? "vis" : "sync",
            end: Self.endName(s.end),
            startedAt: r.startedAt,
            endedAt: Date(),
            rows: s.line,
            height: s.height,
            imageWidth: image.width,
            imageHeight: image.height,
            ppm: s.ppm,
            ppmValid: s.ppmValid,
            offsetHz: s.offsetHz,
            syncGood: s.syncGood,
            syncSeen: s.syncSeen,
            relocks: s.relocks,
            sampleRate: Int(sampleRate.rounded()),
            device: device
        )
        let updated = !savedIDs.insert(r.id).inserted
        events.append(.finished(mode: r.mode, saved: true, updated: updated))

        let box = ImageBox(image: image)
        saveQueue.async { [self] in
            do {
                try ReceptionStore.save(box.image, meta: meta)
                #if os(watchOS)
                WatchSync.shared.send(id: meta.id)
                #endif
            } catch {
                lock.withLock {
                    events.append(.saveFailed(error.localizedDescription))
                }
            }
        }
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

// MARK: - Audio session (shared with the transmitter)

/// Session changes block for a while, so they run on one serial queue,
/// off the main thread, in the order they were asked for.
nonisolated enum AudioSessionControl {
    private static let queue = DispatchQueue(label: "Apricot.session", qos: .userInitiated)

    static func activate(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode
    ) async throws {
        let categoryName = category.rawValue
        let modeName = mode.rawValue
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(
                        AVAudioSession.Category(rawValue: categoryName),
                        mode: AVAudioSession.Mode(rawValue: modeName),
                        options: []
                    )
                    try session.setActive(true)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Receiver (main actor)

@MainActor
final class Receiver: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var stalled = false
    @Published private(set) var notice: String?
    @Published private(set) var status: SSTVStatus?
    @Published private(set) var picture: CGImage?
    @Published private(set) var levelDB = -120.0
    @Published private(set) var clipping = false
    @Published private(set) var lostSeconds = 0.0
    @Published private(set) var savedCount = 0
    /// The input in use ("iPhone Microphone", a USB interface's name).
    @Published private(set) var inputName: String?
    @Published private(set) var sampleRate: Double = 0

    /// Start a picture from its line syncs when the VIS header was missed
    /// (the decoder's autosync). On by default, as on the iPod; remembered.
    @Published var autosync: Bool = UserDefaults.standard.object(forKey: "rx.autosync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autosync, forKey: "rx.autosync")
            core?.setAutosync(autosync)
        }
    }

    /// The one mode to receive (its VIS code), or nil for any mode, found
    /// from the VIS header. Takes effect for the next picture; remembered.
    @Published var chosenMode: Int? = Receiver.loadChosenMode() {
        didSet {
            UserDefaults.standard.set(chosenMode ?? -1, forKey: "rx.mode")
            core?.setMode(vis: chosenMode)
        }
    }

    private static func loadChosenMode() -> Int? {
        guard let vis = UserDefaults.standard.object(forKey: "rx.mode") as? Int,
              SSTVDecoder.isSupported(vis: vis)
        else { return nil }
        return vis
    }

    #if os(watchOS)
    private static let deviceName = "watch"
    #else
    private static let deviceName = "phone"
    #endif

    private var engine = AVAudioEngine()
    private var core: ReceiverCore?
    private var pollTask: Task<Void, Never>?
    private var restarting = false
    private var visible = true
    private var active = true
    private var noticeUntil: Double = 0

    // MARK: Start / stop

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        notice = nil

        Task {
            defer { isStarting = false }
            guard await AVAudioApplication.requestRecordPermission() else {
                show("Microphone access is off. Turn it on in Settings.", seconds: 600)
                return
            }
            do {
                try await AudioSessionControl.activate(.record, mode: .measurement)
                try startCapture()
            } catch {
                AudioSessionControl.deactivate()
                show("Can't start: \(error.localizedDescription)", seconds: 600)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        AudioSessionControl.deactivate()
        core?.finish()
        poll()
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        stalled = false
        levelDB = -120
        setScreenStaysOn(false)
    }

    private func startCapture() throws {
        let core = try makeCore()
        self.core = core
        status = nil
        lostSeconds = 0

        try startEngine(core: core)
        isRunning = true
        setScreenStaysOn(true)
        startPolling()
    }

    /// A decoder for the input's current rate.
    private func makeCore() throws -> ReceiverCore {
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate >= 8000, format.channelCount > 0 else {
            throw ReceiverError.noInput
        }
        guard let core = ReceiverCore(sampleRate: format.sampleRate, device: Self.deviceName) else {
            throw ReceiverError.decoder
        }
        core.setAutosync(autosync)
        core.setMode(vis: chosenMode)
        sampleRate = format.sampleRate
        return core
    }

    private func startEngine(core: ReceiverCore) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: core.makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// After an interruption or a route / configuration change. Same
    /// decoder if the rate is unchanged, so a picture in progress carries
    /// on across the gap; a new input at another rate starts a new one.
    private func restart() {
        guard isRunning, !restarting, let old = core else { return }
        restarting = true
        teardown()
        old.engineRestarted()

        Task {
            defer { restarting = false }
            do {
                try await AudioSessionControl.activate(.record, mode: .measurement)
                guard isRunning else { return }      // stopped meanwhile

                var current = old
                let rate = engine.inputNode.inputFormat(forBus: 0).sampleRate
                if abs(rate - old.sampleRate) >= 1 {
                    old.finish()
                    poll()
                    current = try makeCore()
                    core = current
                    show("Input changed", seconds: 3)
                }
                try startEngine(core: current)
            } catch {
                core?.finish()
                poll()
                pollTask?.cancel()
                pollTask = nil
                isRunning = false
                setScreenStaysOn(false)
                AudioSessionControl.deactivate()
                show("Stopped: \(error.localizedDescription)", seconds: 600)
            }
        }
    }

    /// Blanks the picture (a picture in progress ends and is saved first).
    func clearPicture() {
        core?.clearPicture()
        poll()
        picture = nil
    }

    // MARK: Scene

    /// visible: the app is on screen (also dimmed, Always-On).
    /// active: on screen and not dimmed.
    func setScene(visible: Bool, active: Bool) {
        self.visible = visible
        self.active = active
        if visible { poll() }
    }

    // MARK: Notifications

    func handleInterruption(_ notification: Notification) {
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            show("Interrupted", seconds: 600)
        case .ended:
            show("Resumed after interruption", seconds: 3)
            restart()
        @unknown default:
            break
        }
    }

    func handleEngineConfigurationChange() {
        restart()
    }

    func handleMediaServicesReset() {
        let wasRunning = isRunning
        engine = AVAudioEngine()
        if wasRunning { restart() }
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.active == true ? 250 : 1000
                try? await Task.sleep(for: .milliseconds(interval))
                guard let self else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        guard let core else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let snap = core.snapshot(includeImage: visible)

        if let image = snap.image { picture = image }
        if status != snap.status { status = snap.status }
        levelDB = snap.levelDB
        clipping = snap.clipping
        lostSeconds = Double(snap.lostSamples) / core.sampleRate

        if isRunning, snap.lastBufferUptime > 0 {
            let silent = now - snap.lastBufferUptime > 2
            if silent != stalled { stalled = silent }
        }

        for event in core.drainEvents() {
            handle(event)
        }
        if notice != nil, now > noticeUntil { notice = nil }
    }

    private func handle(_ event: ReceiverEvent) {
        switch event {
        case let .started(mode, viaVIS):
            // A sync start may be a false start, so only a VIS buzzes.
            if viaVIS { Haptics.start() }
            show("\(mode) started", seconds: 3)
        case let .resumed(mode):
            show("\(mode) resumed", seconds: 3)
        case let .finished(mode, saved, updated):
            if saved {
                if !updated { savedCount += 1 }
                Haptics.success()
                show("\(mode) saved", seconds: 5)
            }
        case let .skipped(mode, vis):
            if let chosen = chosenMode, SSTVDecoder.isSupported(vis: vis) {
                let name = SSTVDecoder.modeName(vis: chosen) ?? String(localized: "the chosen mode")
                show("Skipped \(mode): receiving \(name) only", seconds: 8)
            } else {
                show("Skip \(mode): not supported", seconds: 5)
            }
        case let .saveFailed(message):
            Haptics.failure()
            show("Save failed: \(message)", seconds: 30)
        }
    }

    /// Every notice is localized here (String Catalog: Localizable.xcstrings).
    private func show(_ text: String.LocalizationValue, seconds: Double) {
        notice = String(localized: text)
        noticeUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    /// iPhone: keep the screen on while listening, so the picture
    /// can be watched as it comes in. (The watch manages its own.)
    private func setScreenStaysOn(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static func start() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.start)
        #else
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func failure() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.failure)
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

nonisolated enum ReceiverError: LocalizedError {
    case noInput, decoder

    var errorDescription: String? {
        switch self {
        case .noInput: String(localized: "no usable microphone input")
        case .decoder: String(localized: "decoder could not start")
        }
    }
}
