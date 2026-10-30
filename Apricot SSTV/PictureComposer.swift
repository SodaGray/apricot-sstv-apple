// SPDX-License-Identifier: GPL-3.0-only
//
//  PictureComposer.swift
//  Apricot SSTV
//
//  The picture to send: the photo placed in the mode's frame where the
//  user put it, with the callsign and a second line drawn on top.
//
//  PhotoPlacement is the one description of "where the photo is", used
//  both by the adjust screen (live, with gestures) and by compose(), so
//  what is sent is exactly what the adjust screen showed.
//

import UIKit

// MARK: - Placement

nonisolated struct PhotoPlacement: Equatable, Sendable {
    /// 1 = the photo just fills the frame. Less shows the whole photo
    /// with bars (down to "fit"); more zooms in.
    var zoom: CGFloat = 1
    /// The photo's centre relative to the frame's centre, as a fraction
    /// of the frame's width and height, so it carries over between modes.
    var offset: CGSize = .zero

    static let maxZoom: CGFloat = 5

    static func fillScale(photo: CGSize, frame: CGSize) -> CGFloat {
        max(frame.width / photo.width, frame.height / photo.height)
    }

    /// The zoom at which the whole photo fits inside the frame.
    static func fitZoom(photo: CGSize, frame: CGSize) -> CGFloat {
        min(frame.width / photo.width, frame.height / photo.height) / fillScale(photo: photo, frame: frame)
    }

    /// Zoom kept between fit and maxZoom; offset kept so the photo never
    /// leaves an uncovered edge on a side where it is larger than the
    /// frame, and stays centred on a side where it is smaller.
    func clamped(photo: CGSize, frame: CGSize) -> PhotoPlacement {
        guard photo.width > 0, photo.height > 0, frame.width > 0, frame.height > 0 else { return self }
        var p = self
        let lo = Self.fitZoom(photo: photo, frame: frame)
        p.zoom = min(max(zoom, lo), Self.maxZoom)

        let k = Self.fillScale(photo: photo, frame: frame) * p.zoom
        let maxX = max(0, (photo.width * k - frame.width) / 2) / frame.width
        let maxY = max(0, (photo.height * k - frame.height) / 2) / frame.height
        p.offset.width = min(max(offset.width, -maxX), maxX)
        p.offset.height = min(max(offset.height, -maxY), maxY)
        return p
    }

    /// Where the photo goes, in the frame's coordinates (top-left origin).
    func rect(photo: CGSize, frame: CGSize) -> CGRect {
        let p = clamped(photo: photo, frame: frame)
        let k = Self.fillScale(photo: photo, frame: frame) * p.zoom
        let w = photo.width * k
        let h = photo.height * k
        let cx = frame.width / 2 + p.offset.width * frame.width
        let cy = frame.height / 2 + p.offset.height * frame.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Composer

@MainActor
enum PictureComposer {
    /// Longest side kept from a picked photo. More than any mode needs
    /// even at 5× zoom on PD290, and keeps drawing quick.
    static let maxPhotoSide: CGFloat = 2400

    /// Downscales a picked photo and bakes in its orientation.
    static func prepare(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let k = min(1, maxPhotoSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The picture to send, at the mode's size.
    static func compose(
        photo: UIImage?,
        placement: PhotoPlacement,
        mode: SSTVMode,
        callsign: String,
        text: String
    ) -> UIImage {
        let frame = CGSize(width: mode.width, height: mode.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: frame, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: frame))
            if let photo, photo.size.width > 0, photo.size.height > 0 {
                photo.draw(in: placement.rect(photo: photo.size, frame: frame))
            }
            drawText(callsign: callsign, text: text, frame: frame)
        }
    }

    /// Just the text, on a transparent layer at the mode's size: the
    /// adjust screen lays it over the photo while it moves.
    static func overlay(mode: SSTVMode, callsign: String, text: String) -> UIImage {
        let frame = CGSize(width: mode.width, height: mode.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: frame, format: format).image { _ in
            drawText(callsign: callsign, text: text, frame: frame)
        }
    }

    /// The callsign large at the top left, a second line under it.
    private static func drawText(callsign: String, text: String, frame: CGSize) {
        let pad = frame.height * 0.035
        var y = pad
        let call = callsign.trimmingCharacters(in: .whitespaces)
        if !call.isEmpty {
            y += draw(call.uppercased(), size: frame.height * 0.11, weight: .heavy, at: CGPoint(x: pad, y: y))
        }
        let line = text.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty {
            _ = draw(line, size: frame.height * 0.065, weight: .bold, at: CGPoint(x: pad, y: y))
        }
    }

    /// White text with a black outline; returns its height.
    private static func draw(_ string: String, size: CGFloat, weight: UIFont.Weight, at point: CGPoint) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        attributed.draw(at: point)
        return attributed.size().height
    }

    /// width × height × 3 RGB bytes, as the encoder wants them.
    static func rgbBytes(of image: UIImage, mode: SSTVMode) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        return rgbBytes(of: cg, mode: mode)
    }

    /// The same, from any thread (the WAV export runs off the main one).
    nonisolated static func rgbBytes(of cg: CGImage, mode: SSTVMode) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = mode.width
        let h = mode.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }
}
