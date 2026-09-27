// Renders the 1024px app icon: two stacked cards, monochrome.
//   swift scripts/make-icon.swift Eidetic/Assets.xcassets/AppIcon.appiconset/icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func gray(_ v: CGFloat) -> CGColor { CGColor(colorSpace: space, components: [v, v, v, 1])! }

ctx.setFillColor(gray(0.07))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

func card(rotation: CGFloat, offset: CGPoint, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: size / 2 + offset.x, y: size / 2 + offset.y)
    ctx.rotate(by: rotation * .pi / 180)
    let rect = CGRect(x: -250, y: -170, width: 500, height: 340)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

card(rotation: 9, offset: CGPoint(x: 28, y: 56), color: gray(0.28))
card(rotation: -3, offset: CGPoint(x: -12, y: -28), color: gray(0.96))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
