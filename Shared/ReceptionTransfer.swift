// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionTransfer.swift
//  What travels from the watch to the iPhone: image.png as the file,
//  meta.json in the transfer's metadata. Both sides use this file.
//

import Foundation

nonisolated enum ReceptionTransfer {
    private static let kindKey = "kind"
    private static let kindValue = "reception"
    private static let idKey = "id"
    private static let metaKey = "meta"

    /// Metadata for WCSession.transferFile (property-list types only).
    static func metadata(for meta: ReceptionMeta) throws -> [String: Any] {
        [
            kindKey: kindValue,
            idKey: meta.id,
            metaKey: try ReceptionStore.encodeMeta(meta)
        ]
    }

    /// The reception ID a transfer carries, if it is one of ours.
    static func id(from metadata: [String: Any]?) -> String? {
        guard
            let metadata,
            metadata[kindKey] as? String == kindValue,
            let id = metadata[idKey] as? String,
            ReceptionStore.isValidID(id)
        else { return nil }
        return id
    }

    /// The metadata a transfer carries, checked against its ID.
    static func meta(from metadata: [String: Any]?) -> ReceptionMeta? {
        guard
            let id = id(from: metadata),
            let data = metadata?[metaKey] as? Data,
            let meta = ReceptionStore.decodeMeta(data),
            meta.id == id
        else { return nil }
        return meta
    }
}
