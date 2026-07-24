//
//  AvatarPhoto.swift
//  Project-Ezra
//
//  Turns whatever the photo picker hands back into avatar-sized bytes. A picked image
//  can be many megabytes; an avatar is never rendered above ~64pt, so we downscale to
//  a small square before it ever reaches the store — this keeps the database light and
//  (once CloudKit is on) keeps sync cheap.
//

import Foundation
import UIKit

enum AvatarPhoto {
    /// Longest edge of a stored avatar. Comfortably above the largest render (~64pt @3x).
    static let maxDimension: CGFloat = 256

    /// Downscale + center-crop to a square, returning PNG bytes. Nil if the data isn't
    /// a decodable image.
    static func downscaled(_ data: Data, to dimension: CGFloat = maxDimension) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        // Center-crop to a square first so the squircle never distorts the subject.
        let cropOrigin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let target = CGSize(width: dimension, height: dimension)

        let renderer = UIGraphicsImageRenderer(size: target, format: .init(for: .init(displayScale: 1)))
        return renderer.pngData { _ in
            let scale = dimension / side
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(
                in: CGRect(
                    x: -cropOrigin.x * scale, y: -cropOrigin.y * scale,
                    width: drawSize.width, height: drawSize.height))
        }
    }
}
