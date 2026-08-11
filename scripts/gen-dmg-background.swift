// One-shot generator for the dmg window background (assets/desktop/
// dmg-background.png). Draws the "drag into Applications" guidance with
// AppKit; run locally, commit the PNG — CI never regenerates it.
//
// Usage: swift scripts/gen-dmg-background.swift

import AppKit

let size = NSSize(width: 800, height: 500)
let image = NSImage(size: size)
image.lockFocus()

// Background
NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.92, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

func roundedBox(_ rect: NSRect, fill: NSColor, radius: CGFloat = 18) {
  let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  fill.setFill()
  path.fill()
}

// "App" placeholder tile (left side)
let appRect = NSRect(x: 200, y: 210, width: 120, height: 120)
roundedBox(appRect, fill: NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.25, alpha: 1))
// little "鲸" glyph inside the tile
let whale = "鲸" as NSString
let whaleAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 56, weight: .bold),
  .foregroundColor: NSColor.white,
]
let whaleSize = whale.size(withAttributes: whaleAttrs)
whale.draw(
  at: NSPoint(x: appRect.midX - whaleSize.width / 2, y: appRect.midY - whaleSize.height / 2 - 6),
  withAttributes: whaleAttrs)

// "Applications" folder placeholder tile (right side)
let folderRect = NSRect(x: 520, y: 210, width: 120, height: 120)
roundedBox(folderRect, fill: NSColor(calibratedRed: 0.45, green: 0.58, blue: 0.72, alpha: 1))
let folder = "文件" as NSString
let folderAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 44, weight: .bold),
  .foregroundColor: NSColor.white,
]
let folderSize = folder.size(withAttributes: folderAttrs)
folder.draw(
  at: NSPoint(x: folderRect.midX - folderSize.width / 2, y: folderRect.midY - folderSize.height / 2 - 6),
  withAttributes: folderAttrs)

// Arrow between the two tiles
let arrow = NSBezierPath()
arrow.lineWidth = 10
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 330, y: 270))
arrow.line(to: NSPoint(x: 500, y: 270))
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 500, y: 270))
head.line(to: NSPoint(x: 470, y: 245))
head.move(to: NSPoint(x: 500, y: 270))
head.line(to: NSPoint(x: 470, y: 295))
head.lineWidth = 10
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Title
let title = "将 蓝鲸助手 拖入 Applications 文件夹" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 30, weight: .bold),
  .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.32, blue: 0.15, alpha: 1),
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(
  at: NSPoint(x: (size.width - titleSize.width) / 2, y: 420),
  withAttributes: titleAttrs)

// Subtitle
let subtitle = "拖入后即可从启动台/应用程序中使用" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 15, weight: .regular),
  .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.4, blue: 0.3, alpha: 1),
]
let subSize = subtitle.size(withAttributes: subAttrs)
subtitle.draw(
  at: NSPoint(x: (size.width - subSize.width) / 2, y: 388),
  withAttributes: subAttrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  fputs("failed to render background\n", stderr)
  exit(1)
}

let out = URL(fileURLWithPath: "assets/desktop/dmg-background.png")
try! png.write(to: out)
print("wrote \(out.path)")
