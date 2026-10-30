// SPDX-License-Identifier: GPL-3.0-only
//
//  WatchSync.swift
//  Apricot SSTV Watch Watch App
//
//  Sends saved pictures to the iPhone with WCSession.transferFile.
//  The system queues transfers and delivers them when it can (phone
//  away, app closed: it waits). A finished transfer marks the picture
//  synced. On every launch, anything not yet synced and not already
//  queued is queued again, so nothing is lost if the app was quit.
//

import Foundation
import WatchConnectivity

nonisolated final class WatchSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSync()

    private let queue = DispatchQueue(label: "Apricot.sync", qos: .utility)
    private let lock = NSLock()
    private var activated = false

    /// Call once at launch (the App's init).
    func activate() {
        guard WCSession.isSupported() else { return }
        let first = lock.withLock {
            defer { activated = true }
            return !activated
        }
        guard first else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// False until the session is up, or if the iPhone app isn't installed.
    var canSend: Bool {
        guard WCSession.isSupported() else { return false }
        let s = WCSession.default
        return s.activationState == .activated && s.isCompanionAppInstalled
    }

    /// Queues a saved picture for the iPhone. A picture saved again
    /// (it resumed after a fade) replaces its queued older version.
    func send(id: String) {
        queue.async { [self] in
            cancelOutstanding(id: id)
            transfer(id: id)
        }
    }

    /// Deletes a picture on the watch, cancelling its transfer if queued.
    func delete(id: String) {
        queue.async { [self] in
            cancelOutstanding(id: id)
            try? ReceptionStore.delete(id: id)
        }
    }

    /// Deletes every picture the iPhone already has.
    func deleteSynced() {
        queue.async {
            for meta in ReceptionStore.list() where ReceptionStore.isSynced(id: meta.id) {
                try? ReceptionStore.delete(id: meta.id)
            }
        }
    }

    // MARK: Queue (on `queue`)

    private func transfer(id: String) {
        guard canSend, !ReceptionStore.isSynced(id: id),
              let meta = ReceptionStore.meta(id: id),
              let metadata = try? ReceptionTransfer.metadata(for: meta)
        else { return }
        WCSession.default.transferFile(ReceptionStore.imageURL(for: id), metadata: metadata)
    }

    private func cancelOutstanding(id: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        for t in WCSession.default.outstandingFileTransfers
        where ReceptionTransfer.id(from: t.file.metadata) == id {
            t.cancel()
        }
    }

    /// Queues everything not synced and not already on its way.
    private func resyncAll() {
        guard canSend else { return }
        let queued = Set(
            WCSession.default.outstandingFileTransfers
                .compactMap { ReceptionTransfer.id(from: $0.file.metadata) }
        )
        for meta in ReceptionStore.list()
        where !queued.contains(meta.id) && !ReceptionStore.isSynced(id: meta.id) {
            transfer(id: meta.id)
        }
    }

    // MARK: WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        queue.async { [self] in resyncAll() }
        ReceptionStore.postChanged()
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        queue.async { [self] in resyncAll() }
        ReceptionStore.postChanged()
    }

    func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard error == nil,
              let id = ReceptionTransfer.id(from: fileTransfer.file.metadata)
        else { return }
        queue.async {
            ReceptionStore.markSynced(id: id)
        }
    }
}
