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

    private var observer: AnyCancellable?

    init() {
        reload()
        observer = NotificationCenter.default
            .publisher(for: .receptionsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        let list = ReceptionStore.list()
        items = list
        syncedIDs = Set(list.map(\.id).filter { ReceptionStore.isSynced(id: $0) })
    }
}
