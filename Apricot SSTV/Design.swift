// SPDX-License-Identifier: GPL-3.0-only
//
//  Design.swift
//  Apricot SSTV
//
//  Big pictures (Receive, Send, a picture's details) are rows of their
//  own, edge to edge, and take their corners from the list's section,
//  so they always match the system. This is only for the thumbnails in
//  the Pictures grid, which sit on no background, with the system's
//  continuous curve.
//

import SwiftUI

enum Design {
    static let thumbnailCornerRadius: CGFloat = 12

    static var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: thumbnailCornerRadius, style: .continuous)
    }
}
