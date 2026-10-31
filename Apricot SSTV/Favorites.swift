// SPDX-License-Identifier: GPL-3.0-only
//
//  Favorites.swift
//  Apricot SSTV
//
//  Pictures kept in the app for sending again (a QSL card, the station),
//  each with the place it last had in the frame, plus two built-in test
//  cards drawn here (no image files): a test card with color bars, grey
//  steps, fine lines, a circle and a border, and full-frame color bars.
//
//    Documents/Favorites/<uuid>/photo.jpg   the prepared photo
//    Documents/Favorites/<uuid>/info.json   placement and when it was added
//
//  Kept out of the system photo library; Settings → Export All takes them
//  along.
//

import SwiftUI
import Combine
import UIKit

// MARK: - Store

nonisolated struct FavoriteInfo: Codable, Sendable {
    var format = 1
    var added: Date
    var zoom: Double
    var offsetX: Double
    var offsetY: Double

    var placement: PhotoPlacement {
        PhotoPlacement(zoom: CGFloat(zoom), offset: CGSize(width: offsetX, height: offsetY))
    }
}

nonisolated struct Favorite: Identifiable, Sendable {
    let id: String
    let info: FavoriteInfo
    var photoURL: URL { FavoritesStore.folder(for: id).appending(path: "photo.jpg") }
}

