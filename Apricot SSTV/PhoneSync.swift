// SPDX-License-Identifier: GPL-3.0-only
//
//  PhoneSync.swift
//  Apricot SSTV
//
//  Receives pictures from the watch. The system can launch the app in
//  the background to deliver them, so the session is activated in the
//  App's init, before any screen exists. An arriving file is only valid
//  during the delegate call, so it's copied into the store right there.
//

import Foundation
import WatchConnectivity

nonisolated final class PhoneSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneSync()

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

    // MARK: Watch status (for Settings)

    nonisolated enum WatchStatus: Sendable {
        case unsupported, notPaired, appNotInstalled, ready
    }

    var watchStatus: WatchStatus {
        guard WCSession.isSupported() else { return .unsupported }
        let s = WCSession.default
        guard s.activationState == .activated else { return .notPaired }
        if !s.isPaired { return .notPaired }
        return s.isWatchAppInstalled ? .ready : .appNotInstalled
    }

    // MARK: WCSessionDelegate

    /// Pairing or the watch app's install state changed: Settings shows it.
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let meta = ReceptionTransfer.meta(from: file.metadata) else { return }
        do {
            try ReceptionStore.importReception(imageAt: file.fileURL, meta: meta)
        } catch {
            print("[PhoneSync] import \(meta.id) failed: \(error.localizedDescription)")
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        sessionWatchStateDidChange(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another paired watch: start a session with the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

extension Notification.Name {
    nonisolated static let watchStateChanged = Notification.Name("ApricotWatchStateChanged")
}
