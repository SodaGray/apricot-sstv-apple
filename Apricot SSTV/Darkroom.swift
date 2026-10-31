// SPDX-License-Identifier: GPL-3.0-only
//
//  Darkroom.swift
//  Apricot SSTV
//
//  The darkroom: a received picture developed again from its raw audio.
//
//  Develop (冲洗) decodes the whole recording again with today's decoder:
//  every line re-timed against the slant fitted over the whole picture,
//  syncs found where the live decode missed them, the picture carried on
//  where the signal was weak. Then, by hand, starting from what Develop
//  found: the mode, where line 0 starts in the recording (moving the
//  picture up or down a line at a time), the slant (a fixed clock error
//  instead of the fitted one) and the horizontal position.
//
//  The slant can also be measured on the picture: two marks put on one
//  edge that should be upright, or a region with upright edges in it
//  (how much each line is shifted against the lines a few below it, the
//  median of those). How far it leans, with the mode's line and scan
//  times, gives the change of clock error.
//
//  As in Photos, nothing is overwritten: Done saves edited.png and the
//  settings (edit.json) beside image.png and audio.wav, and Revert
//  removes them. Undo and Redo step back and forth through the changes
//  made here (a slider or fine control moved without a pause is one
//  step), each with the picture it gave. Every change is decoded again off the main thread; a
//  newer change cancels the decode in progress.
//

import SwiftUI
import Combine

// MARK: - Settings

nonisolated struct DevelopSettings: Codable, Sendable, Equatable {
    var format = 1
    /// The mode's VIS code.
    var vis: Int
    /// Where line 0's sync starts, seconds into audio.wav.
    var startSeconds: Double
    /// Fixed clock error (ppm); nil: fitted to the syncs.
    var ppm: Double?
    /// Lines sampled this much later (the picture moves left).
    var shiftMs: Double
    /// Where Develop found line 0 (what Reset goes back to).
    var detectedStart: Double?
}

/// The modes, in the order Settings and Send list them.
nonisolated enum DarkroomModes {
    static let all = [8, 12, 44, 40, 60, 56, 76, 93, 99, 95, 98, 96, 97, 94]

    /// Sync to sync (PD modes: two rows per period).
    static func period(vis: Int) -> Double {
        switch vis {
        case 8: 0.150
        case 12: 0.300
        case 44: 0.446446
        case 40: 0.226798
        case 60: 0.42822
        case 56: 0.277692
        case 76: 1.0503
        case 93: 0.38816
        case 99: 0.70304
        case 95: 0.50848
        case 98: 0.804416
        case 96: 0.75424
        case 97: 1.0
        case 94: 0.93728
        default: 0.5
        }
    }

    static func vis(named name: String) -> Int? {
        all.first { SSTVDecoder.modeName(vis: $0) == name }
    }

    /// One colour's (Y's, or green's) scan across the picture, in seconds.
    static func scanSeconds(vis: Int) -> Double {
        switch vis {
        case 8: 0.088
        case 12: 0.138
        case 44: 0.146432
        case 40: 0.073216
        case 60: 0.138240
        case 56: 0.088064
        case 76: 0.3456
        case 93: 0.09152
        case 99: 0.17024
        case 95: 0.1216
        case 98: 0.195584
        case 96: 0.18304
        case 97: 0.24448
        case 94: 0.2288
        default: 0.1
        }
    }

    /// Lines sent, and how many of them one sync period carries.
    static func lines(vis: Int) -> (count: Int, perPeriod: Int) {
        switch vis {
        case 8, 12: (240, 1)
        case 44, 40, 60, 56, 76: (256, 1)
        case 93, 99: (256, 2)
        case 98: (400, 2)
        case 95, 96, 97: (496, 2)
        case 94: (616, 2)
        default: (256, 1)
        }
    }
}

// MARK: - Measuring the slant

