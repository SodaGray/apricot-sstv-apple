// SPDX-License-Identifier: GPL-3.0-only
//
//  BuiltInPictures.swift
//  Apricot SSTV
//
//  The pictures that come with the app, in the photo menu's Built In:
//  the test card and colour bars (Favorites.swift draws them), and the
//  Mandelbrot set, drawn here to any centre, width and depth, with the
//  ten views of NeXTSTEP's Mandelbrot demo as presets. And two pictures
//  of grey stripes, titled only Ⅰ and Ⅱ, on purpose.
//

import SwiftUI

// MARK: - Mandelbrot

nonisolated struct MandelbrotParams: Equatable, Sendable {
    var centerX: Double
    var centerY: Double
    /// Width of the view, in the plane; the height follows the picture.
    var scaleX: Double
    /// Most iterations before a point counts as inside.
    var depth: Int

    static let home = MandelbrotParams(centerX: -0.5, centerY: 0, scaleX: 3, depth: 250)
}

nonisolated struct MandelbrotPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let view: MandelbrotParams

    static let all: [MandelbrotPreset] = [
        .init(id: "home", name: String(localized: "Home"), view: .home),
        .init(id: "blackhole", name: String(localized: "Black Hole"), view: .init(centerX: -0.709964, centerY: 0.269764, scaleX: 0.002271, depth: 300)),
        .init(id: "valley", name: String(localized: "Valley of Fear"), view: .init(centerX: -0.780374, centerY: 0.247664, scaleX: 0.364486, depth: 250)),
        .init(id: "gingerbread", name: String(localized: "Gingerbread Man"), view: .init(centerX: -0.725871, centerY: 0.251070, scaleX: 0.004542, depth: 250)),
        .init(id: "porcupine", name: String(localized: "Electric Porcupine"), view: .init(centerX: -0.198237, centerY: 1.100237, scaleX: 0.007176, depth: 250)),
        .init(id: "seahorse", name: String(localized: "Sea Horse"), view: .init(centerX: -0.733470, centerY: 0.213552, scaleX: 0.03, depth: 250)),
        .init(id: "party", name: String(localized: "Party"), view: .init(centerX: -0.728539, centerY: 0.223586, scaleX: 0.000115, depth: 250)),
        .init(id: "starfish", name: String(localized: "Starfish"), view: .init(centerX: -0.668225, centerY: 0.467290, scaleX: 0.121495, depth: 250)),
        .init(id: "yinyang", name: String(localized: "Yin Yang"), view: .init(centerX: -0.874049, centerY: 0.255267, scaleX: 0.0005, depth: 250)),
        .init(id: "jewel", name: String(localized: "Jewel"), view: .init(centerX: -0.916609, centerY: 0.314922, scaleX: 0.000874, depth: 250)),
    ]
}

nonisolated enum Mandelbrot {
    /// The size it's sent at: 4:3, enough for the largest mode.
    static let size = (width: 800, height: 600)

    /// Navy far out, through slate and teal to near white at the edge of
    /// the set (by the smoothed escape count, on a log scale), the inside
    /// darkest navy: after the NeXT demo.
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.00, (10, 14, 40)),
        (0.45, (24, 38, 72)),
        (0.70, (36, 104, 118)),
        (0.85, (80, 196, 186)),
        (0.95, (200, 255, 240)),
        (1.00, (255, 255, 255)),
    ]
    private static let inside: (UInt8, UInt8, UInt8) = (8, 10, 32)

    private static func color(_ mu: Double, depth: Int) -> (UInt8, UInt8, UInt8) {
        let u = min(1, max(0, log(mu + 1) / log(Double(depth) + 1)))
        for i in 1..<stops.count where u <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let t = (u - a) / max(1e-9, b - a)
            return (
                UInt8(ca.0 + (cb.0 - ca.0) * t),
                UInt8(ca.1 + (cb.1 - ca.1) * t),
                UInt8(ca.2 + (cb.2 - ca.2) * t)
            )
        }
        return (255, 255, 255)
    }

    /// Draws the view at `width` × `height`, rows shared out over the
    /// cores, a band at a time; nil if cancelled between bands.
    static func render(_ v: MandelbrotParams, width: Int, height: Int) -> CGImage? {
        let w = max(1, width), h = max(1, height)
        let count = w * h * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 255, count: count)
        nonisolated(unsafe) let out = buffer
        var finished = true

        let band = 48
        var top = 0
        while top < h {
            if Task.isCancelled { finished = false; break }
            let rows = min(band, h - top)
            let first = top
            DispatchQueue.concurrentPerform(iterations: rows) { i in
                drawRow(first + i, v, w: w, h: h, into: out)
            }
            top += rows
        }

        defer { buffer.deallocate() }
        guard finished else { return nil }
        let data = Data(bytes: buffer, count: count)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func drawRow(_ row: Int, _ v: MandelbrotParams, w: Int, h: Int, into out: UnsafeMutablePointer<UInt8>) {
        let depth = max(1, v.depth)
        let scaleY = v.scaleX * Double(h) / Double(w)
        let y = v.centerY + (0.5 - (Double(row) + 0.5) / Double(h)) * scaleY
        for col in 0..<w {
            let x = v.centerX + ((Double(col) + 0.5) / Double(w) - 0.5) * v.scaleX
            var rgb = inside
            // The main cardioid and the period-2 bulb are inside: no need
            // to iterate.
            let q = (x - 0.25) * (x - 0.25) + y * y
            let inCardioid = q * (q + (x - 0.25)) <= 0.25 * y * y
            let inBulb = (x + 1) * (x + 1) + y * y <= 1.0 / 16
            if !inCardioid && !inBulb {
                var zx = 0.0, zy = 0.0, n = 0
                while n < depth {
                    let t = zx * zx - zy * zy + x
                    zy = 2 * zx * zy + y
                    zx = t
                    n += 1
                    if zx * zx + zy * zy > 65536 { break }
                }
                if n < depth {
                    let mu = Double(n) + 1 - log(log(sqrt(zx * zx + zy * zy))) / log(2)
                    rgb = color(max(0, mu), depth: depth)
                }
            }
            let i = (row * w + col) * 4
            out[i] = rgb.0
            out[i + 1] = rgb.1
            out[i + 2] = rgb.2
        }
    }
}

