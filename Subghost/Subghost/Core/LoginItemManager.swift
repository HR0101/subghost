//
//  LoginItemManager.swift
//  Subghost
//
//  macOS標準のログイン項目APIを使って、起動時の常駐を切り替える。
//

import ServiceManagement

@MainActor
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}
