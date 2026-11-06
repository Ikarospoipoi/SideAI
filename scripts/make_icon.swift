import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let p = CGFloat(pixels)
    NSColor(calibratedRed: 0.18, green: 0.31, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88),
      xRadius: p * 0.19, yRadius: p * 0.19
    ).fill()
    NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.91, alpha: 1).setStroke()
    let outline = NSBezierPath(
      roundedRect: NSRect(x: p * 0.25, y: p * 0.27, width: p * 0.52, height: p * 0.47),
      xRadius: p * 0.065, yRadius: p * 0.065)
    outline.lineWidth = p * 0.035
    outline.stroke()
    let divider = NSBezierPath()
    divider.move(to: NSPoint(x: p * 0.40, y: p * 0.28))
    divider.line(to: NSPoint(x: p * 0.40, y: p * 0.73))
    divider.lineWidth = p * 0.03
    divider.stroke()
    let dot = NSBezierPath(
      ovalIn: NSRect(x: p * 0.55, y: p * 0.49, width: p * 0.075, height: p * 0.075))
    NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.91, alpha: 1).setFill()
    dot.fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let suffix = scale == 2 ? "@2x" : ""
    try rep.representation(using: .png, properties: [:])!.write(
      to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
