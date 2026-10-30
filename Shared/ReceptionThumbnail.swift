// SPDX-License-Identifier: GPL-3.0-only
//
//  ReceptionThumbnail.swift
//  A saved picture, loaded off the main thread. Reloads when the
//  picture is saved again (a resumed picture keeps its ID).
//

import SwiftUI
import CoreGraphics

struct Thumbnail: View {
    let meta: ReceptionMeta
    var cornerRadius: CGFloat = 3

    @State private var image: CGImage?

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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(meta.id)|\(meta.endedAt.timeIntervalSince1970)") {
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