nonisolated enum SlantMeasure {
    /// The change of clock error (ppm) that makes a picture leaning by
    /// `slope` (pixels to the right per row down) stand upright.
    ///
    /// Line n is read at n × the period the decoder assumes; if the sender's
    /// period is longer by d, every line starts d later in the picture, so
    /// what should be upright leans right by d per period, and the period
    /// (the clock error) must grow by d.
    static func ppmChange(slope: Double, vis: Int, imageWidth: Int, imageHeight: Int) -> Double {
        let lines = DarkroomModes.lines(vis: vis)
        let periods = Double(lines.count) / Double(lines.perPeriod)
        let rowsPerPeriod = Double(max(1, imageHeight)) / periods
        let secondsPerPixel = DarkroomModes.scanSeconds(vis: vis) / Double(max(1, imageWidth))
        let drift = slope * rowsPerPeriod * secondsPerPixel        // seconds per period
        return drift / DarkroomModes.period(vis: vis) * 1e6
    }

    /// How a region of the picture leans: pixels right per row down, and
    /// whether the rows agree on it (`sure`); nil if there's too little in
    /// it. `region` is in 0…1 of the picture.
    ///
    /// Each row's edges (the difference to the next pixel) are matched
    /// against the row k below, shifted; the median shift over the rows
    /// with most in them, over k, is the lean. First with k small and a
    /// wide search (a rough lean, safe from repeating patterns), then with
    /// k large and a narrow search around it (precise: a shift of a few
    /// pixels measured over many rows).
    static func slope(of image: CGImage, in region: CGRect) -> (slope: Double, sure: Bool)? {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return nil }
        var lum = [UInt8](repeating: 0, count: w * h)
        let drawn = lum.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let r = region.standardized
        let c0 = max(0, Int(r.minX * Double(w))), c1 = min(w - 2, Int(r.maxX * Double(w)))
        let r0 = max(0, Int(r.minY * Double(h))), r1 = min(h - 1, Int(r.maxY * Double(h)))
        guard c1 - c0 >= 12, r1 - r0 >= 6 else { return nil }

        // Edges across, row by row (w - 1 per row).
        var edges = [Float](repeating: 0, count: (w - 1) * h)
        for y in 0..<h {
            for x in 0..<(w - 1) {
                edges[y * (w - 1) + x] = Float(lum[y * w + x + 1]) - Float(lum[y * w + x])
            }
        }
        let stride = w - 1

        /// Median lean (px per row) matching rows k apart, searching shifts
        /// center ± reach; and the spread (interquartile, in pixels).
        func stage(k: Int, center: Int, reach: Int) -> (slope: Double, spread: Double)? {
            var pairs: [(shift: Double, energy: Float)] = []
            for row in r0...(r1 - k) {
                let a = row * stride, b = (row + k) * stride
                var energy: Float = 0
                for x in c0..<c1 { energy += edges[a + x] * edges[a + x] }
                var scores = [Float](repeating: -.infinity, count: 2 * reach + 1)
                var best = -Float.infinity, bestI = -1
                for i in 0...(2 * reach) {
                    let s = center - reach + i
                    let lo = max(c0, -s), hi = min(c1, stride - s)
                    guard hi > lo else { continue }
                    var sum: Float = 0
                    for x in lo..<hi { sum += edges[a + x] * edges[b + x + s] }
                    scores[i] = sum / Float(hi - lo)
                    if scores[i] > best { best = scores[i]; bestI = i }
                }
                guard bestI >= 0, best > 0 else { continue }
                var shift = Double(center - reach + bestI)
                // Between pixels: the peak of a parabola through three scores.
                if bestI > 0, bestI < 2 * reach, scores[bestI - 1].isFinite, scores[bestI + 1].isFinite {
                    let l = scores[bestI - 1], m = scores[bestI], rr = scores[bestI + 1]
                    let d = l - 2 * m + rr
                    if d < 0 { shift += Double(0.5 * (l - rr) / d) }
                }
                pairs.append((shift / Double(k), energy))
            }
            guard !pairs.isEmpty else { return nil }
            // Rows with little in them (flat sky) say nothing.
            let energies = pairs.map { $0.energy }.sorted()
            let floor = energies[energies.count / 2] * 0.5
            let shifts = pairs.filter { $0.energy >= floor && $0.energy > 0 }.map { $0.shift }.sorted()
            guard shifts.count >= 4 else { return nil }
            let spread = (shifts[(3 * shifts.count) / 4] - shifts[shifts.count / 4]) * Double(k)
            return (shifts[shifts.count / 2], spread)
        }

        let k = max(2, min(6, (r1 - r0) / 3))
        guard let rough = stage(k: k, center: 0, reach: min((c1 - c0) / 3, 2 * k + 1)) else { return nil }
        let bigK = max(k, min(32, (r1 - r0) / 2))
        guard bigK > k, let fine = stage(k: bigK, center: Int((rough.slope * Double(bigK)).rounded()), reach: 3) else {
            return (rough.slope, rough.spread <= 2.5)
        }
        return (fine.slope, fine.spread <= 2.5)
    }
}

