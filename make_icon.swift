import AppKit
import Foundation

// 程序化生成两套 macOS 应用图标（.iconset）。
// 设计：squircle（圆角方块）渐变背景 + 居中白色 SF Symbol。
//   ClamOpen      —— 蓝紫渐变 + laptopcomputer.slash（内置屏已关）
//   恢复内置屏     —— 绿色渐变 + laptopcomputer（屏幕恢复）

func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let size = base.size
    let out = NSImage(size: size)
    out.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func drawIcon(pixel: Int, symbol: String, top: NSColor, bottom: NSColor) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixel, height: pixel)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let p = CGFloat(pixel)
    let inset = p * 0.085                                   // 四周留白（macOS 图标规范）
    let rect = NSRect(x: inset, y: inset, width: p - 2*inset, height: p - 2*inset)
    let radius = rect.width * 0.2237                        // squircle 圆角近似
    let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    clip.addClip()

    if let grad = NSGradient(starting: top, ending: bottom) {
        grad.draw(in: rect, angle: -90)                    // top 在上、bottom 在下
    }
    // 顶部一层很淡的高光，增加质感
    NSColor(white: 1, alpha: 0.10).setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY,
                                     width: rect.width, height: rect.height/2),
                 xRadius: radius, yRadius: radius).fill()

    if let sym = tintedSymbol(symbol, pointSize: p * 0.40, color: .white) {
        let s = sym.size
        let r = NSRect(x: (p - s.width)/2, y: (p - s.height)/2, width: s.width, height: s.height)
        sym.draw(in: r)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

struct IconSpec { let dir: String; let symbol: String; let top: NSColor; let bottom: NSColor }

let specs = [
    IconSpec(dir: "AppIcon.iconset", symbol: "laptopcomputer.slash",
             top: NSColor(srgbRed: 0.40, green: 0.45, blue: 0.98, alpha: 1),
             bottom: NSColor(srgbRed: 0.16, green: 0.14, blue: 0.45, alpha: 1)),
    IconSpec(dir: "RestoreIcon.iconset", symbol: "laptopcomputer",
             top: NSColor(srgbRed: 0.26, green: 0.84, blue: 0.40, alpha: 1),
             bottom: NSColor(srgbRed: 0.06, green: 0.46, blue: 0.20, alpha: 1)),
]

let root = (CommandLine.arguments.count > 1) ? CommandLine.arguments[1]
                                             : FileManager.default.currentDirectoryPath
for spec in specs {
    let dir = "\(root)/\(spec.dir)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, px) in sizes {
        if let data = drawIcon(pixel: px, symbol: spec.symbol, top: spec.top, bottom: spec.bottom) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
    }
    print("generated \(dir)")
}
