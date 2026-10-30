// SPDX-License-Identifier: GPL-3.0-only
//
//  SSTVEncoder.swift
//  Swift wrapper around the C encoder (Core/enc.c, copied unchanged
//  from the iPod repository's host tools, where it drives the decoder
//  tests). Phase-continuous FM synthesis of the 14 modes the decoder
//  receives, VIS header included.
//

import Foundation
import Accelerate

nonisolated struct SSTVMode: Identifiable, Hashable, Sendable {
    let vis: Int
    let name: String
    /// Picture size the mode sends.
    let width: Int
    let height: Int
    /// Approximate length of a transmission.
    let seconds: Int

    var id: Int { vis }

    /// Every mode, in the order a picker shows them.
    static let all: [SSTVMode] = [
        (8, 36), (12, 72),
        (44, 114), (40, 58),
        (60, 110), (56, 71), (76, 269),
        (93, 50), (99, 90), (95, 126), (98, 161), (96, 187), (97, 248), (94, 289)
    ].compactMap { vis, seconds in
        var w: Int32 = 0
        var h: Int32 = 0
        guard enc_mode_size(Int32(vis), &w, &h) != 0,
              let name = enc_mode_name(Int32(vis)).map({ String(cString: $0) })
        else { return nil }
        return SSTVMode(vis: vis, name: name, width: Int(w), height: Int(h), seconds: seconds)
    }

    static func byVIS(_ vis: Int) -> SSTVMode? {
        all.first { $0.vis == vis }
    }

    var lengthText: String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

nonisolated enum SSTVEncoder {
    /// Encodes a picture. `rgb` is width × height × 3 bytes at the mode's
    /// size. Returns mono Float32 samples (±1.0), or nil on failure.
    ///
    /// - amplitude: peak level, 0…1.
    /// - leadSeconds / tailSeconds: silence before and after.
    static func encode(
        rgb: [UInt8],
        mode: SSTVMode,
        sampleRate: Int,
        amplitude: Double = 0.5,
        leadSeconds: Double = 0.2,
        tailSeconds: Double = 0.5
    ) -> [Float]? {
        guard rgb.count == mode.width * mode.height * 3, sampleRate >= 8000 else { return nil }

        var opts = EncOpts()
        enc_default_opts(&opts)
        opts.mode = Int32(mode.vis)
        opts.vis_code = Int32(mode.vis)
        opts.rate = Int32(sampleRate)
        opts.amplitude = max(0, min(1, amplitude)) * 32767
        opts.lead_s = leadSeconds
        opts.tail_s = tailSeconds

        var count = 0
        let samples = rgb.withUnsafeBufferPointer { buf in
            enc_encode(buf.baseAddress, &opts, &count)
        }
        guard let samples, count > 0 else { return nil }
        defer { free(samples) }

        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { dst in
            vDSP_vflt16(samples, 1, dst.baseAddress!, 1, vDSP_Length(count))
            var scale = Float(1.0 / 32768.0)
            vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(count))
        }
        return out
    }
}
