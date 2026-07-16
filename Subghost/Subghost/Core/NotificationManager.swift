//
//  NotificationManager.swift
//  Subghost
//
//  設計書 4.2: 完了通知（UserNotifications）
//

import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(session: SessionInfo, state: AIState, preview: [String]) {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }

        let content = UNMutableNotificationContent()
        switch state {
        case .completed:
            content.title = "\(session.profile.displayName) 応答完了"
        case .error:
            content.title = "\(session.profile.displayName) エラー"
        default:
            return
        }
        content.subtitle = session.tmuxName
        content.body = preview.joined(separator: "\n")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "subghost-\(session.tmuxName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // 通知クリックでGhosttyを最前面化 (設計書 4.2)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            GhosttyActivator.activate()
            completionHandler()
        }
    }

    // アプリ動作中でもバナー表示する
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
