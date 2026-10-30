// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionStore.swift
//  One received picture = one folder:
//
//    Documents/Receptions/<id>/image.png
//    Documents/Receptions/<id>/meta.json
//    Documents/Receptions/<id>/synced      (watch only: the iPhone has it)
//
//  The same layout on the watch and the phone, so a picture can be
//  copied from one to the other as it is. meta.json is written last:
//  a folder without it is incomplete.
//
//  Every change posts .receptionsChanged on the main queue.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ReceptionMeta: Codable, Sendable, Identifiable, Equatable {
    var format = 1
    var id: String
    var mode: String
    var visCode: Int?
    /// "vis" or "sync"
    var start: String
    /// "complete", "lost", "aborted", "new VIS", "no memory"
    var end: String
    var startedAt: Date
    var endedAt: Date
    /// Rows decoded, out of `height` (both as sent).
    var rows: Int
    var height: Int
    /// Size of image.png (the size sent; the iPod stores PD120 and up at half).
    var imageWidth: Int
    var imageHeight: Int
    var ppm: Int
    var ppmValid: Bool
    var offsetHz: Int
    var syncGood: Int
    var syncSeen: Int
    var relocks: Int
    var sampleRate: Int
    /// "watch" or "phone": where it was received.
    var device: String

    var isComplete: Bool { end == "complete" }

    /// How it ended, for showing (end itself stays English in meta.json).
    var endDescription: String {
        switch end {
        case "complete": String(localized: "Complete")
        case "lost": String(localized: "Signal lost")
        case "aborted": String(localized: "Stopped")
        case "new VIS": String(localized: "Interrupted by a new picture")
        case "no memory": String(localized: "Out of memory")
        default: end
        }
    }

    /// How it started, for showing.
    var startDescription: String {
        start == "vis"
            ? String(localized: "VIS header")
            : String(localized: "Line syncs (no VIS)")
    }

    /// Where it was received, for showing.
    var deviceDescription: String {
        device == "watch" ? String(localized: "Apple Watch") : String(localized: "iPhone")
    }
}

extension Notification.Name {
    nonisolated static let receptionsChanged = Notification.Name("ApricotReceptionsChanged")
}

nonisolated enum ReceptionStore {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Receptions", directoryHint: .isDirectory)
    }

    static func folder(for id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    static func imageURL(for id: String) -> URL {
        folder(for: id).appending(path: "image.png")
    }

    private static func metaURL(for id: String) -> URL {
        folder(for: id).appending(path: "meta.json")
    }

    private static func syncedURL(for id: String) -> URL {
        folder(for: id).appending(path: "synced")
    }

    /// "20261029-212300-MartinM1"
    static func makeID(startedAt: Date, mode: String) -> String {
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: startedAt
        )
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
        let name = mode.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return name.isEmpty ? stamp : "\(stamp)-\(name)"
    }

    /// IDs become folder names, and the phone takes them from the watch:
    /// only plain ASCII letters, digits, "-" and "_".
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    // MARK: Write

    /// Writes (or overwrites) a reception's picture and metadata.
    /// Overwriting clears the synced mark, so the new version is sent again.
    static func save(_ image: CGImage, meta: ReceptionMeta) throws {
        guard isValidID(meta.id) else { throw StoreError.badID }
        let dir = folder(for: meta.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: syncedURL(for: meta.id))

        guard let dest = CGImageDestinationCreateWithURL(
            imageURL(for: meta.id) as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StoreError.cannotWriteImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw StoreError.cannotWriteImage
        }

        try writeMeta(meta)
        postChanged()
    }

    /// Takes a reception that arrived from the other device: copies its
    /// picture in (replacing an older version), then writes its metadata.
    static func importReception(imageAt source: URL, meta: ReceptionMeta) throws {
        guard isValidID(meta.id) else { throw StoreError.badID }
        let fm = FileManager.default
        let dir = folder(for: meta.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try? fm.removeItem(at: metaURL(for: meta.id))
        let dest = imageURL(for: meta.id)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: source, to: dest)

        try writeMeta(meta)
        postChanged()
    }

    static func delete(id: String) throws {
        guard isValidID(id) else { throw StoreError.badID }
        try FileManager.default.removeItem(at: folder(for: id))
        postChanged()
    }

    private static func writeMeta(_ meta: ReceptionMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL(for: meta.id), options: .atomic)
    }

    // MARK: Synced mark (watch)

    static func isSynced(id: String) -> Bool {
        FileManager.default.fileExists(atPath: syncedURL(for: id).path)
    }

    static func markSynced(id: String) {
        guard isValidID(id),
              FileManager.default.fileExists(atPath: metaURL(for: id).path)
        else { return }
        FileManager.default.createFile(atPath: syncedURL(for: id).path, contents: Data())
        postChanged()
    }

    // MARK: Read

    /// All complete receptions, newest first.
    static func list() -> [ReceptionMeta] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dirs
            .compactMap { meta(id: $0.lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func meta(id: String) -> ReceptionMeta? {
        guard isValidID(id),
              let data = try? Data(contentsOf: metaURL(for: id))
        else { return nil }
        return decodeMeta(data)
    }

    static func loadImage(id: String) -> CGImage? {
        guard
            isValidID(id),
            let source = CGImageSourceCreateWithURL(imageURL(for: id) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Coding

    static func encodeMeta(_ meta: ReceptionMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(meta)
    }

    static func decodeMeta(_ data: Data) -> ReceptionMeta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReceptionMeta.self, from: data)
    }

    static func postChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .receptionsChanged, object: nil)
        }
    }

    nonisolated enum StoreError: LocalizedError {
        case cannotWriteImage, badID

        var errorDescription: String? {
            switch self {
            case .cannotWriteImage: String(localized: "Could not write image.png")
            case .badID: String(localized: "Invalid picture ID")
            }
        }
    }
}
