import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let radius = size * 0.22
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.90, green: 0.52, blue: 0.38, alpha: 1.0),
            NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.17, alpha: 1.0),
        ])
        gradient?.draw(in: path, angle: -60)

        let symbolSize = size * 0.56
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.white.set()
            let bounds = NSRect(origin: .zero, size: tinted.size)
            bounds.fill(using: .sourceAtop)
            tinted.unlockFocus()

            let symbolRect = NSRect(
                x: (size - tinted.size.width) / 2,
                y: (size - tinted.size.height) / 2,
                width: tinted.size.width,
                height: tinted.size.height
            )
            tinted.draw(in: symbolRect)

            // Sparkle on the front card
            let sparkleConfig = NSImage.SymbolConfiguration(pointSize: size * 0.24, weight: .bold)
            if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(sparkleConfig) {
                let coral = sparkle.copy() as! NSImage
                coral.lockFocus()
                NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1.0).set()
                NSRect(origin: .zero, size: coral.size).fill(using: .sourceAtop)
                coral.unlockFocus()
                coral.draw(in: NSRect(
                    x: (size - coral.size.width) / 2,
                    y: symbolRect.minY + symbolRect.height * 0.37 - coral.size.height / 2,
                    width: coral.size.width,
                    height: coral.size.height
                ))
            }
        }

        return true
    }
    return image
}

for entry in sizes {
    let size = CGFloat(entry.px)
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(entry.name)")
        continue
    }
    let path = "\(outputDir)/\(entry.name).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}
