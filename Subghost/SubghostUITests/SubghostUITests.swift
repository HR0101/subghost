//
//  SubghostUITests.swift
//  SubghostUITests
//
//  Created by hara ryuto   on 2026/07/16.
//
//  アプリを実際に起動して操作するUIテスト（XCTest）。
//  ロジックの検証は SubghostTests（Swift Testing）側で行うため、
//  ここは起動できること・画面が出ることの確認に絞る。
//

import XCTest

final class SubghostUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test初回案内を表示できる() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let title = app.staticTexts["onboarding.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "初回案内が表示されませんでした")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            app.launch()
        }
    }
}
