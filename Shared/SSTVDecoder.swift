// SPDX-License-Identifier: GPL-3.0-only
//
//  SSTVDecoder.swift
//  Swift wrapper around the C SSTV core (Core/sstv_dsp.c).
//
//  Not thread-safe: like the C core, one owner calls everything.
//  The receiver keeps it behind a lock.
//

import Foundation
import CoreGraphics

// MARK: - Status

nonisolated struct SSTVStatus: Sendable, Equatable {
    nonisolated enum Start: Sendable, Equatable {
        case none, vis, sync
    }

    nonisolated enum End: Sendable, Equatable {
        case none, complete, lost, aborted, newVIS, noMemory
    }

    var receiving: Bool
    var mode: String?
    /// Picture size as sent (PD120: 640 × 496).
    var width: Int
    var height: Int
    /// Rows decoded, counted in `height`.
    var line: Int
    var start: Start
    var end: End
    var lastVIS: Int?
    var lastVISSupported: Bool
    var toneHz: Int
    var offsetHz: Int
    /// Sender's clock against ours; a prior until `ppmValid`.
    var ppm: Int
    var ppmValid: Bool
    var syncGood: Int
    var syncSeen: Int
    var relocks: Int
    var images: Int
    var revision: UInt32
    /// Where the picture's line 0 sync starts, seconds into the audio fed.
    var startSeconds: Double
    /// The clock error as fitted right now, whether or not it's settled.
    var ppmFit: Double

    var progress: Double {
        height > 0 ? min(1, Double(line) / Double(height)) : 0
    }

    var syncPercent: Int? {
        syncSeen > 0 ? syncGood * 100 / syncSeen : nil
    }

    init(_ c: SstvStatus) {
        receiving = Int(c.state) == Int(SSTV_RX)
        mode = c.mode.map { String(cString: $0) }
        width = Int(c.width)
        height = Int(c.height)
        line = Int(c.line)

        switch Int(c.start_kind) {
        case Int(SSTV_START_VIS): start = .vis
        case Int(SSTV_START_SYNC): start = .sync
        default: start = .none
        }

        switch Int(c.end_kind) {
        case Int(SSTV_END_COMPLETE): end = .complete
        case Int(SSTV_END_LOST): end = .lost
        case Int(SSTV_END_ABORT): end = .aborted
        case Int(SSTV_END_NEWVIS): end = .newVIS
        case Int(SSTV_END_NOMEM): end = .noMemory
        default: end = .none
        }

        lastVIS = c.last_vis >= 0 ? Int(c.last_vis) : nil
        lastVISSupported = c.last_vis_ok != 0
        toneHz = Int(c.tone_hz)
        offsetHz = Int(c.offset_hz)
        ppm = Int(c.ppm)
        ppmValid = c.ppm_valid != 0
        syncGood = Int(c.sync_good)
        syncSeen = Int(c.sync_seen)
        relocks = Int(c.relocks)
        images = Int(c.images)
        revision = UInt32(c.revision)
        startSeconds = c.start_s
        ppmFit = c.ppm_fit
    }
}

// MARK: - Decoder

