// SPDX-License-Identifier: GPL-3.0-only
//
//  PhotoAdjustView.swift
//  Apricot SSTV
//
//  Place the photo in the mode's frame: drag to move, pinch to zoom,
//  double-tap to switch between fill and fit. The part outside the
//  frame shows dimmed, and the text is drawn on top exactly as sent.
//

import SwiftUI

struct PhotoAdjustView: View {
    let photo: UIImage
    let mode: SSTVMode
    let overlay: UIImage
    @Binding var placement: PhotoPlacement

    @Environment(\.dismiss) private var dismiss
    @State private var working = PhotoPlacement()
    @State private var gestureBase: PhotoPlacement?

    private var frameSize: CGSize { CGSize(width: mode.width, height: mode.height) }
    private var photoSize: CGSize { photo.size }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                editor(in: geo.size)
            }
            .background(Color.black)
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        placement = working
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Fit Whole Photo") { set(zoom: PhotoPlacement.fitZoom(photo: photoSize, frame: frameSize)) }
                    Spacer()
                    Button("Fill Frame") { set(zoom: 1) }
                }
            }
        }
        .onAppear {
            working = placement.clamped(photo: photoSize, frame: frameSize)
        }
    }

    // MARK: Editor

    private func editor(in area: CGSize) -> some View {
        // The frame, as large as fits with a margin, keeping the mode's shape.
        let margin: CGFloat = 20
        let s = min(
            (area.width - 2 * margin) / frameSize.width,
            (area.height - 2 * margin) / frameSize.height
        )
        let vw = frameSize.width * s
        let vh = frameSize.height * s
        let origin = CGPoint(x: (area.width - vw) / 2, y: (area.height - vh) / 2)
        let r = working.rect(photo: photoSize, frame: frameSize)

        return ZStack(alignment: .topLeading) {
            // The whole photo, dimmed, so you can see what's outside the frame.
            Image(uiImage: photo)
                .resizable()
                .frame(width: r.width * s, height: r.height * s)
                .position(x: origin.x + r.midX * s, y: origin.y + r.midY * s)
                .opacity(0.3)

            // Inside the frame: the picture as it will be sent.
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: photo)
                    .resizable()
                    .frame(width: r.width * s, height: r.height * s)
                    .position(x: r.midX * s, y: r.midY * s)
                Image(uiImage: overlay)
                    .resizable()
                    .frame(width: vw, height: vh)
            }
            .frame(width: vw, height: vh)
            .clipped()
            .overlay(Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .offset(x: origin.x, y: origin.y)
        }
        .frame(width: area.width, height: area.height)
        .contentShape(Rectangle())
        .gesture(moveAndZoom(frameWidth: vw, frameHeight: vh))
        .onTapGesture(count: 2) {
            let fit = PhotoPlacement.fitZoom(photo: photoSize, frame: frameSize)
            set(zoom: abs(working.zoom - 1) < 0.01 ? fit : 1)
        }
        .accessibilityLabel("Photo in the \(mode.name) frame")
        .accessibilityHint("Double-tap to switch between fill and fit.")
    }

    private func moveAndZoom(frameWidth: CGFloat, frameHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: MagnifyGesture())
            .onChanged { value in
                if gestureBase == nil { gestureBase = working }
                guard let base = gestureBase, frameWidth > 0, frameHeight > 0 else { return }
                var p = base
                if let magnify = value.second {
                    p.zoom = base.zoom * magnify.magnification
                }
                if let drag = value.first {
                    p.offset.width = base.offset.width + drag.translation.width / frameWidth
                    p.offset.height = base.offset.height + drag.translation.height / frameHeight
                }
                working = p.clamped(photo: photoSize, frame: frameSize)
            }
            .onEnded { _ in
                gestureBase = nil
            }
    }

    private func set(zoom: CGFloat) {
        withAnimation(.snappy) {
            working = PhotoPlacement(zoom: zoom, offset: .zero).clamped(photo: photoSize, frame: frameSize)
        }
    }
}
