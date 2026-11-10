import XCTest
final class SideAIUITests: XCTestCase {
  func testRemoteControlsAndApprovalDetails() {
    let app = XCUIApplication(); app.launchArguments = ["--ui-demo"]; app.launch()
    XCTAssertTrue(app.buttons["消息输入框"].exists || app.textFields["消息输入框"].exists || app.textViews["消息输入框"].exists)
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertTrue(app.buttons["停止任务"].exists)
    let main = XCTAttachment(screenshot: app.screenshot()); main.name = "Remote conversation"; main.lifetime = .keepAlways; add(main)
    app.buttons["Codex 请求修改文件"].tap()
    XCTAssertTrue(app.staticTexts["请求详情"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["允许此次操作"].exists)
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Remote approval"; attachment.lifetime = .keepAlways; add(attachment)
    app.buttons["关闭"].tap()
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "model-a")).firstMatch.tap()
    XCTAssertTrue(app.buttons["保存"].waitForExistence(timeout: 5))
  }
  func testFreshInstallCanOpenPairingWithoutKeychainError() {
    let app = XCUIApplication(); app.launch()
    XCTAssertTrue(app.buttons["连接我的电脑"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.alerts.firstMatch.exists)
    app.buttons["连接我的电脑"].tap()
    XCTAssertTrue(app.buttons["扫描电脑上的二维码"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["连接电脑"].exists)
    XCTAssertFalse(app.buttons["连接电脑"].isEnabled)
  }

}