// MARK: - Developing

nonisolated struct DevelopResult: @unchecked Sendable {
    let image: CGImage
    /// What was found (Develop) or given (by hand).
    let settings: DevelopSettings
    let rows: Int
    let height: Int
    let syncPercent: Int?
    /// The clock error the decoder fitted (where the slant slider starts).
    let ppmFit: Double
}

nonisolated enum Developer {
    enum Failure: LocalizedError {
        case noAudio, badAudio, noPicture

        var errorDescription: String? {
            switch self {
            case .noAudio: String(localized: "This picture has no raw audio.")
            case .badAudio: String(localized: "The raw audio can't be read.")
            case .noPicture: String(localized: "No picture was found in the raw audio.")
            }
        }
    }

    /// audio.wav as written by RawAudioRecorder: 16-bit mono PCM.
    static func readWAV(_ url: URL) throws -> (samples: [Int16], rate: Int) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else {
            throw Failure.badAudio
        }
        func le32(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24 }
        func le16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
        guard String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
        else { throw Failure.badAudio }

        var i = 12, rate = 0, channels = 0, bits = 0
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<(i + 4)], as: UTF8.self)
            var size = le32(i + 4)
            // A recording cut off before its header was finished says 0.
            if id == "data" && size == 0 { size = data.count - (i + 8) }
            let body = i + 8
            if id == "fmt " && body + 16 <= data.count {
                channels = le16(body + 2)
                rate = le32(body + 4)
                bits = le16(body + 14)
            } else if id == "data" {
                guard channels == 1, bits == 16, rate >= 8000 else { throw Failure.badAudio }
                let end = min(data.count, body + size)
                let count = (end - body) / 2
                var samples = [Int16](repeating: 0, count: count)
                samples.withUnsafeMutableBytes { dst in
                    data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: body..<(body + count * 2))
                }
                return (samples.map { Int16(littleEndian: $0) }, rate)
            }
            i = body + size + (size & 1)
        }
        throw Failure.badAudio
    }

    /// Decodes the recording again. `manual` nil: Develop (the decoder finds
    /// the picture, in the mode it was received in); otherwise by hand.
    static func develop(id: String, mode: String, manual: DevelopSettings?) throws -> DevelopResult {
        guard ReceptionStore.hasAudio(id: id) else { throw Failure.noAudio }
        let (samples, rate) = try readWAV(ReceptionStore.audioURL(for: id))
        guard let decoder = SSTVDecoder(sampleRate: rate) else { throw Failure.badAudio }

        let vis = manual?.vis ?? DarkroomModes.vis(named: mode)
        if let manual {
            decoder.setSlant(ppm: manual.ppm)
            decoder.setShift(milliseconds: manual.shiftMs)
            guard decoder.start(vis: manual.vis, at: max(0, manual.startSeconds)) else { throw Failure.noPicture }
        } else {
            decoder.setMode(vis: vis)
        }

        // Feed it all, keeping the picture with the most rows: the one this
        // recording was made for (others may sit in its margins).
        var best: (image: CGImage, status: SSTVStatus, rows: Int)?
        func consider(_ image: CGImage?, _ status: SSTVStatus, rows: Int) {
            guard let image, rows > (best?.rows ?? 0) else { return }
            best = (image, status, rows)
        }

        var prev = decoder.status
        let chunk = 2048
        var at = 0
        try samples.withUnsafeBufferPointer { buf in
            while at < buf.count {
                if (at / chunk) % 64 == 0 { try Task.checkCancellation() }
                let n = min(chunk, buf.count - at)
                decoder.feed(int16: buf.baseAddress! + at, count: n)
                at += n
                let st = decoder.status
                if prev.receiving && st.receiving && st.line < prev.line {
                    consider(decoder.makeImage(), prev, rows: prev.line)    // replaced by another
                }
                decoder.updatePicture()
                if prev.receiving && !st.receiving {
                    consider(decoder.makeImage(), st, rows: max(st.line, prev.line))
                }
                prev = st
            }
        }
        if prev.receiving {
            decoder.updatePicture()
            consider(decoder.makeImage(), prev, rows: prev.line)
        }

        guard let best else { throw Failure.noPicture }
        let s = best.status
        let settings = manual ?? DevelopSettings(
            vis: vis ?? DarkroomModes.vis(named: s.mode ?? "") ?? 44,
            startSeconds: s.startSeconds,
            ppm: nil,
            shiftMs: 0,
            detectedStart: s.startSeconds
        )
        return DevelopResult(
            image: best.image,
            settings: settings,
            rows: best.rows,
            height: s.height,
            syncPercent: s.syncPercent,
            ppmFit: s.ppmFit
        )
    }
}

