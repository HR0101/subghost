//
//  SubghostUITestsLaunchTests.swift
//  SubghostUITests
//
//  Created by hara ryuto   on 2026/07/16.
//
//  起動直後の画面をスクリーンショットとして残すUIテスト。
//
//  注意: testLaunchPerformance は起動時間を計測するため、コードが同じでも
//  失敗することがある。落ちても即座に不具合と判断せず、まず再実行すること。
//

import XCTest

final class SubghostUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
