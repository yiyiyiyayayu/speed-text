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
        editor.typeText("proxies:\n  - {name: HK 03, type: ss, server: example.net, port: 443, cipher: aes-128-gcm, password: demo}\n  - {name: Tokyo 01, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: demo}\n  - {name: Singapore 02, type: trojan, server: example.org, port: 443, password: demo}\n")
        app.buttons["importSubscription"].tap()
        XCTAssertTrue(app.staticTexts["Tokyo 01"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        XCTAssertTrue(app.staticTexts["Singapore 02"].exists)
        XCTAssertTrue(app.staticTexts["HK 03"].exists)
        app.buttons["openExclusions"].tap()
        let hongkong = app.switches["excludeRegion_hk"]
        XCTAssertTrue(hongkong.waitForExistence(timeout: 5))
        hongkong.tap()
        XCTAssertEqual(hongkong.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.staticTexts["HK 03"].exists)
        let download = app.switches["downloadToggle"]
        XCTAssertTrue(download.exists)
        XCTAssertEqual(download.value as? String, "0")
        download.tap()
        XCTAssertEqual(download.value as? String, "1")
        app.tabBars.buttons["网络"].tap()
        app.buttons["addNetwork"].tap()
        let networkName = app.textFields["networkProfileName"]
        XCTAssertTrue(networkName.waitForExistence(timeout: 5))
        networkName.tap(); networkName.typeText("Home network")
        app.buttons["saveNetwork"].tap()
        XCTAssertTrue(app.staticTexts["Home network"].firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["测速"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "NodeScope-node-list"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Tokyo 01"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches["downloadToggle"].value as? String, "1")
        XCTAssertFalse(app.staticTexts["HK 03"].exists)
        XCTAssertTrue(app.staticTexts["Home network"].firstMatch.exists)
        app.buttons["openExclusions"].tap()
        XCTAssertEqual(app.switches["excludeRegion_hk"].value as? String, "1")
        app.switches["excludeRegion_hk"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["HK 03"].waitForExistence(timeout: 5))
        app.switches["downloadToggle"].tap()
    }
}
