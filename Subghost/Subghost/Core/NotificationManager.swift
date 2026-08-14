//
//  NotificationManager.swift
//  Subghost
//
//  設計書 4.2: 完了通知（UserNotifications）
//  完了・失敗通知の発行と、通知から対象ターミナルへ移動する処理を担当する。
//

import Foundation
@preconcurrency import UserNotifications

/// 通知を発行した時点のCLIプロセスを特定する情報。
/// ttyは再利用されるため、PIDも一致した場合だけ同じセッションとみなす。
nonisolated struct NotificationSessionReference: Sendable, Equatable, Hashable {
    static let ttyKey = "sessionTTY"
    static let pidKey = "sessionPID"

    let tty: String
    let pid: Int32

    init(tty: String, pid: Int32) {
        self.tty = tty
        self.pid = pid
    }

    init(session: SessionInfo) {
        self.init(tty: session.tty, pid: session.pid)
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let tty = userInfo[Self.ttyKey] as? String,
              let rawPID = userInfo[Self.pidKey] as? NSNumber
        else { return nil }
        self.init(tty: tty, pid: rawPID.int32Value)
    }

    var userInfo: [AnyHashable: Any] {
        [Self.ttyKey: tty, Self.pidKey: Int(pid)]
    }

    func matches(_ session: SessionInfo) -> Bool {
        session.tty == tty && session.pid == pid
    }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
    }

    /// 利用者がオンボーディングまたは設定画面で明示的に選んだときだけ許可を求める。
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Subghost: 通知の許可取得に失敗しました: \(error.localizedDescription)")
            }
            center.getNotificationSettings { settings in
                let allowed = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                Task { @MainActor in completion(allowed) }
            }
        }
    }

    // MARK: - 完了・エラー通知

    func notify(
        session: SessionInfo,
        state: AIState,
        preview: [String],
        prompt: String? = nil
    ) {
        guard let event = NotificationEvent.from(state: state),
              event == .completed || event == .error,
              AlertGate.allowsNotification(event, session: session)
        else { return }

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
        var bodyParts: [String] = []
        if let prompt, !prompt.isEmpty {
            bodyParts.append("送信内容\n\(AppearancePreferences.maskedPreview(prompt))")
        }
        let reply = AppearancePreferences.maskedPreview(preview).joined(separator: "\n")
        if !reply.isEmpty { bodyParts.append("返答\n\(reply)") }
        content.body = bodyParts.joined(separator: "\n\n")
        content.sound = Self.notificationSound
        content.userInfo = NotificationSessionReference(session: session).userInfo

        post(content: content, identifier: notificationIdentifier(prefix: "subghost", session: session))
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

    private func notificationIdentifier(prefix: String, session: SessionInfo) -> String {
        "\(prefix)-\(session.pid)-\(session.tty)"
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
        let userInfo = response.notification.request.content.userInfo

        // userInfoはSendableでないため、Taskへ渡す前に必要な値だけ取り出す
        let sessionReference = NotificationSessionReference(userInfo: userInfo)
        Task { @MainActor in
            // 旧版の回答ボタンを含め、通知操作は対象ターミナルを開くだけにする。
            // SubghostからCLIへ文字列や選択肢を送信しない。
            Self.jumpFromNotification(to: sessionReference)
            completionHandler()
        }
    }

    @MainActor
    private static func jumpFromNotification(to reference: NotificationSessionReference?) {
        guard let reference,
              let session = AppCoordinator.shared.watcher.sessions.first(where: {
                  reference.matches($0.info)
              })
        else {
            // 終了済みのセッションや旧形式の通知では、誤ったタブへ移動しない。
            TerminalActivator.activate()
            return
        }
        AppCoordinator.shared.jump(to: session)
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
