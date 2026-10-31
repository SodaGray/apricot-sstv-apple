// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionStore.swift
//  One received picture = one folder:
//
//    Documents/Receptions/<id>/image.png     the picture as received (never edited)
//    Documents/Receptions/<id>/meta.json     how it was received
//    Documents/Receptions/<id>/audio.wav     its audio (when Save Raw Audio is on)
//    Documents/Receptions/<id>/audio.json    the audio's rate and gaps
//    Documents/Receptions/<id>/edited.png    (iPhone) the picture developed again in the darkroom
//    Documents/Receptions/<id>/edit.json     (iPhone) the settings it was developed with
//    Documents/Receptions/<id>/notes.json    (iPhone) notes written about it, its event (Events.swift)
//    Documents/Receptions/<id>/synced        (watch only) the iPhone has the picture
//    Documents/Receptions/<id>/audio-synced  (watch only) the iPhone has the audio
//
//    Documents/Receptions/.recording/        audio being recorded right now
//
//  The same layout on the watch and the phone, so a picture can be
//  copied from one to the other as it is. meta.json is written last:
//  a folder without it is incomplete. Edits are files beside these, as in
//  Photos: image.png and audio.wav stay the originals, and reverting just
//  removes edited.png and edit.json.
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
    /// "watch" or "phone": where it was received; "file": decoded from an
    /// audio file on the iPhone.
    var device: String

    var isComplete: Bool { end == "complete" }

    /// Too few rows to count as a picture (the receiver's threshold): a
    /// false start, or a picture caught at its very end. Kept anyway, for
    /// its raw audio; the gallery shows fragments apart.
    var isFragment: Bool { rows < max(16, height / 8) }

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

    /// Where it was received, for showing ("file": decoded from an audio
    /// file, AudioFileImport.swift).
    var deviceDescription: String {
        switch device {
        case "watch": String(localized: "Apple Watch")
        case "file": String(localized: "Audio File")
        default: String(localized: "iPhone")
        }
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

    static func audioURL(for id: String) -> URL {
        folder(for: id).appending(path: "audio.wav")
    }

    private static func audioInfoURL(for id: String) -> URL {
        folder(for: id).appending(path: "audio.json")
    }

    private static func audioSyncedURL(for id: String) -> URL {
        folder(for: id).appending(path: "audio-synced")
    }

    /// Where recordings in progress are written (hidden: list() skips it).
    static var recordingDirectory: URL {
        root.appending(path: ".recording", directoryHint: .isDirectory)
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
        #if os(iOS)
        EventStore.assignOnArrival(meta)
        #endif
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
        #if os(iOS)
        EventStore.assignOnArrival(meta)
        #endif
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

    // MARK: Audio

    static func hasAudio(id: String) -> Bool {
        isValidID(id) && FileManager.default.fileExists(atPath: audioURL(for: id).path)
    }

    static func audioInfo(id: String) -> AudioInfo? {
        guard isValidID(id),
              let data = try? Data(contentsOf: audioInfoURL(for: id))
        else { return nil }
        return try? JSONDecoder().decode(AudioInfo.self, from: data)
    }

    /// Size of audio.wav in bytes (0 if none).
    static func audioByteCount(id: String) -> Int64 {
        guard hasAudio(id: id),
              let size = try? audioURL(for: id).resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return 0 }
        return Int64(size)
    }

    /// Files a finished recording with its picture. Returns false, and
    /// deletes the recording, if the picture wasn't kept.
    @discardableResult
    static func attachAudio(id: String, from recording: URL, info: AudioInfo) throws -> Bool {
        let fm = FileManager.default
        guard isValidID(id), fm.fileExists(atPath: metaURL(for: id).path) else {
            try? fm.removeItem(at: recording)
            return false
        }
        try installAudio(id: id, moving: recording, info: info)
        return true
    }

    /// Takes audio that arrived from the watch. It may come before or
    /// after its picture; the folder is made if it isn't there yet.
    static func importAudio(id: String, from source: URL, info: AudioInfo) throws {
        guard isValidID(id) else { throw StoreError.badID }
        let fm = FileManager.default
        try fm.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        // Staged beside the folder (not in .recording, which is cleared at
        // launch), then moved in.
        let staging = root.appending(path: ".incoming", directoryHint: .isDirectory)
        let copy = staging.appending(path: "\(id).wav")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: source, to: copy)
        try installAudio(id: id, moving: copy, info: info)
    }

    private static func installAudio(id: String, moving file: URL, info: AudioInfo) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: audioSyncedURL(for: id))
        let dest = audioURL(for: id)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: file, to: dest)
        try JSONEncoder().encode(info).write(to: audioInfoURL(for: id), options: .atomic)
        postChanged()
    }

    /// Removes a picture's audio and keeps the picture.
    static func deleteAudio(id: String) throws {
        guard isValidID(id) else { throw StoreError.badID }
        let fm = FileManager.default
        try? fm.removeItem(at: audioInfoURL(for: id))
        try? fm.removeItem(at: audioSyncedURL(for: id))
        try fm.removeItem(at: audioURL(for: id))
        postChanged()
    }

    /// Recordings left half-written by a previous run (the app was
    /// stopped mid-picture). Call once at launch, before receiving.
    static func removeLeftoverRecordings() {
        try? FileManager.default.removeItem(at: recordingDirectory)
    }

    // MARK: Synced marks (watch)

    /// The iPhone has everything there is: the picture, and its audio if
    /// there is any.
    static func isSynced(id: String) -> Bool {
        isImageSynced(id: id) && (!hasAudio(id: id) || isAudioSynced(id: id))
    }

    static func isImageSynced(id: String) -> Bool {
        FileManager.default.fileExists(atPath: syncedURL(for: id).path)
    }

    static func isAudioSynced(id: String) -> Bool {
        FileManager.default.fileExists(atPath: audioSyncedURL(for: id).path)
    }

    static func markSynced(id: String) {
        guard isValidID(id),
              FileManager.default.fileExists(atPath: metaURL(for: id).path)
        else { return }
        FileManager.default.createFile(atPath: syncedURL(for: id).path, contents: Data())
        postChanged()
    }

    static func markAudioSynced(id: String) {
        guard hasAudio(id: id) else { return }
        FileManager.default.createFile(atPath: audioSyncedURL(for: id).path, contents: Data())
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

    /// The picture as shown: the darkroom's version if there is one.
    static func loadImage(id: String) -> CGImage? {
        guard isValidID(id) else { return nil }
        return load(displayImageURL(for: id))
    }

    /// The picture as it was received, whatever was done to it since.
    static func loadOriginalImage(id: String) -> CGImage? {
        guard isValidID(id) else { return nil }
        return load(imageURL(for: id))
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Edits (darkroom)

    static func editedImageURL(for id: String) -> URL {
        folder(for: id).appending(path: "edited.png")
    }

    private static func editURL(for id: String) -> URL {
        folder(for: id).appending(path: "edit.json")
    }

    /// edited.png if there is one, else image.png: what to show and share.
    static func displayImageURL(for id: String) -> URL {
        hasEdit(id: id) ? editedImageURL(for: id) : imageURL(for: id)
    }

    static func hasEdit(id: String) -> Bool {
        isValidID(id) && FileManager.default.fileExists(atPath: editedImageURL(for: id).path)
    }

    /// Changes whenever an edit is saved or reverted (for reloading thumbnails).
    static func editStamp(id: String) -> Double {
        guard hasEdit(id: id),
              let date = try? editedImageURL(for: id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return 0 }
        return date.timeIntervalSince1970
    }

    static func editSettings(id: String) -> Data? {
        guard hasEdit(id: id) else { return nil }
        return try? Data(contentsOf: editURL(for: id))
    }

    /// Saves a developed picture beside the original.
    static func saveEdit(id: String, image: CGImage, settings: Data) throws {
        guard isValidID(id) else { throw StoreError.badID }
        guard let dest = CGImageDestinationCreateWithURL(
            editedImageURL(for: id) as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw StoreError.cannotWriteImage }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw StoreError.cannotWriteImage }
        try settings.write(to: editURL(for: id), options: .atomic)
        postChanged()
    }

    /// Back to the picture as received.
    static func revertEdit(id: String) {
        guard isValidID(id) else { return }
        try? FileManager.default.removeItem(at: editedImageURL(for: id))
        try? FileManager.default.removeItem(at: editURL(for: id))
        postChanged()
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
