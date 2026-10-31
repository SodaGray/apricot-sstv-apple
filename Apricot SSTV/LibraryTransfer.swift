// SPDX-License-Identifier: GPL-3.0-only
//
//  LibraryTransfer.swift
//  Apricot SSTV
//
//  Everything the app keeps, as a plain folder anyone can open, and back:
//
//    Apricot SSTV <date>/
//      Pictures/<id>/image.png, meta.json, audio.wav, audio.json, notes.json, ...
//      Events/<uuid>.json
//      Favorites/<uuid>/photo.jpg, info.json
//      Read Me.txt
//
//  Export Library writes that folder wherever the person picks in Files (the
//  files are read as they're written, not loaded first). Import takes such
//  a folder back, or a folder of picture folders: pictures already here
//  are skipped, nothing is overwritten. And how much space each kind uses,
//  for Settings.
//

import SwiftUI
import UniformTypeIdentifiers

nonisolated enum LibraryTransfer {
    // MARK: Space used

    nonisolated struct Usage: Sendable, Equatable {
        var pictures: Int64 = 0
        var audio: Int64 = 0
        var favorites: Int64 = 0
    }

    /// Walks the folders; call off the main thread.
    static func usage() -> Usage {
        var u = Usage()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let fm = FileManager.default
        if let files = fm.enumerator(at: ReceptionStore.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let file as URL in files {
                let v = try? file.resourceValues(forKeys: keys)
                guard v?.isRegularFile == true else { continue }
                let size = Int64(v?.fileSize ?? 0)
                if file.lastPathComponent == "audio.wav" { u.audio += size } else { u.pictures += size }
            }
        }
        if let files = fm.enumerator(at: FavoritesStore.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let file as URL in files {
                let v = try? file.resourceValues(forKeys: keys)
                if v?.isRegularFile == true { u.favorites += Int64(v?.fileSize ?? 0) }
            }
        }
        return u
    }

    /// Removes every picture's raw audio; the pictures stay.
    static func deleteAllAudio() {
        for meta in ReceptionStore.list() where ReceptionStore.hasAudio(id: meta.id) {
            try? ReceptionStore.deleteAudio(id: meta.id)
        }
    }

    // MARK: Import

    nonisolated struct ImportResult: Sendable {
        var pictures = 0
        var skipped = 0
        var favorites = 0
        var events = 0
    }

    /// Files that only mean something on the device that wrote them.
    private static let localOnly: Set<String> = ["synced", "audio-synced"]

    /// Copies pictures (and favorites) from a folder picked in Files.
    static func importFolder(_ url: URL) throws -> ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var result = ImportResult()

        // An export (Pictures/ inside), or a folder of picture folders.
        let pictures = url.appending(path: "Pictures", directoryHint: .isDirectory)
        let source = fm.fileExists(atPath: pictures.path) ? pictures : url
        try fm.createDirectory(at: ReceptionStore.root, withIntermediateDirectories: true)

        for dir in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let id = dir.lastPathComponent
            guard ReceptionStore.isValidID(id),
                  let data = try? Data(contentsOf: dir.appending(path: "meta.json")),
                  let meta = ReceptionStore.decodeMeta(data), meta.id == id,
                  fm.fileExists(atPath: dir.appending(path: "image.png").path)
            else { continue }
            if fm.fileExists(atPath: ReceptionStore.folder(for: id).path) {
                result.skipped += 1
                continue
            }
            // Into a hidden folder first, then moved in whole: a half-copied
            // picture never shows in the list.
            let staging = ReceptionStore.root.appending(path: ".incoming", directoryHint: .isDirectory)
                .appending(path: "import-\(id)", directoryHint: .isDirectory)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: dir, to: staging)
            for name in localOnly { try? fm.removeItem(at: staging.appending(path: name)) }
            try fm.moveItem(at: staging, to: ReceptionStore.folder(for: id))
            result.pictures += 1
        }

        // Events: kept as they are, except none comes in current (that's
        // this iPhone's choice to make).
        let events = url.appending(path: "Events", directoryHint: .isDirectory)
        if fm.fileExists(atPath: events.path) {
            try fm.createDirectory(at: EventStore.root, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: events, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                guard file.pathExtension == "json",
                      let data = try? Data(contentsOf: file),
                      var event = EventStore.decodeEvent(data),
                      !fm.fileExists(atPath: EventStore.url(for: event.id).path)
                else { continue }
                if let last = event.currentSpans.last, last.end > .now {
                    event.currentSpans[event.currentSpans.count - 1] = DateInterval(start: last.start, end: max(last.start, .now))
                }
                try EventStore.save(event)
                result.events += 1
            }
        }

        let favorites = url.appending(path: "Favorites", directoryHint: .isDirectory)
        if fm.fileExists(atPath: favorites.path) {
            try fm.createDirectory(at: FavoritesStore.root, withIntermediateDirectories: true)
            for dir in (try? fm.contentsOfDirectory(at: favorites, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let dest = FavoritesStore.folder(for: dir.lastPathComponent)
                guard fm.fileExists(atPath: dir.appending(path: "photo.jpg").path),
                      fm.fileExists(atPath: dir.appending(path: "info.json").path),
                      !fm.fileExists(atPath: dest.path)
                else { continue }
                try fm.copyItem(at: dir, to: dest)
                result.favorites += 1
            }
        }

        ReceptionStore.postChanged()
        return result
    }
}

// MARK: - Export

/// The whole library as a folder, for fileExporter.
nonisolated struct LibraryExport: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]

    init() {}

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let fm = FileManager.default
        var pictures: [String: FileWrapper] = [:]
        for meta in ReceptionStore.list() {
            let dir = ReceptionStore.folder(for: meta.id)
            var files: [String: FileWrapper] = [:]
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let name = file.lastPathComponent
                guard !["synced", "audio-synced"].contains(name),
                      let w = try? FileWrapper(url: file, options: [])     // read lazily, as it's written
                else { continue }
                files[name] = w
            }
            pictures[meta.id] = FileWrapper(directoryWithFileWrappers: files)
        }

        var top: [String: FileWrapper] = [
            "Pictures": FileWrapper(directoryWithFileWrappers: pictures),
            "Read Me.txt": FileWrapper(regularFileWithContents: Data(Self.readMe.utf8)),
        ]
        if fm.fileExists(atPath: FavoritesStore.root.path),
           let favorites = try? FileWrapper(url: FavoritesStore.root, options: []) {
            top["Favorites"] = favorites
        }
        if fm.fileExists(atPath: EventStore.root.path),
           let events = try? FileWrapper(url: EventStore.root, options: []) {
            top["Events"] = events
        }
        return FileWrapper(directoryWithFileWrappers: top)
    }

    static var defaultName: String {
        let day = Date().formatted(.iso8601.year().month().day())
        return "Apricot SSTV \(day)"
    }

    private static let readMe = """
    Apricot SSTV export

    Pictures/<id>/
      image.png    the picture as received
      meta.json    how it was received (mode, times, rows, clock, ...)
      audio.wav    its raw audio, if it was kept (16-bit mono)
      audio.json   the audio's sample rate, and stretches lost to gaps
      notes.json   notes written about it: frequency (MHz), source, note,
                   and the id of its event
      edited.png   the picture developed again in the darkroom, and
      edit.json    the settings it was developed with

    Events/<id>.json
                   an event: name, first and last day, frequency, note

    Favorites/<id>/
      photo.jpg    a picture kept for sending
      info.json    where it was placed in the frame

    In Apricot SSTV: Settings > Import, and pick this folder.
    """
}
