//
//  NotificationManager.swift
//  Subghost
//
//  設計書 4.2: 完了通知（UserNotifications）
//  設計書 追補: 承認リクエスト／質問の通知（バナーからも承認・拒否できる）
//
//  通知の発行と、バナー上で押されたボタンの受け取りを担当する。
//
//  バナーの応答は「通知を出した時点のセッション」へ返さなければならない。
//  ttyは使い回されるため、NotificationSessionReference で tty と PID の両方を
//  照合し、入れ替わった別プロセスへ誤って承認を送らないようにしている。
//

import Foundation
import UserNotifications

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

/// 同じTTYへ届いた古い承認通知を確実に失効させる、一度限りのトークン管理。
nonisolated struct ChoiceNotificationRegistry {
    private var tokens: [NotificationSessionReference: String] = [:]

    mutating func issue(
        for reference: NotificationSessionReference,
        token: String = UUID().uuidString
    ) -> String {
        tokens[reference] = token
        return token
    }

    func isCurrent(_ token: String, for reference: NotificationSessionReference) -> Bool {
        tokens[reference] == token
    }

    mutating func consume(_ token: String, for reference: NotificationSessionReference) -> Bool {
        guard isCurrent(token, for: reference) else { return false }
        tokens[reference] = nil
        return true
    }

    mutating func restore(_ token: String, for reference: NotificationSessionReference) {
        guard tokens[reference] == nil else { return }
        tokens[reference] = token
    }

    mutating func invalidate(_ reference: NotificationSessionReference) {
        tokens[reference] = nil
    }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// 承認/質問通知に付けるカテゴリと、そのアクション識別子。
    ///
    /// 通知バナーのアクションボタンは、選択肢の文言（問いごとに変わる）を
    /// そのままタイトルにする。UNNotificationCategory は識別子ごとに事前登録が
    /// 必要なため、「選択肢数」を識別子にしたカテゴリを問いが来るたびに
    /// 動的に作り直す（registerChoiceCategory 参照）。
    private nonisolated enum Category {
        static func choice(optionCount: Int) -> String { "SUBGHOST_CHOICE_\(optionCount)" }
        static func option(at index: Int) -> String { "SUBGHOST_OPTION_\(index)" }
        /// 通知バナーに出すボタンの最大数。増やすとバナーが煩雑になるため絞る。
        static let maxButtonCount = 4

        /// アクション識別子から選択肢のインデックスを取り出す（本体タップとの判別用）
        static func optionIndex(from actionIdentifier: String) -> Int? {
            let prefix = "SUBGHOST_OPTION_"
            guard actionIdentifier.hasPrefix(prefix) else { return nil }
            return Int(actionIdentifier.dropFirst(prefix.count))
        }
    }

    /// 通知のuserInfoに載せるキー
    private nonisolated enum UserInfoKey {
        static let choiceToken = "choiceToken"
    }

    private var choiceRegistry = ChoiceNotificationRegistry()

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Subghost: 通知の許可取得に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    /// この問いの選択肢ラベルでボタンを組み立て、動的にカテゴリを登録してから完了を通知する。
    ///
    /// 選択肢数ごとの識別子を使い回し、都度そのタイトルを最新の内容へ差し替える
    /// （事前に無限の組み合わせを登録することはできないため）。登録が完了する前に
    /// 通知を出すとボタンが出ないことがあるため、完了ハンドラで直列化する。
    private func registerChoiceCategory(for options: [ChoiceOption], completion: @escaping (String) -> Void) {
        let identifier = Category.choice(optionCount: options.count)
        let actions = options.enumerated().map { index, option in
            UNNotificationAction(
                identifier: Category.option(at: index),
                title: option.label,
                options: option.isNegative ? [.destructive] : []
            )
        }
        let category = UNNotificationCategory(
            identifier: identifier, actions: actions, intentIdentifiers: [], options: []
        )
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var updated = existing.filter { $0.identifier != identifier }
            updated.insert(category)
            center.setNotificationCategories(updated)
            DispatchQueue.main.async { completion(identifier) }
        }
    }

    // MARK: - 完了・エラー通知

    func notify(session: SessionInfo, state: AIState, preview: [String]) {
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
        content.body = AppearancePreferences.maskedPreview(preview).joined(separator: "\n")
        content.sound = Self.notificationSound
        content.userInfo = NotificationSessionReference(session: session).userInfo

        post(content: content, identifier: notificationIdentifier(prefix: "subghost", session: session))
    }

    // MARK: - 承認リクエスト／質問の通知 (Approve / Ask)

    func notifyChoice(session: SessionInfo, choice: PendingChoice) {
        let event: NotificationEvent = choice.kind == .approval ? .approval : .question
        guard AlertGate.allowsNotification(event, session: session) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(session.profile.displayName) \(choice.kind.displayName)"
        content.subtitle = session.displayName
        content.body = AppearancePreferences.maskedPreview(choice.title)
        content.sound = Self.notificationSound
        // 回答しないと処理が止まるため、既定では集中モード中でも届かせる。
        // 集中モードを尊重したい人は設定で通常の割り込みへ落とせる。
        if NotificationPreferences.timeSensitiveEnabled {
            content.interruptionLevel = .timeSensitive
        }

        let reference = NotificationSessionReference(session: session)
        let choiceToken = choiceRegistry.issue(for: reference)
        var userInfo = reference.userInfo
        userInfo[UserInfoKey.choiceToken] = choiceToken
        content.userInfo = userInfo

        let identifier = notificationIdentifier(prefix: "subghost-choice", session: session)

        // 複数選択は「チェックを入れてからSubmit」という操作を通知のボタンでは
        // 表現できない（1つ選ぶと即座に確定してしまう）ため、ボタンは出さず
        // 本体タップでの操作に委ねる。単一選択はボタン数の実用上の上限内であれば
        // その場で回答できるようにする。
        guard !choice.isMultiSelect, (2...Category.maxButtonCount).contains(choice.options.count) else {
            post(content: content, identifier: identifier)
            return
        }
        registerChoiceCategory(for: choice.options) { [weak self] categoryIdentifier in
            content.categoryIdentifier = categoryIdentifier
            self?.post(content: content, identifier: identifier)
        }
    }

    /// 回答済み・完了などで不要になった承認通知を失効させる。
    func invalidateChoice(for session: SessionInfo) {
        choiceRegistry.invalidate(NotificationSessionReference(session: session))
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [notificationIdentifier(prefix: "subghost-choice", session: session)]
        )
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
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // userInfoはSendableでないため、Taskへ渡す前に必要な値だけ取り出す
        let sessionReference = NotificationSessionReference(userInfo: userInfo)
        let choiceToken = userInfo[UserInfoKey.choiceToken] as? String
        let optionIndex = Category.optionIndex(from: actionIdentifier)

        Task { @MainActor in
            if let optionIndex {
                Self.respondFromNotification(
                    sessionReference: sessionReference,
                    choiceToken: choiceToken,
                    optionIndex: optionIndex
                )
            } else {
                // 本体タップ：通知を発行したセッションのタブへ移動する (設計書 4.2)
                Self.jumpFromNotification(to: sessionReference)
            }
            completionHandler()
        }
    }

    /// 通知アクションから選択肢へ回答する
    @MainActor
    private static func respondFromNotification(
        sessionReference: NotificationSessionReference?,
        choiceToken: String?,
        optionIndex: Int
    ) {
        guard let sessionReference, let choiceToken else {
            NSLog("Subghost: 通知アクションに必要な情報が欠けています")
            return
        }

        let watcher = AppCoordinator.shared.watcher
        guard let session = watcher.sessions.first(where: { sessionReference.matches($0.info) }) else {
            NSLog("Subghost: 通知の対象セッション \(sessionReference.tty) が見つかりません")
            return
        }
        guard shared.choiceRegistry.isCurrent(choiceToken, for: sessionReference),
              let choice = session.pendingChoice
        else {
            NSLog("Subghost: 古い、または解決済みの通知アクションを無視しました")
            return
        }
        guard choice.options.indices.contains(optionIndex) else {
            NSLog("Subghost: 通知のボタンに対応する選択肢がありません")
            return
        }
        let option = choice.options[optionIndex]
        guard shared.choiceRegistry.consume(choiceToken, for: sessionReference) else { return }

        Task { @MainActor in
            do {
                try await watcher.respond(with: option, in: session)
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [shared.notificationIdentifier(
                        prefix: "subghost-choice",
                        session: session.info
                    )]
                )
            } catch {
                // 送信失敗時は、同じ質問がまだ待機中なら再試行できるように戻す。
                if session.pendingChoice == choice {
                    shared.choiceRegistry.restore(choiceToken, for: sessionReference)
                }
                NSLog("Subghost: 通知からの回答送信に失敗しました: \(error.localizedDescription)")
            }
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