// MARK: - View

struct DarkroomView: View {
    let meta: ReceptionMeta

    @Environment(\.dismiss) private var dismiss

    @State private var image: CGImage?
    @State private var original: CGImage?
    @State private var showingOriginal = false

    /// The settings the picture on screen was developed with; nil until
    /// the first Develop (or an earlier edit) gives a starting point.
    @State private var settings: DevelopSettings?
    @State private var lastPPM: Double = 0
    @State private var report: String?
    @State private var developed = false            // something new to save
    @State private var working = false
    @State private var job: Task<Void, Never>?
    /// Settings changed while a decode by hand was running: decoded next.
    @State private var pending: DevelopSettings?
    @State private var errorMessage: String?
    @State private var duration: Double = 0
    @State private var confirmRevert = false
    /// Reverted here: Done removes the saved edit (unless developed again).
    @State private var reverted = false

    /// Undo / Redo: the state before each change.
    @State private var undoStack: [Snapshot] = []
    @State private var redoStack: [Snapshot] = []
    @State private var lastContinuousEdit = Date.distantPast

    struct Snapshot {
        var settings: DevelopSettings?
        var developed: Bool
        var reverted: Bool
        var image: CGImage?
        var shown: (settings: DevelopSettings, ppm: Double)?
        var report: String?
        /// The picture matched the settings (no decode was running).
        var settled: Bool
    }

    /// The settings and clock error the picture on screen was developed
    /// with: what a slant measured on it is measured against.
    @State private var shown: (settings: DevelopSettings, ppm: Double)?
    /// Measuring the slant on the picture.
    @State private var tool: SlantTool?
    @State private var markA = CGPoint(x: 0.5, y: 0.2)     // 0…1 of the picture
    @State private var markB = CGPoint(x: 0.5, y: 0.8)
    @State private var dragging: (mark: Int, from: CGPoint)?
    @State private var region: CGRect?
    @State private var regionStart: CGPoint?
    /// The change of clock error measured, nil: nothing to apply.
    @State private var measured: Double?
    @State private var measureFailed = false
    /// The rows didn't agree well: shown, but marked.
    @State private var measureUnsure = false

    enum SlantTool { case twoPoints, region }

    private var hasSavedEdit: Bool { ReceptionStore.hasEdit(id: meta.id) }

