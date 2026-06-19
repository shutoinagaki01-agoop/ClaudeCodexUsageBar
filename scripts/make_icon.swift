import AppKit

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = repo.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let baseSize = 1024
let baseImage = NSImage(size: NSSize(width: baseSize, height: baseSize))

baseImage.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 212, yRadius: 212)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.13, green: 0.38, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.19, green: 0.52, blue: 0.42, alpha: 1),
])!
gradient.draw(in: background, angle: -38)

func drawUsageBar(x: CGFloat, y: CGFloat, width: CGFloat, fill: CGFloat, color: NSColor) {
    let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 54), xRadius: 27, yRadius: 27)
    NSColor(calibratedWhite: 1, alpha: 0.16).setFill()
    track.fill()

    let fillWidth = max(54, width * fill)
    let filled = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillWidth, height: 54), xRadius: 27, yRadius: 27)
    color.setFill()
    filled.fill()
}

let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 78, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
    .paragraphStyle: {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }(),
]

("Claude/Codex Usage" as NSString).draw(in: NSRect(x: 42, y: 642, width: 940, height: 118), withAttributes: labelAttrs)
drawUsageBar(x: 116, y: 520, width: 792, fill: 0.82, color: NSColor(calibratedRed: 0.21, green: 0.72, blue: 0.64, alpha: 1))
drawUsageBar(x: 116, y: 398, width: 792, fill: 0.57, color: NSColor(calibratedRed: 0.41, green: 0.58, blue: 0.97, alpha: 1))

let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 560, y: 336))
bolt.line(to: NSPoint(x: 668, y: 336))
bolt.line(to: NSPoint(x: 608, y: 164))
bolt.line(to: NSPoint(x: 826, y: 420))
bolt.line(to: NSPoint(x: 690, y: 420))
bolt.line(to: NSPoint(x: 742, y: 594))
bolt.close()
NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.28, alpha: 1).setFill()
bolt.fill()

NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
bolt.lineWidth = 4
bolt.stroke()

baseImage.unlockFocus()

func savePNG(_ image: NSImage, size: Int, name: String) throws {
    let target = NSImage(size: NSSize(width: size, height: size))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: NSRect(x: 0, y: 0, width: baseSize, height: baseSize), operation: .copy, fraction: 1)
    target.unlockFocus()

    guard let tiff = target.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "Icon", code: 1)
    }
    try data.write(to: iconset.appendingPathComponent(name))
}

try savePNG(baseImage, size: baseSize, name: "../AppIconSource.png")

let files = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in files {
    try savePNG(baseImage, size: size, name: name)
}
