// compare.swift: lay screenshots side by side, each labelled, into one PNG.
// usage: swift compare.swift <out.png> <a.png> <b.png> [label=path …]
// A `label=path` argument sets the caption; a bare path is captioned with its file name.
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
  FileHandle.standardError.write(
    "usage: compare.swift <out.png> <a.png> <b.png> [label=path …]\n".data(using: .utf8)!)
  exit(2)
}
let out = args[0]
let items: [(label: String, image: NSImage)] = args.dropFirst().map { arg in
  let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
  let path = parts.count == 2 && !FileManager.default.fileExists(atPath: arg) ? parts[1] : arg
  let label =
    parts.count == 2 && path == parts[1]
    ? parts[0] : (path as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
  guard let img = NSImage(contentsOfFile: path) else {
    FileHandle.standardError.write("no such image: \(path)\n".data(using: .utf8)!)
    exit(1)
  }
  return (label, img)
}

let height: CGFloat = 1400
let gap: CGFloat = 24
let captionH: CGFloat = 90
func pixelSize(_ i: NSImage) -> CGSize {
  if let rep = i.representations.first, rep.pixelsWide > 0 {
    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
  }
  return i.size
}
let widths = items.map { pixelSize($0.image).width * height / pixelSize($0.image).height }
let total = CGSize(
  width: widths.reduce(0, +) + gap * CGFloat(items.count + 1), height: height + captionH + gap)

guard
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(total.width), pixelsHigh: Int(total.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = total
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.13, alpha: 1).setFill()
NSRect(origin: .zero, size: total).fill()
let attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
  .foregroundColor: NSColor.white,
]
var x = gap
for (i, item) in items.enumerated() {
  item.image.draw(in: NSRect(x: x, y: captionH, width: widths[i], height: height))
  let text = NSAttributedString(string: item.label, attributes: attrs)
  let ts = text.size()
  text.draw(at: NSPoint(x: x + (widths[i] - ts.width) / 2, y: (captionH - ts.height) / 2))
  x += widths[i] + gap
}
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print(out)
