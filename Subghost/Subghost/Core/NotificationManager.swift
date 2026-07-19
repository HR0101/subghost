//
//  NotificationManager.swift
//  Subghost
//
//  設計書 4.2: 完了通知（UserNotifications）
//  設計書 追補: 承認リクエスト／質問の通知（バナーからも承認・拒否できる）
//

import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// 承認/質問通知に付けるカテゴリと、そのアクション識別子
    private nonisolated enum Category {
        static let choice = "SUBGHOST_CHOICE"
        static let approve = "SUBGHOST_APPROVE"
        static let deny = "SUBGHOST_DENY"
    }

    /// 通知のuserInfoに載せるキー
    private nonisolated enum UserInfoKey {
        static let session = "session"
        static let approveKey = "approveKey"
        static let approveNeedsEnter = "approveNeedsEnter"
        static let denyKey = "denyKey"
        static let denyNeedsEnter = "denyNeedsEnter"
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Subghost: 通知の許可取得に失敗しました: \(error.localizedDescription)")
            }
        }
        registerCategories(on: center)
    }

    /// 通知バナー上の「承認 / 拒否」ボタンを登録する
    private func registerCategories(on center: UNUserNotificationCenter) {
        let approve = UNNotificationAction(identifier: Category.approve, title: "承認", options: [])
        let deny = UNNotificationAction(identifier: Category.deny, title: "拒否", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Category.choice,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    // MARK: - 完了・エラー通知

    func notify(session: SessionInfo, state: AIState, preview: [String]) {
        guard Self.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        switch state {
        case .completed:
            content.title = "\(session.profile.displayName) 応答完了"
        case .error:
            content.title = "\(session.profile.displayName) エラー"
        default:
            return
        }
        content.subtitle = session.displayName
        content.body = preview.joined(separator: "\n")
        content.sound = Self.notificationSound

        post(content: content, identifier: "subghost-\(session.tty)")
    }

    // MARK: - 承認リクエスト／質問の通知 (Approve / Ask)

    func notifyChoice(session: SessionInfo, choice: PendingChoice) {
        guard Self.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(session.profile.displayName) \(choice.kind.displayName)"
        content.subtitle = session.displayName
        content.body = choice.title
        content.sound = Self.notificationSound
        // 回答しないと処理が止まるため、集中モード中でも届くようにする
        content.interruptionLevel = .timeSensitive

        var userInfo: [String: Any] = [UserInfoKey.session: session.tty]
        // はい／いいえが揃っているときだけバナーにボタンを出す
        if let affirmative = choice.affirmativeOption, let negative = choice.negativeOption {
            content.categoryIdentifier = Category.choice
            userInfo[UserInfoKey.approveKey] = affirmative.keystroke
            userInfo[UserInfoKey.approveNeedsEnter] = affirmative.needsEnter
            userInfo[UserInfoKey.denyKey] = negative.keystroke
            userInfo[UserInfoKey.denyNeedsEnter] = negative.needsEnter
        }
        content.userInfo = userInfo

        post(content: content, identifier: "subghost-choice-\(session.tty)")
    }

    // MARK: - 共通

    private func post(content: UNNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Subghost: 通知の送信に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// 独自のアラート音が有効なときは、通知音と二重に鳴らさない
    private static var notificationSound: UNNotificationSound? {
        SoundAlerts.isEnabled ? nil : .default
    }

    // MARK: - 通知への応答

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // userInfoはSendableでないため、Taskへ渡す前に必要な値だけ取り出す
        let sessionName = userInfo[UserInfoKey.session] as? String
        let keyField = actionIdentifier == Category.approve
            ? UserInfoKey.approveKey : UserInfoKey.denyKey
        let enterField = actionIdentifier == Category.approve
            ? UserInfoKey.approveNeedsEnter : UserInfoKey.denyNeedsEnter
        let keystroke = userInfo[keyField] as? String
        let needsEnter = userInfo[enterField] as? Bool ?? false

        Task { @MainActor in
            switch actionIdentifier {
            case Category.approve, Category.deny:
                Self.respondFromNotification(
                    sessionName: sessionName,
                    keystroke: keystroke,
                    needsEnter: needsEnter,
                    label: actionIdentifier == Category.approve ? "承認" : "拒否"
                )
            default:
                // 本体タップ：ターミナルへ移動する (設計書 4.2)
                TerminalActivator.activate()
            }
            completionHandler()
        }
    }

    /// 通知アクションから選択肢へ回答する
    @MainActor
    private static func respondFromNotification(
        sessionName: String?,
        keystroke: String?,
        needsEnter: Bool,
        label: String
    ) {
        guard let sessionName, let keystroke else {
            NSLog("Subghost: 通知アクションに必要な情報が欠けています")
            return
        }

        let watcher = AppCoordinator.shared.watcher
        guard let session = watcher.sessions.first(where: { $0.info.tty == sessionName }) else {
            NSLog("Subghost: 通知の対象セッション \(sessionName) が見つかりません")
            return
        }
        let option = ChoiceOption(number: 0, label: label, keystroke: keystroke, needsEnter: needsEnter)

        Task {
            do {
                try await watcher.respond(with: option, in: session)
            } catch {
                NSLog("Subghost: 通知からの回答送信に失敗しました: \(error.localizedDescription)")
            }
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