nonisolated enum FavoritesStore {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Favorites", directoryHint: .isDirectory)
    }

    static func folder(for id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    static func list() -> [Favorite] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return dirs.compactMap { dir -> Favorite? in
            let id = dir.lastPathComponent
            guard let data = try? Data(contentsOf: dir.appending(path: "info.json")),
                  let info = try? decoder.decode(FavoriteInfo.self, from: data),
                  FileManager.default.fileExists(atPath: dir.appending(path: "photo.jpg").path)
            else { return nil }
            return Favorite(id: id, info: info)
        }
        .sorted { $0.info.added > $1.info.added }
    }

    static func add(photo: UIImage, placement: PhotoPlacement) throws {
        guard let jpeg = photo.jpegData(compressionQuality: 0.92) else { throw CocoaError(.fileWriteUnknown) }
        let id = UUID().uuidString
        let dir = folder(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpeg.write(to: dir.appending(path: "photo.jpg"), options: .atomic)
        let info = FavoriteInfo(
            added: Date(),
            zoom: Double(placement.zoom),
            offsetX: Double(placement.offset.width),
            offsetY: Double(placement.offset.height)
        )
        try encoder.encode(info).write(to: dir.appending(path: "info.json"), options: .atomic)
    }

    /// Remembers where the picture was last placed.
    static func update(id: String, placement: PhotoPlacement) {
        let url = folder(for: id).appending(path: "info.json")
        guard let data = try? Data(contentsOf: url),
              var info = try? decoder.decode(FavoriteInfo.self, from: data)
        else { return }
        info.zoom = Double(placement.zoom)
        info.offsetX = Double(placement.offset.width)
        info.offsetY = Double(placement.offset.height)
        try? encoder.encode(info).write(to: url, options: .atomic)
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Built-in test cards

enum TestCard: String, CaseIterable, Identifiable {
    case card, bars
    var id: Self { self }

    var title: String {
        switch self {
        case .card: String(localized: "Test Card")
        case .bars: String(localized: "Color Bars")
        }
    }

    /// 1600 × 1200 (4:3); fills every mode's frame with little cropped.
    @MainActor
    var image: UIImage {
        switch self {
        case .card: Self.drawCard()
        case .bars: Self.drawBars()
        }
    }

    private static let size = CGSize(width: 1600, height: 1200)

    /// White, yellow, cyan, green, magenta, red, blue (100 %).
    private static let barColors: [UIColor] = [
        .white,
        UIColor(red: 1, green: 1, blue: 0, alpha: 1),
        UIColor(red: 0, green: 1, blue: 1, alpha: 1),
        UIColor(red: 0, green: 1, blue: 0, alpha: 1),
        UIColor(red: 1, green: 0, blue: 1, alpha: 1),
        UIColor(red: 1, green: 0, blue: 0, alpha: 1),
        UIColor(red: 0, green: 0, blue: 1, alpha: 1),
    ]

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    private static func drawCard() -> UIImage {
        renderer().image { r in
            let c = r.cgContext
            let W = size.width, H = size.height

            // Grey ground and a white grid, 16 × 12.
            UIColor(white: 0.45, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            for i in 0...16 { c.fill(CGRect(x: CGFloat(i) * W / 16 - 2, y: 0, width: 4, height: H)) }
            for j in 0...12 { c.fill(CGRect(x: 0, y: CGFloat(j) * H / 12 - 2, width: W, height: 4)) }

            // A border: alternating black and white blocks round the edge.
            for i in 0..<32 {
                (i % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                c.fill(CGRect(x: CGFloat(i) * W / 32, y: 0, width: W / 32, height: 24))
                c.fill(CGRect(x: CGFloat(i) * W / 32, y: H - 24, width: W / 32, height: 24))
            }
            for j in 0..<24 {
                (j % 2 == 0 ? UIColor.white : UIColor.black).setFill()
                c.fill(CGRect(x: 0, y: CGFloat(j) * H / 24, width: 24, height: H / 24))
                c.fill(CGRect(x: W - 24, y: CGFloat(j) * H / 24, width: 24, height: H / 24))
            }

            // The circle, and inside it, top to bottom: bars, fine lines,
            // grey steps.
            let r0 = H * 0.42
            let circle = CGRect(x: W / 2 - r0, y: H / 2 - r0, width: 2 * r0, height: 2 * r0)
            c.saveGState()
            c.addEllipse(in: circle)
            c.clip()
            UIColor.black.setFill()
            c.fill(circle)

            let bandH = 2 * r0 / 6
            let top = circle.minY + bandH
            for (i, color) in barColors.enumerated() {
                color.setFill()
                c.fill(CGRect(x: circle.minX + CGFloat(i) * circle.width / 7, y: top, width: circle.width / 7 + 1, height: bandH * 1.4))
            }

            // Fine vertical lines, in four groups, each twice as fine as
            // the one before.
            let linesY = top + bandH * 1.6
            UIColor.white.setFill()
            for (i, w) in [CGFloat(16), 8, 4, 2].enumerated() {
                let x0 = circle.minX + CGFloat(i) * circle.width / 4
                var x = x0
                while x < x0 + circle.width / 4 {
                    c.fill(CGRect(x: x, y: linesY, width: w, height: bandH * 0.9))
                    x += 2 * w
                }
            }

            // Six grey steps, black to white.
            let stepsY = linesY + bandH * 1.1
            for i in 0..<6 {
                UIColor(white: CGFloat(i) / 5, alpha: 1).setFill()
                c.fill(CGRect(x: circle.minX + CGFloat(i) * circle.width / 6, y: stepsY, width: circle.width / 6 + 1, height: bandH))
            }
            c.restoreGState()

            UIColor.white.setStroke()
            c.setLineWidth(6)
            c.strokeEllipse(in: circle)

            // Centre cross.
            UIColor.white.setFill()
            c.fill(CGRect(x: W / 2 - 2, y: H / 2 - 60, width: 4, height: 120))
            c.fill(CGRect(x: W / 2 - 60, y: H / 2 - 2, width: 120, height: 4))
        }
    }

    private static func drawBars() -> UIImage {
        renderer().image { r in
            let c = r.cgContext
            let W = size.width, H = size.height
            for (i, color) in (barColors + [.black]).enumerated() {
                color.setFill()
                c.fill(CGRect(x: CGFloat(i) * W / 8, y: 0, width: W / 8 + 1, height: H * 0.66))
            }
            // A smooth black-to-white ramp, then black and white blocks.
            let ramp = CGRect(x: 0, y: H * 0.66, width: W, height: H * 0.17)
            let colors = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
                c.saveGState()
                c.clip(to: ramp)
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: ramp.midY), end: CGPoint(x: W, y: ramp.midY), options: [])
                c.restoreGState()
            }
            for i in 0..<8 {
                (i % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                c.fill(CGRect(x: CGFloat(i) * W / 8, y: H * 0.83, width: W / 8 + 1, height: H * 0.17 + 1))
            }
        }
    }
}

// MARK: - Picker

/// What a choice from the favorites sheet hands back.
struct FavoritePick {
    let photo: UIImage
    let placement: PhotoPlacement
    /// nil for a built-in card.
    let favoriteID: String?
}

struct FavoritesView: View {
    let onPick: (FavoritePick) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var favorites: [Favorite] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var cards: [TestCard: UIImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Built In") {
                        ForEach(TestCard.allCases) { card in
                            tile(cards[card], title: card.title) {
                                if let image = cards[card] {
                                    onPick(FavoritePick(photo: image, placement: PhotoPlacement(), favoriteID: nil))
                                    dismiss()
                                }
                            }
                        }
                    }

                    section("Your Pictures") {
                        ForEach(favorites) { fav in
                            tile(thumbnails[fav.id], title: nil) {
                                pick(fav)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    FavoritesStore.delete(id: fav.id)
                                    reload()
                                } label: {
                                    Label("Remove from Favorites", systemImage: "trash")
                                }
                            }
                        }
                    }

                    if favorites.isEmpty {
                        Text("To keep a picture here, choose Add to Favorites in the photo menu after placing it in the frame.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            for card in TestCard.allCases { cards[card] = card.image }
            reload()
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LazyVGrid(columns: columns, spacing: 12) { content() }
        }
    }

    private func tile(_ image: UIImage?, title: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Color(.secondarySystemFill)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let title {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        favorites = FavoritesStore.list()
        for fav in favorites where thumbnails[fav.id] == nil {
            if let image = UIImage(contentsOfFile: fav.photoURL.path) {
                thumbnails[fav.id] = image.preparingThumbnail(of: CGSize(width: 320, height: 240)) ?? image
            }
        }
    }

    private func pick(_ fav: Favorite) {
        guard let image = UIImage(contentsOfFile: fav.photoURL.path) else { return }
        onPick(FavoritePick(photo: image, placement: fav.info.placement, favoriteID: fav.id))
        dismiss()
    }
}
