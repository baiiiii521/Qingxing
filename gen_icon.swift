//
//  gen_icon.swift — 生成 AppIcon.iconset（纯 CoreGraphics，无外部依赖）
//  由 build.sh 调用，产物经 iconutil 转为 icns
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func render(_ s: CGFloat) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: Int(s), height: Int(s),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // 背景：左下深蓝 → 右上青 渐变
    let colors = [
        CGColor(srgbRed: 0.13, green: 0.18, blue: 0.50, alpha: 1),
        CGColor(srgbRed: 0.06, green: 0.55, blue: 0.60, alpha: 1),
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])

    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ctx.setFillColor(white)
    ctx.setStrokeColor(white)

    // 杯身
    let body = CGRect(x: s * 0.30, y: s * 0.26, width: s * 0.32, height: s * 0.26)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil))
    ctx.fillPath()

    // 杯柄（右侧半圆弧）
    ctx.setLineWidth(s * 0.034)
    ctx.addArc(center: CGPoint(x: s * 0.62, y: s * 0.39), radius: s * 0.082,
               startAngle: -1.25, endAngle: 1.25, clockwise: false)
    ctx.strokePath()

    // 杯托
    let saucer = CGRect(x: s * 0.24, y: s * 0.145, width: s * 0.44, height: s * 0.065)
    ctx.addPath(CGPath(roundedRect: saucer, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
    ctx.fillPath()

    // 热气（两条曲线）
    ctx.setLineWidth(s * 0.026)
    ctx.setLineCap(.round)
    for dx in [0.0, 0.115] {
        let x = s * (0.385 + dx)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: s * 0.58))
        path.addCurve(
            to: CGPoint(x: x + s * 0.05, y: s * 0.70),
            control1: CGPoint(x: x - s * 0.05, y: s * 0.63),
            control2: CGPoint(x: x + s * 0.09, y: s * 0.66)
        )
        ctx.addPath(path)
        ctx.strokePath()
    }

    return ctx.makeImage()
}

let sizes: [String: Int] = [
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
]

let fm = FileManager.default
let dir = "build/AppIcon.iconset"
try? fm.removeItem(atPath: dir)
try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

for (name, px) in sizes {
    guard let image = render(CGFloat(px)) else {
        fatalError("render \(name) failed")
    }
    let url = URL(fileURLWithPath: "\(dir)/\(name)") as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("create destination \(name) failed")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
print("iconset 已生成：\(dir)")
