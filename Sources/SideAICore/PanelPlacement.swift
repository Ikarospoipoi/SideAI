import Foundation
import CoreGraphics

public enum PanelPlacement {
  /// Preserve intentional partial off-screen placement. Recover only when the
  /// window is no longer reachable (for example, a monitor has been disconnected).
  public static func frame(origin: CGPoint?, width: Double, fallback: CGRect, screens: [CGRect]) -> CGRect {
    let validOrigin = origin.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
    let desiredWidth = width.isFinite ? width : 460
    let provisional = CGRect(origin: validOrigin ?? fallback.origin,
                             size: CGSize(width: min(max(desiredWidth, 360), 740), height: min(820, fallback.height - 24)))
    let visible = screens.max { a, b in
      area(a.intersection(provisional)) < area(b.intersection(provisional))
    }.flatMap { area($0.intersection(provisional)) > 0 ? $0 : nil } ?? fallback
    let size = CGSize(width: min(max(desiredWidth, 360), min(740, max(120, visible.width - 16))),
                      height: max(80, min(820, visible.height - 24)))
    let desired = CGRect(origin: validOrigin ?? CGPoint(x: visible.minX + 8, y: visible.midY - size.height / 2), size: size)
    if validOrigin != nil, screens.contains(where: {
      let overlap = $0.intersection(desired)
      return !overlap.isNull && overlap.width >= 48 && overlap.height >= 48
    }) { return desired }
    return CGRect(x: min(max(desired.minX, visible.minX + 8), visible.maxX - size.width - 8),
                  y: min(max(desired.minY, visible.minY + 8), visible.maxY - size.height - 8),
                  width: size.width, height: size.height)
  }
  private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
}
