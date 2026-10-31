// SPDX-License-Identifier: GPL-3.0-only
//
//  Events.swift
//  What the person writes about a picture, and events that gather
//  pictures (an ISS SSTV weekend, a net, a test with a friend).
//
//    Documents/Receptions/<id>/notes.json   a picture's notes and its event
//    Documents/Events/<uuid>.json           an event
//
//  meta.json stays exactly as the receiver wrote it: notes are a file of
//  their own beside it, written only by hand (or, once, on arrival, when
//  an event is current; see below). A picture belongs to one event or
//  none.
//
//  The current event: one event at a time can be made current, by hand,
//  until the end of its last day or until it's ended by hand. Each time
//  it was current is kept (`currentSpans`). A picture saved here, or
//  arriving from the watch, that was received during one of those spans
//  and has no notes yet joins that event and takes its frequency (not a
//  fragment, though: most are false starts; one can be added by hand). Going
//  by when the picture was received, not when it arrived, means a watch
//  picture that reaches the iPhone hours later still lands in the right
//  event, and one received after the event ended doesn't.
//
//  Only the iPhone keeps events; the watch is told the current event's
//  name (PhoneSync), to show it.
//

import Foundation

// MARK: - Notes

nonisolated struct PictureNotes: Codable, Sendable, Equatable {
    var format = 1
    var event: UUID?
    /// As typed, in MHz ("145.800").
    var frequency = ""
    /// Who or what sent it, as typed: a satellite, a callsign, anything.
    var source = ""
    var note = ""

    init(event: UUID? = nil, frequency: String = "", source: String = "", note: String = "") {
        self.event = event
        self.frequency = frequency
        self.source = source
        self.note = note
    }

    // Missing keys are empty, so a hand-written or older file still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        event = try c.decodeIfPresent(UUID.self, forKey: .event)
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    var isEmpty: Bool {
        event == nil && frequency.isEmpty && source.isEmpty && note.isEmpty
    }
}

// MARK: - Event

nonisolated struct SSTVEvent: Codable, Sendable, Identifiable, Equatable, Hashable {
    var format = 1
    var id = UUID()
    var name: String
    /// First and last day (any time on that day; the calendar day counts).
    var firstDay: Date
    var lastDay: Date
    /// As typed, in MHz.
    var frequency = ""
    var note = ""
    /// The times it was the current event.
    var currentSpans: [DateInterval] = []

    init(name: String, firstDay: Date, lastDay: Date, frequency: String = "", note: String = "") {
        self.name = name
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.frequency = frequency
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        firstDay = try c.decode(Date.self, forKey: .firstDay)
        lastDay = try c.decodeIfPresent(Date.self, forKey: .lastDay) ?? firstDay
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        currentSpans = try c.decodeIfPresent([DateInterval].self, forKey: .currentSpans) ?? []
    }

    /// Midnight after the last day.
    var endsAt: Date {
        let cal = Calendar.current
        let day = cal.startOfDay(for: max(lastDay, firstDay))
        return cal.date(byAdding: .day, value: 1, to: day) ?? day
    }

    var hasEnded: Bool { endsAt <= .now }

    func isCurrent(at now: Date = .now) -> Bool {
        guard let last = currentSpans.last else { return false }
        return last.start <= now && now < last.end
    }

    /// Whether a picture received at `date` belongs here by being current.
    func wasCurrent(at date: Date) -> Bool {
        currentSpans.contains { $0.start <= date && date < $0.end }
    }

    /// When it stops being current (nil: it isn't).
    var currentUntil: Date? {
        isCurrent() ? currentSpans.last?.end : nil
    }

    var displayName: String {
        name.isEmpty ? String(localized: "Untitled Event") : name
    }
}

extension Notification.Name {
    nonisolated static let eventsChanged = Notification.Name("ApricotEventsChanged")
}

// MARK: - Store

