import XCTest

final class SmokeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testImportGroupAndDownloadPreferenceSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["addSubscription"].waitForExistence(timeout: 20))
        app.buttons["addSubscription"].tap()
        let name = app.textFields["subscriptionName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("My subscription")
        app.buttons["粘贴配置"].tap()
        let editor = app.textViews["subscriptionContent"]
        editor.tap()
        editor.typeText("proxies:\n  - {name: Tokyo 01, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: demo}\n  - {name: Singapore 02, type: trojan, server: example.org, port: 443, password: demo}\n")
        app.buttons["importSubscription"].tap()
        XCTAssertTrue(app.staticTexts["Tokyo 01"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(app.staticTexts["Singapore 02"].exists)
        let download = app.switches["downloadToggle"]
        XCTAssertTrue(download.exists)
        XCTAssertEqual(download.value as? String, "0")
        download.tap()
        XCTAssertEqual(download.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "NodeScope-node-list"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Tokyo 01"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches["downloadToggle"].value as? String, "1")
        app.switches["downloadToggle"].tap()
    }
}
