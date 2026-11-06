import AppKit
import XCTest
import SideAICore
@testable import SideAI

final class InteractionTests: XCTestCase {
  @MainActor func testReturnSendsAndShiftReturnInsertsNewline() throws {
    let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    var sends = 0
    editor.send = { sends += 1 }
    editor.string = "第一行"
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    func key(_ code: UInt16 = 36, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
    }
    editor.keyDown(with: try key())
    XCTAssertEqual(sends, 1)
    XCTAssertEqual(editor.string, "第一行")
    editor.keyDown(with: try key(36, .shift))
    XCTAssertEqual(sends, 1)
    XCTAssertEqual(editor.string, "第一行\n")
    editor.keyDown(with: try key(76))
    XCTAssertEqual(sends, 2)
    editor.keyDown(with: try key(36, .command))
    XCTAssertEqual(sends, 3)
    editor.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    editor.keyDown(with: try key())
    XCTAssertEqual(sends, 3, "Return while composing must not send a message")
  }
  func testPlacementPreservesDraggedPositionAndRecoversFromDisconnectedDisplay() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let second = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let position = CGPoint(x: -1000, y: 50)
    let moved = PanelPlacement.frame(origin: position, width: 460, fallback: main, screens: [main, second])
    XCTAssertEqual(moved.origin, position)
    let resized = PanelPlacement.frame(origin: position, width: 600, fallback: main, screens: [main, second])
    XCTAssertEqual(resized.origin, position)
    let recovered = PanelPlacement.frame(origin: position, width: 600, fallback: main, screens: [main])
    XCTAssertTrue(main.contains(recovered))
    let bottomRight = PanelPlacement.frame(origin: CGPoint(x: 1400, y: 880), width: 740, fallback: main, screens: [main])
    XCTAssertTrue(main.contains(bottomRight))
  }
  func testHalfOffScreenPlacementPersistsOnEveryEdgeAndAcrossScreens() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    for point in [CGPoint(x: -230, y: 40), CGPoint(x: 1210, y: 40), CGPoint(x: 300, y: -410), CGPoint(x: 300, y: 490)] {
      let frame = PanelPlacement.frame(origin: point, width: 460, fallback: main, screens: [main])
      XCTAssertEqual(frame.origin, point)
      XCTAssertEqual(PanelPlacement.frame(origin: frame.origin, width: 460, fallback: main, screens: [main]), frame)
    }
    let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let spanning = CGPoint(x: -230, y: 40)
    XCTAssertEqual(PanelPlacement.frame(origin: spanning, width: 460, fallback: main, screens: [left, main]).origin, spanning)
    XCTAssertTrue(main.contains(PanelPlacement.frame(origin: CGPoint(x: -4000, y: -4000), width: 460, fallback: main, screens: [main])))
  }
  func testOldSettingsDecodeAndDraggedOriginPersists() throws {
    var settings = AppSettings()
    let old = try JSONEncoder().encode(settings)
    XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: old).panelOriginX)
    settings.panelOriginX = 345; settings.panelOriginY = 52
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.panelOriginX, 345)
    XCTAssertEqual(restored.panelOriginY, 52)
  }
}
