// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionTransfer.swift
//  What travels from the watch to the iPhone. Two kinds of transfer:
//
//    picture  the file is image.png, meta.json is in the metadata
//    audio    the file is audio.wav, audio.json is in the metadata
//
//  They're separate because the audio is finished after the picture (it
//  keeps a short tail, or the resume window after a loss), and either
//  may arrive first. Both sides use this file.
//

import Foundation

nonisolated enum ReceptionTransfer {
    nonisolated enum Kind: String, Sendable {
        case picture = "reception"
        case audio = "audio"
    }

    private static let kindKey = "kind"
    private static let idKey = "id"
    private static let metaKey = "meta"
    private static let audioKey = "audio"

    /// Metadata for a picture's transfer (property-list types only).
    static func metadata(for meta: ReceptionMeta) throws -> [String: Any] {
        [
            kindKey: Kind.picture.rawValue,
            idKey: meta.id,
            metaKey: try ReceptionStore.encodeMeta(meta)
        ]
    }

    /// Metadata for an audio transfer.
    static func metadata(forAudioOf id: String, info: AudioInfo) throws -> [String: Any] {
        [
            kindKey: Kind.audio.rawValue,
            idKey: id,
            audioKey: try JSONEncoder().encode(info)
        ]
    }

    static func kind(from metadata: [String: Any]?) -> Kind? {
        (metadata?[kindKey] as? String).flatMap(Kind.init(rawValue:))
    }

    /// The reception ID a transfer carries, if it is one of ours.
    static func id(from metadata: [String: Any]?) -> String? {
        guard
            let metadata,
            kind(from: metadata) != nil,
            let id = metadata[idKey] as? String,
            ReceptionStore.isValidID(id)
        else { return nil }
        return id
    }

    /// A picture transfer's metadata, checked against its ID.
    static func meta(from metadata: [String: Any]?) -> ReceptionMeta? {
        guard
            kind(from: metadata) == .picture,
            let id = id(from: metadata),
            let data = metadata?[metaKey] as? Data,
            let meta = ReceptionStore.decodeMeta(data),
            meta.id == id
        else { return nil }
        return meta
    }

    /// An audio transfer's ID and audio.json.
    static func audio(from metadata: [String: Any]?) -> (id: String, info: AudioInfo)? {
        guard
            kind(from: metadata) == .audio,
            let id = id(from: metadata),
            let data = metadata?[audioKey] as? Data,
            let info = try? JSONDecoder().decode(AudioInfo.self, from: data)
        else { return nil }
        return (id, info)
    }
}
