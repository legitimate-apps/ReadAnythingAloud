// Renders the app icon: muted salmon gradient, three lines of "text", one highlighted word, sound waves.
// Usage: swift Scripts/make-icon.swift <output-dir>
import AppKit
import CoreGraphics

let out = CommandLine.arguments.dropFirst().first ?? "."

func render(size: CGFloat, mac: Bool) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size / 1024
    var canvas = CGRect(x: 0, y: 0, width: size, height: size)
    if mac {
        // macOS icon grid: 824pt rounded square centered, with a soft drop shadow.
        canvas = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = CGPath(roundedRect: canvas, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.87, green: 0.58, blue: 0.52, alpha: 1),
        CGColor(red: 0.71, green: 0.40, blue: 0.35, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: canvas.minX, y: canvas.maxY), end: CGPoint(x: canvas.maxX, y: canvas.minY), options: [])

    let u = canvas.width / 1024
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
        let r = CGRect(x: canvas.minX + x * u, y: canvas.minY + y * u, width: w * u, height: h * u)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: h * u / 2, cornerHeight: h * u / 2, transform: nil))
        ctx.setFillColor(color); ctx.fillPath()
    }
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 0.96)
    let dim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
    // Text lines (y from bottom).
    bar(170, 640, 430, 64, dim)
    // Middle line: word, highlighted word pill, word.
    bar(170, 480, 150, 64, white)
    let pill = CGRect(x: canvas.minX + 340 * u, y: canvas.minY + 462 * u, width: 250 * u, height: 100 * u)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 34 * u, cornerHeight: 34 * u, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.92, alpha: 1)); ctx.fillPath()
    bar(372, 480, 186, 64, CGColor(red: 0.70, green: 0.38, blue: 0.33, alpha: 1))
    
    bar(170, 320, 330, 64, dim)
    // Sound waves on the right.
    ctx.setStrokeColor(white)
    ctx.setLineCap(.round)
    let center = CGPoint(x: canvas.minX + 700 * u, y: canvas.minY + 512 * u)
    for (i, radius) in [80.0, 140.0, 200.0].enumerated() {
        ctx.setLineWidth(36 * u)
        ctx.setAlpha(1 - CGFloat(i) * 0.25)
        ctx.addArc(center: center, radius: CGFloat(radius) * u, startAngle: -.pi / 4.5, endAngle: .pi / 4.5, clockwise: false)
        ctx.strokePath()
    }
    ctx.setAlpha(1)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
try! render(size: 1024, mac: false).write(to: URL(fileURLWithPath: "\(out)/icon-ios-1024.png"))
var images: [[String: String]] = [["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon-mac-\(base)@\(scale)x.png"
        try! render(size: CGFloat(px), mac: true).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
print("wrote \(images.count) icons")