    var body: some View {
        NavigationStack {
            // The picture stays at the top while the controls scroll under
            // it: whatever is being adjusted, its effect is in view.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    pictureHeader(maxHeight: geo.size.height * 0.42)
                    controls
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Darkroom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { job?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(working)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        undo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(undoStack.isEmpty)
                    Button {
                        redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(redoStack.isEmpty)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Revert to Original", role: .destructive) {
                        confirmRevert = true
                    }
                    .tint(.red)
                    .disabled(!developed && !(hasSavedEdit && !reverted))
                    // On the button, so it comes up from it, not mid-screen.
                    .confirmationDialog(
                        "Revert to the picture as received?",
                        isPresented: $confirmRevert,
                        titleVisibility: .visible
                    ) {
                        Button("Revert to Original", role: .destructive) {
                            record(continuous: false)
                            revert()
                        }
                    }
                }
            }
            .alert(
                errorMessage ?? "",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            }
        }
        // Dark, but only in here. preferredColorScheme(.dark) would turn the
        // whole window dark, the picture page behind included: it flashed
        // black as the darkroom came up.
        .environment(\.colorScheme, .dark)
        .task { await load() }
    }

    // MARK: Controls

    private var controls: some View {
        List {
            Section {
                Button {
                    record(continuous: false)
                    develop(manual: nil)
                } label: {
                    // Not a Label: in a list, a Label's icon takes the
                    // tint, the same colour as this button.
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text("Develop")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(working)
            } footer: {
                Text("Decodes the whole raw audio again with the latest decoder.")
            }

            if let settings {
                manualSections(settings)
            } else {
                Section {
                    Text("Develop once to adjust the picture by hand.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Picture

    private func pictureHeader(maxHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            picture
                .frame(maxHeight: max(120, maxHeight))
                .frame(maxWidth: .infinity)
            if let tool {
                toolBar(tool)
            } else {
                Text(report ?? String(localized: "Touch and hold the picture to see it as received."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
        .background(Color.black)
    }

    private var picture: some View {
        ZStack {
            Color.black
            if let shown = showingOriginal ? original : (image ?? original) {
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(pictureAspect, contentMode: .fit)
        // Small and in a corner: the picture stays in view while it's redone.
        .overlay(alignment: .topTrailing) {
            if working {
                ProgressView()
                    .tint(.white)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
            }
        }
        .overlay(alignment: .topLeading) {
            if showingOriginal {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in showingOriginal = true }
                .onEnded { _ in showingOriginal = false },
            including: tool == nil ? .all : .subviews
        )
        .overlay {
            if let tool {
                toolOverlay(tool)
            }
        }
        .accessibilityLabel(Text("Picture"))
        .accessibilityHint(Text("Touch and hold to see it as received."))
    }

    private var pictureAspect: CGFloat {
        if let img = image ?? original, img.height > 0 {
            return CGFloat(img.width) / CGFloat(img.height)
        }
        return CGFloat(max(1, meta.imageWidth)) / CGFloat(max(1, meta.imageHeight))
    }

    // MARK: Measuring the slant

    @ViewBuilder
    private func toolOverlay(_ tool: SlantTool) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let p = { (u: CGPoint) in CGPoint(x: u.x * size.width, y: u.y * size.height) }
            ZStack {
                switch tool {
                case .twoPoints:
                    Path { path in
                        path.move(to: p(markA))
                        path.addLine(to: p(markB))
                    }
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach([markA, markB].indices, id: \.self) { i in
                        Mark()
                            .position(p(i == 0 ? markA : markB))
                    }
                case .region:
                    if let region {
                        let r = CGRect(
                            x: region.minX * size.width, y: region.minY * size.height,
                            width: region.width * size.width, height: region.height * size.height
                        )
                        Path { $0.addRect(CGRect(origin: .zero, size: size)); $0.addRect(r) }
                            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 1.5)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(toolGesture(tool, size: size))
        }
    }

    private func toolGesture(_ tool: SlantTool, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let unit = { (pt: CGPoint) in
                    CGPoint(x: min(1, max(0, pt.x / max(1, size.width))), y: min(1, max(0, pt.y / max(1, size.height))))
                }
                switch tool {
                case .twoPoints:
                    // The mark nearest the touch follows the finger at half
                    // its speed, for precision, wherever the finger is.
                    if dragging == nil {
                        let start = unit(v.startLocation)
                        func d(_ m: CGPoint) -> CGFloat { hypot((m.x - start.x) * size.width, (m.y - start.y) * size.height) }
                        let i = d(markA) <= d(markB) ? 0 : 1
                        dragging = (i, i == 0 ? markA : markB)
                    }
                    guard let drag = dragging else { return }
                    let moved = CGPoint(
                        x: min(1, max(0, drag.from.x + v.translation.width * 0.5 / max(1, size.width))),
                        y: min(1, max(0, drag.from.y + v.translation.height * 0.5 / max(1, size.height)))
                    )
                    if drag.mark == 0 { markA = moved } else { markB = moved }
                    measureTwoPoints()
                case .region:
                    let a = unit(v.startLocation), b = unit(v.location)
                    region = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    measured = nil
                    measureFailed = false
                    measureUnsure = false
                }
            }
            .onEnded { _ in
                dragging = nil
                if tool == .region { measureRegion() }
            }
    }

    private func toolBar(_ tool: SlantTool) -> some View {
        HStack(spacing: 12) {
            Button("Cancel") { self.tool = nil }
            Spacer(minLength: 0)
            Group {
                if let value = measured.map({ String(format: "%+.1f ppm", $0) }) {
                    if measureUnsure {
                        Text("\(value) (unsure)").monospacedDigit()
                    } else {
                        Text(verbatim: value).monospacedDigit()
                    }
                } else if measureFailed {
                    Text(tool == .region ? LocalizedStringKey("Nothing upright found here") : LocalizedStringKey("Put the marks further apart"))
                } else {
                    Text(tool == .region ? LocalizedStringKey("Drag across upright edges") : LocalizedStringKey("Drag both marks onto one upright edge"))
                }
            }
            .font(.footnote)
            .foregroundStyle(measureFailed || (measured != nil && measureUnsure) ? Color.orange : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button("Apply") { applyMeasured() }
                .fontWeight(.semibold)
                .disabled(measured == nil || working)
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .frame(minHeight: 28)
    }

    private func startTool(_ t: SlantTool) {
        markA = CGPoint(x: 0.5, y: 0.2)
        markB = CGPoint(x: 0.5, y: 0.8)
        region = nil
        measured = nil
        measureFailed = false
        measureUnsure = false
        tool = t
        if t == .twoPoints { measureTwoPoints() }
    }

    private func measureTwoPoints() {
        guard let shown, let img = image else { measured = nil; return }
        let dx = Double(markB.x - markA.x) * Double(img.width)
        let dy = Double(markB.y - markA.y) * Double(img.height)
        measureUnsure = false
        guard abs(dy) >= 8 else { measured = nil; measureFailed = true; return }
        measureFailed = false
        measured = SlantMeasure.ppmChange(slope: dx / dy, vis: shown.settings.vis, imageWidth: img.width, imageHeight: img.height)
    }

    private func measureRegion() {
        guard let shown, let img = image, let region else { measured = nil; return }
        if let m = SlantMeasure.slope(of: img, in: region) {
            measured = SlantMeasure.ppmChange(slope: m.slope, vis: shown.settings.vis, imageWidth: img.width, imageHeight: img.height)
            measureUnsure = !m.sure
            measureFailed = false
        } else {
            measured = nil
            measureFailed = true
        }
    }

    /// The clock error the picture was developed with, changed by what was
    /// measured: fitting goes off.
    private func applyMeasured() {
        guard let shown, let measured else { return }
        let ppm = min(1000, max(-1000, ((shown.ppm + measured) * 10).rounded() / 10))
        tool = nil
        update { $0.ppm = ppm }
    }

    // MARK: By hand

    @ViewBuilder
    private func manualSections(_ s: DevelopSettings) -> some View {
        Section {
            Picker("Mode", selection: binding(\.vis)) {
                ForEach(DarkroomModes.all, id: \.self) { vis in
                    Text(verbatim: SSTVDecoder.modeName(vis: vis) ?? "VIS \(vis)").tag(vis)
                }
            }
        }

        Section {
            LabeledContent("Line 0 starts at") {
                Text(String(format: "%.3f s", s.startSeconds)).monospacedDigit()
            }
            Slider(value: binding(\.startSeconds, continuous: true), in: 0...max(1, duration))
            FineRow(maxRate: 0.5, step: 0.001) { d in
                update(continuous: true) { $0.startSeconds = min(max(0, $0.startSeconds + d), max(1, duration)) }
            }
            HStack {
                Button {
                    nudgeStart(lines: 1)
                } label: {
                    Label("Picture Up", systemImage: "arrow.up")
                }
                Spacer()
                Button {
                    nudgeStart(lines: -1)
                } label: {
                    Label("Picture Down", systemImage: "arrow.down")
                }
            }
            .buttonStyle(.borderless)
            // Back to where Develop found the first line, as Center does for
            // the shift.
            Button("Reset to Detected") {
                if let found = s.detectedStart { update { $0.startSeconds = found } }
            }
            .buttonStyle(.borderless)
            .disabled(s.detectedStart == nil || s.detectedStart == s.startSeconds)
        } header: {
            Text("Vertical Position")
        }

        Section {
            Toggle("Fitted to the Syncs", isOn: Binding(
                get: { s.ppm == nil },
                set: { fitted in update { $0.ppm = fitted ? nil : lastPPM } }
            ))
            if let ppm = s.ppm {
                LabeledContent("Clock Error") {
                    Text(String(format: "%+.1f ppm", ppm)).monospacedDigit()
                }
                Slider(value: Binding(get: { ppm }, set: { v in update(continuous: true) { $0.ppm = v.rounded() } }), in: -1000...1000)
                FineRow(maxRate: 100, step: 0.1) { d in
                    update(continuous: true) { $0.ppm = min(max(-1000, ($0.ppm ?? 0) + d), 1000) }
                }
            }
            HStack {
                Button {
                    startTool(.twoPoints)
                } label: {
                    Label("Two Points", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Spacer()
                Button {
                    startTool(.region)
                } label: {
                    Label("From a Region", systemImage: "viewfinder")
                }
            }
            .buttonStyle(.borderless)
            .disabled(shown == nil || working || tool != nil)
        } header: {
            Text("Slant")
        }

        Section {
            LabeledContent("Shift") {
                Text(String(format: "%+.2f ms", s.shiftMs)).monospacedDigit()
            }
            Slider(value: Binding(get: { s.shiftMs }, set: { v in update(continuous: true) { $0.shiftMs = (v * 10).rounded() / 10 } }), in: -20...20)
            FineRow(maxRate: 4, step: 0.01) { d in
                update(continuous: true) { $0.shiftMs = min(max(-20, $0.shiftMs + d), 20) }
            }
            Button("Center") { update { $0.shiftMs = 0 } }
                .buttonStyle(.borderless)
                .disabled(s.shiftMs == 0)
        } header: {
            Text("Horizontal Position")
        }
    }

    private func binding<T>(_ key: WritableKeyPath<DevelopSettings, T>, continuous: Bool = false) -> Binding<T> {
        Binding(
            get: { settings![keyPath: key] },
            set: { v in update(continuous: continuous) { $0[keyPath: key] = v } }
        )
    }

    private func nudgeStart(lines: Int) {
        guard let s = settings else { return }
        update { $0.startSeconds = max(0, s.startSeconds + Double(lines) * DarkroomModes.period(vis: s.vis)) }
    }

    /// Changes the settings and develops again by hand. `continuous`: a
    /// slider or fine control, whose changes without a pause make one undo
    /// step.
    private func update(continuous: Bool = false, _ change: (inout DevelopSettings) -> Void) {
        guard var s = settings else { return }
        change(&s)
        guard s != settings else { return }
        record(continuous: continuous)
        settings = s
        if let ppm = s.ppm { lastPPM = ppm }
        develop(manual: s)
    }

    // MARK: Undo

    private var snapshot: Snapshot {
        Snapshot(
            settings: settings, developed: developed, reverted: reverted,
            image: image, shown: shown, report: report, settled: !working
        )
    }

    /// Keeps the state before a change, for Undo.
    private func record(continuous: Bool) {
        let now = Date.now
        if continuous {
            defer { lastContinuousEdit = now }
            if now.timeIntervalSince(lastContinuousEdit) < 1.0 { return }
        } else {
            lastContinuousEdit = .distantPast
        }
        undoStack.append(snapshot)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(step)
    }

    private func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(step)
    }

    /// Back to a kept state: its picture at once, decoded again only if it
    /// was still being decoded when kept.
    private func restore(_ step: Snapshot) {
        job?.cancel()
        job = nil
        pending = nil
        working = false
        tool = nil
        lastContinuousEdit = .distantPast
        settings = step.settings
        developed = step.developed
        reverted = step.reverted
        image = step.image
        shown = step.shown
        report = step.report
        if let ppm = step.settings?.ppm { lastPPM = ppm }
        if !step.settled, let s = step.settings {
            develop(manual: s)
        }
    }

    // MARK: Work

    private func load() async {
        let id = meta.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?, Data?, Double) in
            let info = ReceptionStore.audioInfo(id: id)
            let bytes = ReceptionStore.audioByteCount(id: id)
            let seconds = info.map { Double(max(0, bytes - 44) / 2) / Double(max(1, $0.sampleRate)) } ?? 0
            return (ReceptionStore.loadOriginalImage(id: id), ReceptionStore.loadImage(id: id), ReceptionStore.editSettings(id: id), seconds)
        }.value
        original = loaded.0
        image = loaded.1
        duration = loaded.3
        if let data = loaded.2, let saved = try? JSONDecoder().decode(DevelopSettings.self, from: data) {
            settings = saved
            if let ppm = saved.ppm {
                lastPPM = ppm
                shown = (saved, ppm)
            }
        }
    }

    /// Develop cancels whatever is running. A change by hand while a decode
    /// is running waits for it (the newest change only), so a slider or the
    /// fine control being moved shows a new picture as often as decoding
    /// allows, instead of only when it stops.
    private func develop(manual: DevelopSettings?) {
        if let manual, working, job != nil {
            pending = manual
            return
        }
        job?.cancel()
        pending = nil
        working = true
        let id = meta.id, mode = meta.mode
        job = Task {
            let work = Task.detached(priority: .userInitiated) {
                Result { try Developer.develop(id: id, mode: mode, manual: manual) }
            }
            let outcome = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            working = false
            job = nil
            switch outcome {
            case .success(let r):
                image = r.image
                developed = true
                shown = (r.settings, manual?.ppm ?? r.ppmFit)
                if manual == nil {
                    settings = r.settings
                    lastPPM = (r.ppmFit * 10).rounded() / 10
                }
                let rows = String(localized: "\(r.rows) of \(r.height) rows")
                if let pct = r.syncPercent {
                    report = rows + " · " + String(localized: "syncs found") + " \(pct)%"
                } else {
                    report = rows
                }
            case .failure(let error):
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            if let next = pending {
                pending = nil
                develop(manual: next)
            }
        }
    }

    /// Back to the picture as received, here only: the darkroom stays open,
    /// and nothing changes on disk until Done.
    private func revert() {
        job?.cancel()
        job = nil
        pending = nil
        working = false
        tool = nil
        image = nil                     // the original shows
        settings = nil
        shown = nil
        report = nil
        developed = false
        reverted = true
    }

    private func save() {
        job?.cancel()
        if !developed && reverted {
            ReceptionStore.revertEdit(id: meta.id)
            dismiss()
            return
        }
        guard developed, let image, let settings else { dismiss(); return }
        do {
            let data = try JSONEncoder().encode(settings)
            try ReceptionStore.saveEdit(id: meta.id, image: image, settings: data)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Marks

/// One of the two marks: a crosshair in a ring, easy to see on any picture.
private struct Mark: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.6), lineWidth: 3)
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Rectangle().fill(Color.yellow).frame(width: 1, height: 30)
            Rectangle().fill(Color.yellow).frame(width: 30, height: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Fine control

/// A "Fine" label and a control that springs back to the middle: held to
/// one side, it keeps changing the value above, slowly near the middle and
/// faster the further it's pulled (the speed grows with the square of the
/// pull), until it's let go.
struct FineRow: View {
    /// Change per second with the control pulled all the way.
    let maxRate: Double
    /// One step for VoiceOver's swipe up / down.
    let step: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Fine")
                .foregroundStyle(.secondary)
            JogControl(maxRate: maxRate, step: step, onChange: onChange)
        }
    }
}

private struct JogControl: View {
    let maxRate: Double
    let step: Double
    let onChange: (Double) -> Void

    /// -1 … 1: how far the knob is pulled.
    @State private var pull: Double = 0
    @State private var ticker: Task<Void, Never>?

    private static let knob = CGSize(width: 34, height: 24)

    var body: some View {
        GeometryReader { geo in
            let reach = max(1, (geo.size.width - Self.knob.width) / 2)
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 2, height: 12)
                Capsule()
                    .fill(.tint)
                    .frame(width: Self.knob.width, height: Self.knob.height)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(pull) * reach)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        pull = min(1, max(-1, Double(v.translation.width / reach)))
                        if ticker == nil { startTicking() }
                    }
                    .onEnded { _ in
                        ticker?.cancel()
                        ticker = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pull = 0 }
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text("Fine"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(step)
            case .decrement: onChange(-step)
            @unknown default: break
            }
        }
    }

    /// While held: 30 times a second, the change since the last tick.
    private func startTicking() {
        ticker = Task {
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                let now = clock.now
                let dt = (now - last) / .seconds(1)
                last = now
                let rate = maxRate * pull * abs(pull)
                if rate != 0 { onChange(rate * dt) }
            }
        }
    }
}
