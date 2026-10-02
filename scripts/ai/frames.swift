// frames.swift: tile a screen recording into one contact sheet, each frame numbered.
// AVFoundation only (ships with macOS), so no ffmpeg.
// usage: swift frames.swift <in.mov> <out.png> [fps=10] [columns=6]
import AVFoundation
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else {
    FileHandle.standardError.write("usage: frames.swift <in.mov> <out.png> [fps] [columns]\n".data(using: .utf8)!)
    exit(2)
}
let fps = a.count > 3 ? Double(a[3]) ?? 10 : 10
let cols = a.count > 4 ? Int(a[4]) ?? 6 : 6
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let duration = try await asset.load(.duration).seconds
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.maximumSize = CGSize(width: 300, height: 0)
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
let count = max(1, Int((duration * fps).rounded(.up)))
var images: [CGImage] = []
for i in 0..<count {
    let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
    if let (img, _) = try? await gen.image(at: t) { images.append(img) }
}
guard let first = images.first else { FileHandle.standardError.write("no frames\n".data(using: .utf8)!); exit(1) }
let w = CGFloat(first.width), h = CGFloat(first.height)
let rows = (images.count + cols - 1) / cols
let size = CGSize(width: w * CGFloat(cols), height: h * CGFloat(rows))
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold),
                                            .foregroundColor: NSColor.yellow, .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
for (i, img) in images.enumerated() {
    let x = CGFloat(i % cols) * w, y = size.height - CGFloat(i / cols + 1) * h
    NSImage(cgImage: img, size: NSSize(width: w, height: h)).draw(in: NSRect(x: x, y: y, width: w, height: h))
    NSAttributedString(string: " \(i) ", attributes: attrs).draw(at: NSPoint(x: x + 6, y: y + h - 30))
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("\(a[2]) (\(images.count) frames at \(Int(fps)) fps, \(cols)x\(rows))")