nonisolated enum EventStore {
    static var root: URL {
        URL.documentsDirectory.appending(path: "Events", directoryHint: .isDirectory)
    }

    static func url(for id: UUID) -> URL {
        root.appending(path: "\(id.uuidString).json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func decodeEvent(_ data: Data) -> SSTVEvent? {
        try? decoder().decode(SSTVEvent.self, from: data)
    }

    // MARK: Events

    /// Newest first (by first day, then name).
    static func list() -> [SSTVEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(decodeEvent) }
            .sorted { a, b in
                a.firstDay != b.firstDay ? a.firstDay > b.firstDay
                    : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    static func event(id: UUID) -> SSTVEvent? {
        (try? Data(contentsOf: url(for: id))).flatMap(decodeEvent)
    }

    static var current: SSTVEvent? {
        list().first { $0.isCurrent() }
    }

    static func save(_ event: SSTVEvent) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder().encode(event).write(to: url(for: event.id), options: .atomic)
        postChanged()
    }

    /// Saves an edited event. If it's current, it stays current until the
    /// end of its (possibly new) last day.
    static func update(_ event: SSTVEvent) throws {
        var e = event
        if e.isCurrent(), var last = e.currentSpans.popLast() {
            let now = Date.now
            last = DateInterval(start: last.start, end: max(now, e.endsAt))
            e.currentSpans.append(last)
        }
        try save(e)
    }

    /// Makes it the current event from now until the end of its last day;
    /// any other current event ends now.
    static func makeCurrent(id: UUID) throws {
        let now = Date.now
        for var other in list() where other.id != id && other.isCurrent(at: now) {
            other.endCurrent(at: now)
            try save(other)
        }
        guard var e = event(id: id), e.endsAt > now, !e.isCurrent(at: now) else { return }
        e.currentSpans.append(DateInterval(start: now, end: e.endsAt))
        try save(e)
    }

    static func endCurrent(id: UUID) throws {
        guard var e = event(id: id), e.isCurrent() else { return }
        e.endCurrent(at: .now)
        try save(e)
    }

    /// Deletes the event. Its pictures stay, in no event (their other
    /// notes are kept).
    static func delete(id: UUID) {
        for (pictureID, notes) in allNotes() where notes.event == id {
            var cleared = notes
            cleared.event = nil
            saveNotes(cleared, for: pictureID, post: false)
        }
        try? FileManager.default.removeItem(at: url(for: id))
        postChanged()
        ReceptionStore.postChanged()
    }

    // MARK: Notes

    static func notesURL(for pictureID: String) -> URL {
        ReceptionStore.folder(for: pictureID).appending(path: "notes.json")
    }

    static func notes(for pictureID: String) -> PictureNotes? {
        guard ReceptionStore.isValidID(pictureID),
              let data = try? Data(contentsOf: notesURL(for: pictureID))
        else { return nil }
        return try? decoder().decode(PictureNotes.self, from: data)
    }

    /// Writes a picture's notes (empty notes remove the file). `post`:
    /// tell the lists (not while typing: once, when done).
    static func saveNotes(_ notes: PictureNotes, for pictureID: String, post: Bool = true) {
        guard ReceptionStore.isValidID(pictureID),
              FileManager.default.fileExists(atPath: ReceptionStore.folder(for: pictureID).path)
        else { return }
        let url = notesURL(for: pictureID)
        if notes.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? encoder().encode(notes) {
            try? data.write(to: url, options: .atomic)
        }
        if post { ReceptionStore.postChanged() }
    }

    /// Every picture's notes, by picture.
    static func allNotes() -> [String: PictureNotes] {
        var all: [String: PictureNotes] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: ReceptionStore.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for dir in dirs {
            let id = dir.lastPathComponent
            if let n = notes(for: id) { all[id] = n }
        }
        return all
    }

    /// Puts pictures in an event (nil: in none). Joining an event fills in
    /// its frequency where none was written; nothing else is touched.
    static func setEvent(_ eventID: UUID?, for pictureIDs: some Sequence<String>) {
        let target = eventID.flatMap { Self.event(id: $0) }
        for id in pictureIDs {
            var n = notes(for: id) ?? PictureNotes()
            n.event = target?.id
            if let target, n.frequency.isEmpty { n.frequency = target.frequency }
            saveNotes(n, for: id, post: false)
        }
        ReceptionStore.postChanged()
    }

    /// A picture was just saved or arrived: if it has no notes and was
    /// received while an event was current, it joins that event.
    static func assignOnArrival(_ meta: ReceptionMeta) {
        guard ReceptionStore.isValidID(meta.id), !meta.isFragment,
              !FileManager.default.fileExists(atPath: notesURL(for: meta.id).path),
              let event = list().first(where: { $0.wasCurrent(at: meta.startedAt) })
        else { return }
        saveNotes(PictureNotes(event: event.id, frequency: event.frequency), for: meta.id, post: false)
    }

    static func postChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .eventsChanged, object: nil)
        }
        #if os(iOS)
        PhoneSync.shared.sendCurrentEvent()
        #endif
    }
}

private extension SSTVEvent {
    mutating func endCurrent(at now: Date) {
        guard let last = currentSpans.last, last.start <= now, now < last.end else { return }
        currentSpans[currentSpans.count - 1] = DateInterval(start: last.start, end: max(last.start, now))
    }
}

// MARK: - The watch's copy of the current event

/// What the watch shows: the current event's name, and until when.
nonisolated enum CurrentEventInfo {
    static let nameKey = "currentEvent.name"
    static let untilKey = "currentEvent.until"

    /// The iPhone's message (PhoneSync / WatchSync).
    static func message(for event: SSTVEvent?) -> [String: Any] {
        guard let event, let until = event.currentUntil else {
            return ["event": "", "until": 0.0]
        }
        return ["event": event.displayName, "until": until.timeIntervalSince1970]
    }

    /// Watch: keeps the message, for @AppStorage to show.
    static func store(_ message: [String: Any]) {
        let name = message["event"] as? String ?? ""
        let until = message["until"] as? Double ?? 0
        DispatchQueue.main.async {
            UserDefaults.standard.set(name, forKey: nameKey)
            UserDefaults.standard.set(until, forKey: untilKey)
        }
    }
}