nonisolated final class SSTVDecoder {
    let sampleRate: Int

    private let rx: OpaquePointer
    private var pcm = [Int16](repeating: 0, count: 4096)

    // RGBA copy of the decoder's RGB565 picture, kept up to date from its
    // dirty rows. It also holds the previous picture for a moment after a
    // new VIS replaces it inside the core, so that picture can still be saved.
    private var rgba: [UInt32] = []
    private(set) var pictureWidth = 0
    private(set) var pictureHeight = 0

    /// nil if the rate is below 8000 Hz or memory ran out.
    init?(sampleRate: Int) {
        guard let rx = sstv_new(Int32(sampleRate)) else { return nil }
        self.rx = rx
        self.sampleRate = sampleRate
    }

    deinit {
        sstv_free(rx)
    }

    /// Feeds Float32 samples (±1.0 full scale).
    func feed(_ samples: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let n = min(pcm.count, count - done)
            pcm.withUnsafeMutableBufferPointer { out in
                for i in 0..<n {
                    let v = samples[done + i]
                    let c: Float = v >= 1 ? 1 : v <= -1 ? -1 : v.isNaN ? 0 : v
                    out[i] = Int16((c * 32767).rounded())
                }
                sstv_feed(rx, UnsafePointer(out.baseAddress!), Int32(n), 1)
            }
            done += n
        }
    }

    /// Feeds 16-bit samples as they are (a recording read back).
    func feed(int16 samples: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        sstv_feed(rx, samples, Int32(clamping: count), 1)
    }

    // MARK: Darkroom

    /// Starts a picture of this mode with its line 0 sync `seconds` into
    /// the audio, before any is fed; from then on no VIS or line syncs start
    /// another, and it never ends as lost. False if the mode isn't decoded.
    func start(vis: Int, at seconds: Double, offsetHz: Double = 0) -> Bool {
        sstv_start_at(rx, Int32(clamping: vis), seconds, offsetHz) != 0
    }

    /// Fixes the line period at this clock error (ppm) instead of fitting it.
    func setSlant(ppm: Double?) {
        sstv_set_slant(rx, ppm == nil ? 0 : 1, ppm ?? 0)
    }

    /// Samples every line this much later (the picture moves left).
    func setShift(milliseconds: Double) {
        sstv_set_shift(rx, milliseconds)
    }

    /// `count` samples were lost; keeps the picture's timing exact.
    func gap(_ count: Int) {
        guard count > 0 else { return }
        sstv_gap(rx, Int32(clamping: count))
    }

    var status: SSTVStatus {
        var c = SstvStatus()
        sstv_status(rx, &c)
        return SSTVStatus(c)
    }

    func abort() { sstv_abort(rx) }
    func clear() { sstv_clear(rx) }
    func setAutosync(_ on: Bool) { sstv_set_autosync(rx, on ? 1 : 0) }
    func setPPMPrior(_ ppm: Int) { sstv_set_ppm_prior(rx, Int32(clamping: ppm)) }
    /// Receive only the mode with this VIS code; nil = any mode.
    func setMode(vis: Int?) { sstv_set_mode(rx, Int32(clamping: vis ?? -1)) }

    static func modeName(vis: Int) -> String? {
        sstv_vis_name(Int32(vis)).map { String(cString: $0) }
    }

    static func isSupported(vis: Int) -> Bool {
        sstv_vis_supported(Int32(vis)) != 0
    }

    // MARK: Picture

    /// Copies the rows the core changed into the RGBA copy.
    /// Returns true if the picture changed.
    @discardableResult
    func updatePicture() -> Bool {
        var w: Int32 = 0
        var h: Int32 = 0
        var y0: Int32 = 0
        var y1: Int32 = 0
        let dirty = sstv_dirty(rx, &y0, &y1) != 0

        guard let src = sstv_image(rx, &w, &h), w > 0, h > 0 else { return false }
        let width = Int(w)
        let height = Int(h)

        if width != pictureWidth || height != pictureHeight {
            pictureWidth = width
            pictureHeight = height
            rgba = [UInt32](repeating: 0xFF00_0000, count: width * height)
            convert(src, rows: 0...(height - 1))
            return true
        }

        guard dirty else { return false }
        let lo = max(0, Int(y0))
        let hi = min(height - 1, Int(y1))
        guard lo <= hi else { return false }
        convert(src, rows: lo...hi)
        return true
    }

    /// The RGBA copy as an image (as of the last `updatePicture`).
    func makeImage() -> CGImage? {
        guard pictureWidth > 0, pictureHeight > 0 else { return nil }
        let data = rgba.withUnsafeBytes { Data($0) }
        guard
            let provider = CGDataProvider(data: data as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        return CGImage(
            width: pictureWidth,
            height: pictureHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pictureWidth * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// RGB565 → bytes R, G, B, 0xFF in memory.
    private func convert(_ src: UnsafePointer<UInt16>, rows: ClosedRange<Int>) {
        let width = pictureWidth
        rgba.withUnsafeMutableBufferPointer { dst in
            for y in rows {
                let base = y * width
                for x in 0..<width {
                    let p = UInt32(src[base + x])
                    let r = (p >> 11) & 0x1F
                    let g = (p >> 5) & 0x3F
                    let b = p & 0x1F
                    let r8 = (r << 3) | (r >> 2)
                    let g8 = (g << 2) | (g >> 4)
                    let b8 = (b << 3) | (b >> 2)
                    dst[base + x] = r8 | (g8 << 8) | (b8 << 16) | 0xFF00_0000
                }
            }
        }
    }
}
