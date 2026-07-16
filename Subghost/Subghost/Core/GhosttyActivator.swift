//
//  GhosttyActivator.swift
//  Subghost
//
//  設計書 4.2: クリックでGhosttyを最前面化（NSWorkspaceでアクティベート）
//

import AppKit

enum GhosttyActivator {

    static let bundleID = "com.mitchellh.ghostty"

    static func activate() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            return
        }
        // 起動していなければ起動を試みる
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
