import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// DryRun app icon.

let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

// Powder Blue is lifted straight from PaintCatalog, so the icon and the app's swatch row are
// literally the same colour.
let wallPaint = rgb(0xE7E0D2)      // the wall, unpainted
let paintedWall = rgb(0xA9C5D6)    // Powder Blue, what the phone sees
let floorPaint = rgb(0xFFFFFF)     // outside the wall
let couchBody = rgb(0x9A8974)
let couchCushion = rgb(0xB0A08A)
let phoneBody = rgb(0x2B2F35)
let bracket = CGColor(gray: 1, alpha: 0.92)

let floorY: CGFloat = 772

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The room behind everything: wall, then floor.
func drawRoom(_ ctx: CGContext) {
    ctx.setFillColor(wallPaint)
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: floorY))
    ctx.setFillColor(floorPaint)
    ctx.fill(CGRect(x: 0, y: floorY, width: S, height: S - floorY))
}


func drawCouch(_ ctx: CGContext) {

    ctx.setFillColor(couchBody)
    ctx.addPath(roundedRect(CGRect(x: 130, y: 664, width: 764, height: 420), 34))
    ctx.fillPath()

    ctx.setFillColor(couchCushion)
    ctx.addPath(roundedRect(CGRect(x: 186, y: 688, width: 652, height: 128), 24))
    ctx.fillPath()
}


func drawBrackets(_ ctx: CGContext, in r: CGRect) {
    let arm: CGFloat = 62
    let weight: CGFloat = 11
    ctx.setStrokeColor(bracket)
    ctx.setLineWidth(weight)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    for (cx, cy, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                             (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy + arm * CGFloat(dy)))
        path.addLine(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx + arm * CGFloat(dx), y: cy))
        ctx.addPath(path)
        ctx.strokePath()
    }
}

func render(to url: URL, pixels: CGFloat) {
    guard let ctx = CGContext(data: nil, width: Int(pixels), height: Int(pixels),
                              bitsPerComponent: 8, bytesPerRow: Int(pixels) * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              // No alpha channel: an App Store icon must be fully opaque, and
                              // every pixel is painted below.
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else {
        fatalError("could not create context")
    }
    ctx.translateBy(x: 0, y: pixels)
    ctx.scaleBy(x: 1, y: -1)
    // Everything below is authored against a 1024 canvas; this maps it to the requested size.
    ctx.scaleBy(x: pixels / S, y: pixels / S)
    ctx.setAllowsAntialiasing(true)

    drawRoom(ctx)
    drawCouch(ctx)

    // The phone runs off the bottom of the canvas on purpose: its lower corners are never drawn,
    // so it reads as held into frame instead of as an object floating in the room.
    let phone = CGRect(x: (S - 480) / 2, y: 115, width: 480, height: 822)
    let screen = phone.insetBy(dx: 30, dy: 30)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 42,
                  color: CGColor(gray: 0, alpha: 0.26))
    ctx.setFillColor(phoneBody)
    ctx.addPath(roundedRect(phone, 68))
    ctx.fillPath()
    ctx.restoreGState()

    // --- What the phone sees: the same room, with the wall repainted ---
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 44))
    ctx.clip()

    ctx.setFillColor(paintedWall)
    ctx.fill(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: floorY - screen.minY))
    ctx.setFillColor(floorPaint)
    ctx.fill(CGRect(x: screen.minX, y: floorY, width: screen.width, height: screen.maxY - floorY))

    drawCouch(ctx)
    drawBrackets(ctx, in: screen.insetBy(dx: 48, dy: 48))
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
    print("wrote \(url.lastPathComponent)")
}

render(to: URL(fileURLWithPath: CommandLine.arguments[1])
    .appending(path: "AppIcon-1024.png"), pixels: 1024)
