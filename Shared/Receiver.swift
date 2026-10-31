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
//  The core also keeps each picture's audio (RawAudioRecorder), with as
//  much again before and after as the picture takes to send (at least
//  the 2-minute resume window after a loss).
//
//  Listening stops by itself after a set time without a picture, and on
//  the watch when the wrist goes down or the app is left (wristPolicy),
//  but never in the middle of a picture. Each change of state taps the
//  wrist (Haptics).
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

// MARK: - Settings

/// Watch: what lowering the wrist or leaving the app does to listening.
nonisolated enum WristPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Keep listening until Stop (or the receive timeout). The default.
    case keep
    /// Keep listening while dimmed; stop when the app is left.
    case keepWhenDimmed
    /// Stop (after the picture in progress) when the screen dims or the
    /// app is left: saves the most battery.
    case stop

    var id: Self { self }
}

/// Why listening stopped by itself.
nonisolated enum AutoStopReason: Sendable {
    /// The screen dimmed (wrist down), and wristPolicy says stop.
    case dimmed
    /// The app was left, and wristPolicy says stop.
    case left
    /// No picture for the receive timeout.
    case timeout
}

// MARK: - Core (tap thread)

nonisolated enum ReceiverEvent: Sendable {
    case started(mode: String, viaVIS: Bool)
    /// A start from line syncs got far enough to be a real picture (the
    /// rows a picture needs to be kept), not noise.
    case confirmed(mode: String)
    case resumed(mode: String)
    /// updated: the same picture saved again after it resumed.
    case finished(mode: String, end: SSTVStatus.End, saved: Bool, updated: Bool)
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
    /// Still recording the margin after a picture (stopping now would cut it).
    var recordingTail: Bool
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
    private let recorder: RawAudioRecorder
    private var saveAudio = true

    nonisolated private struct Reception {
        var id: String
        var startedAt: Date
        var mode: String
        var visCode: Int?
        /// A VIS start, or a sync start that reached the rows to keep.
        var confirmed: Bool
    }

    /// How long a mode takes to send, for the recording's margins.
    static func sendSeconds(mode: String?) -> Double {
        switch mode {
        case "Robot 36": 36
        case "Robot 72": 72
        case "Martin M1": 114
        case "Martin M2": 58
        case "Scottie S1": 110
        case "Scottie S2": 71
        case "Scottie DX": 269
        case "PD50": 50
        case "PD90": 90
        case "PD120": 126
        case "PD160": 161
        case "PD180": 187
        case "PD240": 248
        case "PD290": 289
        default: 120
        }
    }

    /// Rows a picture needs to be kept (fewer: a false start).
    private static func minRows(_ s: SSTVStatus) -> Int {
        max(16, s.height / 8)
    }

    init?(sampleRate: Double, device: String, fullRateAudio: Bool = false) {
        guard let decoder = SSTVDecoder(sampleRate: Int(sampleRate.rounded())) else {
            return nil
        }
        self.sampleRate = sampleRate
        self.device = device
        self.decoder = decoder
        self.prev = decoder.status
        self.recorder = RawAudioRecorder(
            inputRate: sampleRate,
            directory: ReceptionStore.recordingDirectory,
            fullRate: fullRateAudio
        )
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

    /// Ends the picture in progress (saving it, and its audio, if it's
    /// worth keeping).
    func finish() {
        lock.withLock {
            decoder.abort()
            checkTransitions()
            if decoder.updatePicture() { pictureChanged = true }
            if let done = recorder.finish() { attach(done) }
        }
    }

    /// Keep each picture's audio. Turning it off ends a recording in
    /// progress (what was recorded is kept).
    func setSaveAudio(_ on: Bool) {
        lock.withLock {
            saveAudio = on
            if !on, let done = recorder.finish() { attach(done) }
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
            if let done = recorder.finish() { attach(done) }

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
                lastBufferUptime: lastBufferEnd,
                recordingTail: recorder.isRecordingTail
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
                if let done = recorder.gap(inputCount: Int(gap)) { attach(done) }
            }
            // The recorder first, so a picture starting in this buffer
            // finds the buffer already in its pre-roll.
            if let done = recorder.feed(samples, count: count) { attach(done) }
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
            // As much again as the picture takes to send, however it ended
            // (the decoder may have called the end early). After a loss, at
            // least the resume window (120 s, and a few lines more to notice
            // the return), in case it comes back on the same lines.
            let margin = Self.sendSeconds(mode: s.mode)
            recorder.end(after: s.end == .lost ? max(130, margin) : margin)
        }

        if newPicture {
            let mode = s.mode ?? "?"
            let resumed = !prev.receiving && s.relocks > prev.relocks && current != nil
            if resumed {
                events.append(.resumed(mode: mode))
                recorder.keepGoing()
            } else {
                let started = Date()
                current = Reception(
                    id: ReceptionStore.makeID(startedAt: started, mode: mode),
                    startedAt: started,
                    mode: mode,
                    visCode: s.start == .vis ? s.lastVIS : nil,
                    confirmed: s.start == .vis
                )
                events.append(.started(mode: mode, viaVIS: s.start == .vis))

                // A new recording (the previous one, if any, ends here).
                let done = saveAudio && current != nil
                    ? recorder.begin(id: current!.id, before: Self.sendSeconds(mode: mode))
                    : recorder.finish()
                if let done { attach(done) }
            }
        }

        if s.receiving, var r = current, !r.confirmed, s.line >= Self.minRows(s) {
            r.confirmed = true
            current = r
            events.append(.confirmed(mode: r.mode))
        }
    }

    /// Saves the picture in the RGBA copy as the current reception.
    /// A resumed picture is saved again over the same folder.
    private func save(_ s: SSTVStatus) {
        guard let r = current else { return }

        // Too few rows to count as a picture (false sync starts end up
        // here too) is still kept, as a fragment: its raw audio may hold
        // the whole picture, for the darkroom. It's kept quietly (no tap,
        // no notice), and the gallery keeps fragments apart.
        let fragment = s.line < Self.minRows(s)
        guard s.line >= 1, let image = decoder.makeImage() else {
            events.append(.finished(mode: r.mode, end: s.end, saved: false, updated: false))
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
        // (A fragment isn't counted as saved, so if it resumes into a
        // picture, that picture is.)
        let updated = fragment ? false : !savedIDs.insert(r.id).inserted
        events.append(.finished(mode: r.mode, end: s.end, saved: !fragment, updated: updated))

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

    /// Files a finished recording with its picture, then sends it on.
    /// If the picture wasn't kept (no rows at all), the recording is dropped.
    private func attach(_ done: RawAudioRecorder.Finished) {
        saveQueue.async {
            let kept = (try? ReceptionStore.attachAudio(id: done.id, from: done.url, info: done.info)) ?? false
            #if os(watchOS)
            if kept { WatchSync.shared.sendAudio(id: done.id) }
            #else
            _ = kept
            #endif
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
    /// Why listening last stopped by itself (nil after Listen, or a Stop).
    @Published private(set) var stoppedBy: AutoStopReason?
    /// Seconds until the receive timeout stops listening, in its last
    /// two minutes; nil otherwise.
    @Published private(set) var stopsIn: Int?

    /// Start a picture from its line syncs when the VIS header was missed
    /// (the decoder's autosync). On by default, as on the iPod; remembered.
    @Published var autosync: Bool = UserDefaults.standard.object(forKey: "rx.autosync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autosync, forKey: "rx.autosync")
            core?.setAutosync(autosync)
        }
    }

    /// Keep each picture's audio with it (audio.wav), to share or decode
    /// again later. On by default; remembered.
    @Published var saveAudio: Bool = UserDefaults.standard.object(forKey: "rx.saveAudio") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(saveAudio, forKey: "rx.saveAudio")
            core?.setSaveAudio(saveAudio)
        }
    }

    /// iPhone: raw audio at the input's own rate (usually 48 kHz) instead
    /// of the decoder's 12 kHz. Takes effect at the next Listen; remembered.
    @Published var fullRateAudio: Bool = UserDefaults.standard.bool(forKey: "rx.audioFullRate") {
        didSet { UserDefaults.standard.set(fullRateAudio, forKey: "rx.audioFullRate") }
    }

    /// The one mode to receive (its VIS code), or nil for any mode, found
    /// from the VIS header. Takes effect for the next picture; remembered.
    @Published var chosenMode: Int? = Receiver.loadChosenMode() {
        didSet {
            UserDefaults.standard.set(chosenMode ?? -1, forKey: "rx.mode")
            core?.setMode(vis: chosenMode)
        }
    }

    /// Watch: what lowering the wrist or leaving the app does to
    /// listening. Keeps listening by default (what anyone expects after
    /// tapping Listen); chosen at first launch; remembered.
    @Published var wristPolicy: WristPolicy = WristPolicy(
        rawValue: UserDefaults.standard.string(forKey: "rx.wristPolicy") ?? ""
    ) ?? .keep {
        didSet {
            UserDefaults.standard.set(wristPolicy.rawValue, forKey: "rx.wristPolicy")
            updateLeaving()
        }
    }

    /// Stop listening after this many minutes without a picture; 0 never.
    /// 10 by default; remembered.
    @Published var timeoutMinutes: Int = UserDefaults.standard.object(forKey: "rx.timeout") as? Int ?? 10 {
        didSet {
            UserDefaults.standard.set(timeoutMinutes, forKey: "rx.timeout")
        }
    }

    static let timeoutChoices = [0, 5, 10, 15, 30]

    /// "Waiting for VIS", or for the one mode chosen.
    var waitingText: String {
        if let vis = chosenMode, let name = SSTVDecoder.modeName(vis: vis) {
            return String(localized: "Waiting for \(name)")
        }
        return String(localized: "Waiting for VIS")
    }

    private static func loadChosenMode() -> Int? {
        guard let vis = UserDefaults.standard.object(forKey: "rx.mode") as? Int,
              SSTVDecoder.isSupported(vis: vis)
        else { return nil }
        return vis
    }

    init() {
        // Nothing is recording yet: anything in .recording is from a run
        // that ended mid-picture.
        ReceptionStore.removeLeftoverRecordings()
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
    /// When the last picture ended, or listening began (nil during a picture).
    private var idleSince: Double?
    /// When the wrist went down or the app was left, if that should stop
    /// listening (see wristPolicy).
    private var leftSince: Double?
    /// A short look away doesn't stop it.
    private static let leaveGrace = 5.0

    // MARK: Start / stop

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        notice = nil
        stoppedBy = nil

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
        // Cleared first: the poll below must not decide to stop again.
        idleSince = nil
        leftSince = nil
        stopsIn = nil
        stoppedBy = nil
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
        idleSince = ProcessInfo.processInfo.systemUptime
        leftSince = nil
        updateLeaving()
        setScreenStaysOn(true)
        startPolling()
    }

    /// A decoder for the input's current rate.
    private func makeCore() throws -> ReceiverCore {
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate >= 8000, format.channelCount > 0 else {
            throw ReceiverError.noInput
        }
        #if os(iOS)
        let fullRate = fullRateAudio
        #else
        let fullRate = false            // 5 minutes held at 48 kHz is too much for the watch
        #endif
        guard let core = ReceiverCore(sampleRate: format.sampleRate, device: Self.deviceName, fullRateAudio: fullRate) else {
            throw ReceiverError.decoder
        }
        core.setAutosync(autosync)
        core.setMode(vis: chosenMode)
        core.setSaveAudio(saveAudio)
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
        updateLeaving()
        if visible { poll() }
    }

    /// Watch: starts (or cancels) the countdown to stopping when the
    /// wrist goes down or the app is left, as wristPolicy says.
    private func updateLeaving() {
        #if os(watchOS)
        let leaving = switch wristPolicy {
        case .stop: !active
        case .keepWhenDimmed: !visible
        case .keep: false
        }
        if leaving && isRunning {
            if leftSince == nil { leftSince = ProcessInfo.processInfo.systemUptime }
        } else {
            leftSince = nil
        }
        #endif
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

    /// Active: everything. Dimmed (wrist down): the status line only; the
    /// picture when one starts or is saved. Hidden: nothing for the UI;
    /// events (haptics) and stopping still run.
    private func poll() {
        guard let core else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Dimmed too: the picture, the rows and the progress move together,
        // once a second, so it never looks stuck.
        let snap = core.snapshot(includeImage: visible)

        if visible {
            if let image = snap.image { picture = image }
            if status != snap.status { status = snap.status }
            lostSeconds = Double(snap.lostSamples) / core.sampleRate
            if isRunning, snap.lastBufferUptime > 0 {
                let silent = now - snap.lastBufferUptime > 2
                if silent != stalled { stalled = silent }
            }
        }
        if active {
            levelDB = snap.levelDB
            clipping = snap.clipping
        }

        for event in core.drainEvents() {
            handle(event)
        }

        if notice != nil, now > noticeUntil { notice = nil }
        if isRunning { checkAutoStop(snap, now: now) }
    }

    // MARK: Stopping by itself

    /// The countdown is shown for this long before the timeout.
    private static let countdownSeconds = 120.0

    /// Starts the timeout over, as if a picture had just ended.
    func keepListening() {
        guard isRunning else { return }
        idleSince = ProcessInfo.processInfo.systemUptime
        stopsIn = nil
    }

    /// Stops after the timeout without a picture, or once the wrist is down
    /// or the app left (wristPolicy), but never during a picture or the
    /// recording's margin after it: those are finished first.
    private func checkAutoStop(_ snap: ReceiverSnapshot, now: Double) {
        guard !restarting else { return }
        let s = snap.status
        if s.receiving {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now
        }

        // The last two minutes before the timeout are counted down.
        var left: Int?
        if !s.receiving, timeoutMinutes > 0, let idle = idleSince {
            let remaining = Double(timeoutMinutes) * 60 - (now - idle)
            if remaining <= Self.countdownSeconds { left = max(0, Int(remaining.rounded(.up))) }
        }
        if left != stopsIn { stopsIn = left }

        guard !s.receiving, !snap.recordingTail else { return }

        let reason: AutoStopReason
        if let since = leftSince, now - since >= Self.leaveGrace {
            reason = visible ? .dimmed : .left
        } else if let left, left == 0 {
            reason = .timeout
        } else {
            return
        }

        // A picture was just saved: let its tap finish first (the next
        // poll stops), so the two are felt apart.
        guard now - Haptics.lastPlayed >= 1.5 else { return }

        Haptics.stop()
        stop()
        stoppedBy = reason
        // Shown until the next Listen, so it's there when the wrist comes up.
        let day = 86_400.0
        switch reason {
        case .dimmed: show("Stopped when the screen dimmed", seconds: day)
        case .left: show("Stopped after leaving the app", seconds: day)
        case .timeout: show("No picture for \(timeoutMinutes) min: stopped", seconds: day)
        }
    }

    /// Haptics and notices for one event. True if the picture changed
    /// (one started, or was saved).
    @discardableResult
    private func handle(_ event: ReceiverEvent) -> Bool {
        switch event {
        case let .started(mode, viaVIS):
            // A sync start may be a false start: it taps once confirmed.
            if viaVIS { Haptics.start() }
            show("\(mode) started", seconds: 3)
            return true
        case .confirmed:
            Haptics.start()
            return false
        case let .resumed(mode):
            Haptics.start()
            show("\(mode) resumed", seconds: 3)
            return false
        case let .finished(mode, end, saved, updated):
            guard saved else { return false }
            if !updated { savedCount += 1 }
            switch end {
            case .complete:
                Haptics.success()
                show("\(mode) saved", seconds: 5)
            case .lost:
                Haptics.lost()
                show("\(mode) saved: signal lost", seconds: 5)
            case .noMemory:
                Haptics.failure()
                show("\(mode) saved: out of memory", seconds: 5)
            default:
                // Stopped, or a new picture took over: no tap.
                show("\(mode) saved", seconds: 5)
            }
            return true
        case let .skipped(mode, vis):
            if let chosen = chosenMode, SSTVDecoder.isSupported(vis: vis) {
                let name = SSTVDecoder.modeName(vis: chosen) ?? String(localized: "the chosen mode")
                show("Skipped \(mode): receiving \(name) only", seconds: 8)
            } else {
                show("Skip \(mode): not supported", seconds: 5)
            }
            return false
        case let .saveFailed(message):
            Haptics.failure()
            show("Save failed: \(message)", seconds: 30)
            return false
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

/// One tap per change of state, so the watch can be followed without
/// looking: a picture starts (or resumes), is saved, is lost, or
/// listening stops by itself.
@MainActor
enum Haptics {
    /// Uptime of the last tap, so two aren't played on top of each other.
    private(set) static var lastPlayed: Double = 0

    static func start() {
        #if os(watchOS)
        play(.start)
        #else
        played()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if os(watchOS)
        play(.success)
        #else
        played()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// The signal was lost; what came in was saved.
    static func lost() {
        #if os(watchOS)
        play(.directionDown)
        #else
        played()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func failure() {
        #if os(watchOS)
        play(.failure)
        #else
        played()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Listening stopped by itself (timeout, wrist down). On the iPhone,
    /// ContentView's feedback for isRunning already plays it.
    static func stop() {
        #if os(watchOS)
        play(.stop)
        #else
        played()
        #endif
    }

    private static func played() {
        lastPlayed = ProcessInfo.processInfo.systemUptime
    }

    #if os(watchOS)
    private static func play(_ type: WKHapticType) {
        played()
        WKInterfaceDevice.current().play(type)
    }
    #endif
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