// MARK: - Stripes

/// Two 320 × 256 pictures of grey stripes, a level per row.
nonisolated enum StripePicture: Int, CaseIterable, Identifiable {
    case one, two
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one: "Ⅰ"
        case .two: "Ⅱ"
        }
    }

    private static let levels: [Character: UInt8] = ["0": 0, "1": 59, "2": 124, "3": 160, "4": 238]

    private var rows: String {
        switch self {
        case .one:
            "2211001122222222111111112244444422110011222222221111221100000000221100112222222211111111224444442211001122222222111122110000000022110011222222221111111122444444221100112222222211112211000000002211001122222222111111112244444422110011222222221111221100000000"
        case .two:
            "2222334444332211000011222221111122223344443322110000112211100000111122001123220011232211001144442222334444332211000011221110000022223344443322110000112222211111222233444433221100001122111000001111220011232200112322110011444422223344443322110000112211100000"
        }
    }

    /// Exactly these levels, in sRGB (nothing scaled or converted).
    var image: UIImage {
        let w = 320, rowLevels = rows.map { Self.levels[$0] ?? 0 }
        let h = rowLevels.count
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for (y, v) in rowLevels.enumerated() {
            for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i] = v
                bytes[i + 1] = v
                bytes[i + 2] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Built In

/// The built-in pictures: a tap on the test card or the bars picks it;
/// the Mandelbrot set opens its own screen first.
struct BuiltInView: View {
    let onPick: (FavoritePick) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(TestCard.allCases) { card in
                        Button {
                            pick(card.image)
                        } label: {
                            tile(Self.thumbnail(card), title: card.title)
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink {
                        MandelbrotScreen { image in pick(image) }
                    } label: {
                        tile(Self.mandelbrotThumbnail(), title: String(localized: "Mandelbrot"))
                    }
                    .buttonStyle(.plain)
                    ForEach(StripePicture.allCases) { stripes in
                        Button {
                            pick(stripes.image)
                        } label: {
                            tile(Self.thumbnail(stripes), title: stripes.title)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Built In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func pick(_ image: UIImage) {
        onPick(FavoritePick(photo: image, placement: PhotoPlacement(), favoriteID: nil))
        dismiss()
    }

    private func tile(_ image: UIImage?, title: String) -> some View {
        VStack(spacing: 4) {
            Color(.secondarySystemFill)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // Drawn in the first pass and kept: a thumbnail set later, from a task,
    // didn't show until the screen was redrawn for another reason.
    private static var cardThumbnails: [TestCard: UIImage] = [:]
    private static var mandelbrotTile: UIImage?

    private static func thumbnail(_ card: TestCard) -> UIImage {
        if let done = cardThumbnails[card] { return done }
        let thumb = FavoritesView.thumbnail(of: card.image)
        cardThumbnails[card] = thumb
        return thumb
    }

    private static var stripeThumbnails: [StripePicture: UIImage] = [:]

    private static func thumbnail(_ stripes: StripePicture) -> UIImage {
        if let done = stripeThumbnails[stripes] { return done }
        let thumb = FavoritesView.thumbnail(of: stripes.image)
        stripeThumbnails[stripes] = thumb
        return thumb
    }

    private static func mandelbrotThumbnail() -> UIImage? {
        if let mandelbrotTile { return mandelbrotTile }
        guard let image = Mandelbrot.render(.home, width: 320, height: 240) else { return nil }
        let tile = UIImage(cgImage: image)
        mandelbrotTile = tile
        return tile
    }
}

// MARK: - The Mandelbrot screen

/// A view of the set: a preset, or a centre, width and depth typed in, as
/// in the NeXT demo; tap the picture to centre it there, or zoom by two.
struct MandelbrotScreen: View {
    let onUse: (UIImage) -> Void

    @State private var params = MandelbrotParams.home
    @State private var preview: CGImage?
    @State private var rendering = false
    @State private var using = false

    @State private var centerXText = ""
    @State private var centerYText = ""
    @State private var scaleXText = ""
    @State private var depthText = ""
    @FocusState private var typing: Bool

    /// Drawn first, at once; then the sharp one (about the screen's pixels).
    private static let roughSize = (width: 320, height: 240)
    private static let previewSize = (width: 1200, height: 900)

    var body: some View {
        Form {
            Section {
                ZStack {
                    Color(red: 8 / 255, green: 10 / 255, blue: 32 / 255)
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    }
                }
                // Small and in a corner: the picture stays in view while
                // it's drawn again.
                .overlay(alignment: .topTrailing) {
                    if rendering {
                        ProgressView()
                            .tint(.white)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { point in recenter(at: point, in: geo.size) }
                    }
                }
            } footer: {
                Text("Tap the picture to centre it there.")
            }

            Section {
                HStack {
                    Button {
                        zoom(by: 0.8)
                    } label: {
                        Label("Zoom In", systemImage: "plus.magnifyingglass")
                    }
                    Spacer()
                    Button {
                        zoom(by: 1.25)
                    } label: {
                        Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    }
                }
                .buttonStyle(.borderless)
                // As in the darkroom: held to the right it keeps zooming in,
                // to the left out, faster the further it's pulled.
                FineRow(maxRate: 2, step: 0.1) { d in
                    zoom(by: exp(-d))
                }

                // The same kind of menu as Sample Rate in Settings.
                Picker("Presets", selection: Binding(
                    get: { currentPresetID ?? "custom" },
                    set: { id in
                        if let preset = MandelbrotPreset.all.first(where: { $0.id == id }) { apply(preset.view) }
                    }
                )) {
                    ForEach(MandelbrotPreset.all) { preset in
                        Text(verbatim: preset.name).tag(preset.id)
                    }
                    if currentPresetID == nil {
                        Text("Custom").tag("custom")
                    }
                }
            }

            Section {
                field("X Center", text: $centerXText)
                field("Y Center", text: $centerYText)
                field("X Scale", text: $scaleXText)
                LabeledContent("Y Scale") {
                    Text(String(format: "%.6g", params.scaleX * 0.75)).monospacedDigit()
                }
                field("Depth", text: $depthText, integer: true)
                Button("Run") { run() }
                    .fontWeight(.semibold)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Mandelbrot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if using {
                    ProgressView()
                } else {
                    Button("Use") { use() }
                        .fontWeight(.semibold)
                }
            }
            ToolbarSpacer(.flexible, placement: .keyboard)
            ToolbarItem(placement: .keyboard) {
                Button("Done") { typing = false }
                    .fontWeight(.semibold)
            }
        }
        .onAppear { if centerXText.isEmpty { showFields() } }
        .task(id: params) { await renderPreview() }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, integer: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .keyboardType(integer ? .numberPad : .numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($typing)
                .onSubmit { run() }
        }
    }

    private var currentPresetID: String? {
        MandelbrotPreset.all.first { $0.view == params }?.id
    }

    // MARK: Changes

    private func apply(_ v: MandelbrotParams) {
        params = v
        showFields()
    }

    private func showFields() {
        centerXText = Self.format(params.centerX)
        centerYText = Self.format(params.centerY)
        scaleXText = Self.format(params.scaleX)
        depthText = "\(params.depth)"
    }

    private static func format(_ v: Double) -> String {
        String(format: "%.10g", v)
    }

    /// The fields as typed (anything that doesn't read as a number is left
    /// as it was).
    private func run() {
        typing = false
        var v = params
        if let x = Double(centerXText) { v.centerX = x }
        if let y = Double(centerYText) { v.centerY = y }
        if let s = Double(scaleXText), s > 0 { v.scaleX = s }
        if let d = Int(depthText), d > 0 { v.depth = min(d, 5000) }
        apply(v)
    }

    private func recenter(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var v = params
        v.centerX += (point.x / size.width - 0.5) * params.scaleX
        v.centerY -= (point.y / size.height - 0.5) * params.scaleX * 0.75
        apply(v)
    }

    private func zoom(by factor: Double) {
        var v = params
        v.scaleX = min(8, max(1e-13, v.scaleX * factor))   // past 1e-13 doubles run out
        apply(v)
    }

    // MARK: Drawing

    /// A quick rough picture first, then one as sharp as the screen.
    private func renderPreview() async {
        rendering = true
        for size in [Self.roughSize, Self.previewSize] {
            let v = params
            let work = Task.detached(priority: .userInitiated) {
                Mandelbrot.render(v, width: size.width, height: size.height)
            }
            // A newer view cancels this one, and the drawing with it.
            let image = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            if let image { preview = image }
        }
        rendering = false
    }

    /// Draws it at full size and hands it over.
    private func use() {
        using = true
        let v = params, size = Mandelbrot.size
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                Mandelbrot.render(v, width: size.width, height: size.height)
            }.value
            using = false
            if let image { onUse(UIImage(cgImage: image)) }
        }
    }
}
