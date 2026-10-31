// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionList.swift
//  The saved pictures, for the gallery screens. Reloads whenever the
//  store changes (a save, an arrival from the watch, a delete).
//

import Foundation
import Combine

@MainActor
final class ReceptionList: ObservableObject {
    @Published private(set) var items: [ReceptionMeta] = []
    /// Watch: pictures the iPhone already has.
    @Published private(set) var syncedIDs: Set<String> = []
    /// iPhone: each picture's notes (Events.swift), and the events.
    @Published private(set) var notes: [String: PictureNotes] = [:]
    @Published private(set) var events: [SSTVEvent] = []
    /// Fragments (ReceptionMeta.isFragment) not developed into a picture
    /// in the darkroom since.
    @Published private(set) var fragmentIDs: Set<String> = []

    private var observers: [AnyCancellable] = []

    init() {
        reload()
        observers.append(NotificationCenter.default
            .publisher(for: .receptionsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() })
        #if os(iOS)
        observers.append(NotificationCenter.default
            .publisher(for: .eventsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.events = EventStore.list() })
        #endif
    }

    func reload() {
        let list = ReceptionStore.list()
        items = list
        fragmentIDs = Set(list.filter { $0.isFragment && !ReceptionStore.hasEdit(id: $0.id) }.map(\.id))
        #if os(iOS)
        notes = EventStore.allNotes()
        events = EventStore.list()
        #else
        syncedIDs = Set(list.map(\.id).filter { ReceptionStore.isSynced(id: $0) })
        #endif
    }

    /// The event a picture is in, if it still exists.
    func event(of pictureID: String) -> SSTVEvent? {
        guard let id = notes[pictureID]?.event else { return nil }
        return events.first { $0.id == id }
    }

    /// An event's pictures (not fragments), oldest first.
    func pictures(in event: SSTVEvent) -> [ReceptionMeta] {
        items
            .filter { notes[$0.id]?.event == event.id && !fragmentIDs.contains($0.id) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The picture shown for an event: the one chosen, or its first.
    func cover(of event: SSTVEvent) -> ReceptionMeta? {
        let pictures = pictures(in: event)
        if let id = event.cover, let chosen = pictures.first(where: { $0.id == id }) { return chosen }
        return pictures.first
    }

    var currentEvent: SSTVEvent? {
        events.first { $0.isCurrent() }
    }
}
