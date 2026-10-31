// SPDX-License-Identifier: GPL-3.0-only
//
//  WatchSync.swift
//  Apricot SSTV Watch Watch App
//
//  Sends saved pictures, and their audio, to the iPhone with
//  WCSession.transferFile. The system queues transfers and delivers them
//  when it can (phone away, app closed: it waits). A finished transfer
//  marks the picture (or its audio) synced. On every launch, anything not
//  yet synced and not already queued is queued again, so nothing is lost
//  if the app was quit.
//
//  A picture's audio goes only once the picture itself has arrived, so
//  the iPhone never holds audio without its picture, and the much larger
//  audio file never holds up the picture.
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
            cancelOutstanding(id: id, kind: .picture)
            transferImage(id: id)
        }
    }

    /// Queues a picture's audio, which was finished after the picture.
    /// It waits for the picture if that hasn't arrived yet.
    func sendAudio(id: String) {
        queue.async { [self] in
            cancelOutstanding(id: id, kind: .audio)
            transferAudio(id: id)
        }
    }

    /// Deletes a picture (and its audio) on the watch, cancelling its
    /// transfers if queued.
    func delete(id: String) {
        queue.async { [self] in
            cancelOutstanding(id: id, kind: nil)
            try? ReceptionStore.delete(id: id)
        }
    }

    /// Deletes every picture the iPhone already has in full.
    func deleteSynced() {
        queue.async {
            for meta in ReceptionStore.list() where ReceptionStore.isSynced(id: meta.id) {
                try? ReceptionStore.delete(id: meta.id)
            }
        }
    }

    // MARK: Queue (on `queue`)

    private func transferImage(id: String) {
        guard canSend, !ReceptionStore.isImageSynced(id: id),
              let meta = ReceptionStore.meta(id: id),
              let metadata = try? ReceptionTransfer.metadata(for: meta)
        else { return }
        WCSession.default.transferFile(ReceptionStore.imageURL(for: id), metadata: metadata)
    }

    private func transferAudio(id: String) {
        guard canSend,
              ReceptionStore.isImageSynced(id: id),
              ReceptionStore.hasAudio(id: id),
              !ReceptionStore.isAudioSynced(id: id),
              let info = ReceptionStore.audioInfo(id: id),
              let metadata = try? ReceptionTransfer.metadata(forAudioOf: id, info: info)
        else { return }
        WCSession.default.transferFile(ReceptionStore.audioURL(for: id), metadata: metadata)
    }

    /// Cancels queued transfers of one picture: of one kind, or all (nil).
    private func cancelOutstanding(id: String, kind: ReceptionTransfer.Kind?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        for t in WCSession.default.outstandingFileTransfers
        where ReceptionTransfer.id(from: t.file.metadata) == id
            && (kind == nil || ReceptionTransfer.kind(from: t.file.metadata) == kind) {
            t.cancel()
        }
    }

    /// Queues everything not synced and not already on its way.
    private func resyncAll() {
        guard canSend else { return }
        var queuedImages = Set<String>()
        var queuedAudio = Set<String>()
        for t in WCSession.default.outstandingFileTransfers {
            guard let id = ReceptionTransfer.id(from: t.file.metadata) else { continue }
            switch ReceptionTransfer.kind(from: t.file.metadata) {
            case .picture: queuedImages.insert(id)
            case .audio: queuedAudio.insert(id)
            case nil: break
            }
        }
        for meta in ReceptionStore.list() {
            let id = meta.id
            if !ReceptionStore.isImageSynced(id: id) {
                if !queuedImages.contains(id) { transferImage(id: id) }
            } else if !queuedAudio.contains(id) {
                transferAudio(id: id)
            }
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
        CurrentEventInfo.store(session.receivedApplicationContext)
    }

    /// The iPhone's current event changed (shown under Listen).
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        CurrentEventInfo.store(applicationContext)
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
        let metadata = fileTransfer.file.metadata
        guard error == nil,
              let id = ReceptionTransfer.id(from: metadata),
              let kind = ReceptionTransfer.kind(from: metadata)
        else { return }
        queue.async { [self] in
            switch kind {
            case .picture:
                ReceptionStore.markSynced(id: id)
                transferAudio(id: id)      // its audio may have been waiting
            case .audio:
                ReceptionStore.markAudioSynced(id: id)
            }
        }
    }
}
