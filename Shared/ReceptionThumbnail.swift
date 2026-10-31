// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionThumbnail.swift
//  A saved picture, loaded off the main thread. Reloads when the
//  picture is saved again (a resumed picture keeps its ID), or edited.
//

import SwiftUI
import CoreGraphics
import Combine

struct Thumbnail: View {
    let meta: ReceptionMeta
    var cornerRadius: CGFloat = 3

    @State private var image: CGImage?
    /// When the darkroom last saved or reverted it (0: never).
    @State private var editStamp: Double = 0

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear { editStamp = ReceptionStore.editStamp(id: meta.id) }
        .onReceive(NotificationCenter.default.publisher(for: .receptionsChanged)) { _ in
            editStamp = ReceptionStore.editStamp(id: meta.id)
        }
        .task(id: "\(meta.id)|\(meta.endedAt.timeIntervalSince1970)|\(editStamp)") {
            let id = meta.id
            let loaded = await Task.detached(priority: .utility) {
                LoadedImage(image: ReceptionStore.loadImage(id: id))
            }.value
            image = loaded.image
        }
    }
}

/// CGImage is immutable; this lets it cross from the loading task.
nonisolated private struct LoadedImage: @unchecked Sendable {
    let image: CGImage?
}
