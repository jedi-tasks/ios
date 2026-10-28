// Генерирует иконку приложения: swift Scripts/generate-app-icon.swift Tasks/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

enum Variant { case light, dark, tinted }

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Три строки задач: выполненная, текущая (с приоритетом) и заблокированная — бледная.
func render(_ v: Variant, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

    // Фон (иконки iOS без прозрачности)
    switch v {
    case .light: ctx.setFillColor(rgb(0x3D5AFE))
    case .dark: ctx.setFillColor(rgb(0x14161F))
    case .tinted: ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    }
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let card: CGColor = v == .light ? rgb(0xFFFFFF) : (v == .dark ? rgb(0x262A3A) : CGColor(gray: 1, alpha: 0.9))
    let line: CGColor = v == .light ? rgb(0xC9D0E8) : (v == .dark ? rgb(0x4A5070) : CGColor(gray: 0, alpha: 0.35))
    let done: CGColor = v == .tinted ? CGColor(gray: 0, alpha: 1) : rgb(0x30C26B)
    let accent: CGColor = v == .tinted ? CGColor(gray: 0, alpha: 0.8) : rgb(0xFF9F1C)

    // В CG ось Y вверх: первая строка — верхняя
    let rowHeight: CGFloat = 196, gap: CGFloat = 52, width: CGFloat = 704
    let x = (CGFloat(size) - width) / 2
    let top = (CGFloat(size) + rowHeight * 3 + gap * 2) / 2
    for index in 0..<3 {
        let rect = CGRect(x: x, y: top - rowHeight * CGFloat(index + 1) - gap * CGFloat(index), width: width, height: rowHeight)
        ctx.setAlpha(index == 2 ? 0.45 : 1)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 56, cornerHeight: 56, transform: nil))
        ctx.setFillColor(card)
        ctx.fillPath()

        // Кружок-чекбокс
        let circle = CGRect(x: rect.minX + 52, y: rect.midY - 46, width: 92, height: 92)
        if index == 0 {
            ctx.setFillColor(done)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(card)
            ctx.setLineWidth(16)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: circle.minX + 24, y: circle.midY))
            ctx.addLine(to: CGPoint(x: circle.minX + 40, y: circle.midY - 18))
            ctx.addLine(to: CGPoint(x: circle.maxX - 20, y: circle.midY + 20))
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(index == 1 ? accent : line)
            ctx.setLineWidth(14)
            ctx.strokeEllipse(in: circle.insetBy(dx: 7, dy: 7))
        }

        // Полоска текста
        let barWidth: CGFloat = [380, 440, 300][index]
        let bar = CGRect(x: circle.maxX + 44, y: rect.midY - 18, width: barWidth, height: 36)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.setFillColor(line)
        ctx.fillPath()
    }
    ctx.setAlpha(1)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(.light, to: dir + "/AppIcon.png")
render(.dark, to: dir + "/AppIcon-dark.png")
render(.tinted, to: dir + "/AppIcon-tinted.png")
