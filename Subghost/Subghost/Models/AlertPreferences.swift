//
//  AlertPreferences.swift
//  Subghost
//
//  「この知らせを今このセッションで出してよいか」の判断を一か所へ集約する。
//
//  従来は通知のオン/オフが単一のマスタースイッチしかなく、サウンド(AlertSound)だけが
//  イベント単位で設定できるという非対称があった。ここで通知側もイベント単位に揃え、
//  さらにエージェント単位・セッション単位のミュートと静穏時間を重ねられるようにする。
//
//  判断は AlertGate に集約し、AppCoordinator / SessionWatcher からはそこだけを見る。
//

import Foundation

// MARK: - 通知イベント

/// 通知を出しうるイベント。AlertSound と対になる粒度で持つ。
nonisolated enum NotificationEvent: String, CaseIterable, Sendable {
    case completed
    case error
    case approval
    case question

    var displayName: String {
        switch self {
        case .completed: return "応答完了"
        case .error: return "エラー"
        case .approval: return "承認リクエスト"
        case .question: return "質問"
        }
    }

    var detail: String {
        switch self {
        case .completed: return "AI がターンを完了したとき"
        case .error: return "ツールエラーまたは API エラーが起きたとき"
        case .approval: return "権限の承認を求められたとき（バナーから承認・拒否できます）"
        case .question: return "AI が質問を投げて入力を待っているとき"
        }
    }

    /// 回答しないとCLIの処理が止まるイベントか。
    /// 静穏時間の例外や、割り込みレベルの判断に使う。
    var isBlocking: Bool { self == .approval || self == .question }

    var enabledKey: String { "notification.\(rawValue).enabled" }

    var isEnabled: Bool {
        NotchPreferences.bool(forKey: enabledKey, default: true)
    }

    /// 状態遷移から対応する通知イベントを求める（該当しなければ nil）
    static func from(state: AIState) -> NotificationEvent? {
        switch state {
        case .completed: return .completed
        case .error: return .error
        case .awaitingApproval: return .approval
        case .awaitingAnswer: return .question
        case .idle, .thinking: return nil
        }
    }
}

// MARK: - 静穏時間

/// 指定した時間帯のあいだ、通知とサウンドを控える設定。
///
/// 開始・終了は「0時からの分数」で保持する。日付をまたぐ指定（22:00〜7:00）を
/// 素直に表現できるようにするため、時刻ではなく分数で持っている。
nonisolated enum QuietHours {
    static let enabledKey = "quietHoursEnabled"
    static let startKey = "quietHoursStartMinutes"
    static let endKey = "quietHoursEndMinutes"
    /// 承認・質問だけは静穏時間でも通す（既定で有効）。
    /// 答えないとCLIが止まったままになるため、こちらを既定にしている。
    static let allowBlockingKey = "quietHoursAllowBlocking"

    static let defaultStartMinutes = 22 * 60
    static let defaultEndMinutes = 7 * 60

    static var isEnabled: Bool {
        NotchPreferences.bool(forKey: enabledKey, default: false)
    }

    static var startMinutes: Int {
        Int(NotchPreferences.number(forKey: startKey, default: Double(defaultStartMinutes)))
    }

    static var endMinutes: Int {
        Int(NotchPreferences.number(forKey: endKey, default: Double(defaultEndMinutes)))
    }

    static var allowsBlockingEvents: Bool {
        NotchPreferences.bool(forKey: allowBlockingKey, default: true)
    }

    /// 現在が静穏時間内か
    static func isQuietNow(_ now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        return isQuiet(at: now, start: startMinutes, end: endMinutes, calendar: calendar)
    }

    /// 時間帯の判定本体。日付をまたぐ指定にも対応する。
    /// 開始と終了が同じ場合は「一日中」ではなく「静穏なし」として扱う
    /// （誤設定で全通知が消えるより、何も起きないほうが気づきやすい）。
    static func isQuiet(at date: Date, start: Int, end: Int, calendar: Calendar = .current) -> Bool {
        guard start != end else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return minutes >= start && minutes < end
        }
        // 22:00〜7:00 のように日付をまたぐ指定
        return minutes >= start || minutes < end
    }

    /// "22:00" の形に整形する
    static func text(forMinutes minutes: Int) -> String {
        let normalized = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }
}

// MARK: - エージェント単位のミュート

/// CLIの種類（Claude Code / Codex / Antigravity）ごとに知らせを止める設定。
/// 「Codexは常に眺めているので通知は要らない」といった使い分けのため。
nonisolated enum AgentMutePreferences {
    static func key(profileID: String) -> String { "agent.\(profileID).muted" }

    static func isMuted(profileID: String) -> Bool {
        NotchPreferences.bool(forKey: key(profileID: profileID), default: false)
    }

    static func setMuted(_ muted: Bool, profileID: String) {
        UserDefaults.standard.set(muted, forKey: key(profileID: profileID))
    }
}

// MARK: - セッション単位のミュート

/// 個別のセッション（1タブ）だけを一時的に黙らせるための保持箱。
///
/// あえて永続化していない。ttyは使い回されるため、保存すると別のセッションが
/// そのタブを引き継いだときに、身に覚えのないミュートを引きずってしまう。
@Observable
final class SessionMuteStore {
    private var mutedKeys: Set<String> = []

    /// ttyの再利用で取り違えないよう、PIDと組にして識別する
    nonisolated static func key(for info: SessionInfo) -> String {
        "\(info.pid):\(info.tty)"
    }

    func isMuted(_ info: SessionInfo) -> Bool {
        mutedKeys.contains(Self.key(for: info))
    }

    func setMuted(_ muted: Bool, for info: SessionInfo) {
        let key = Self.key(for: info)
        if muted {
            mutedKeys.insert(key)
        } else {
            mutedKeys.remove(key)
        }
    }

    func toggle(_ info: SessionInfo) {
        setMuted(!isMuted(info), for: info)
    }

    /// 終了したセッションぶんを捨てる（起動しっぱなしでも溜め込まないように）
    func prune(livingSessions: [SessionInfo]) {
        let living = Set(livingSessions.map(Self.key(for:)))
        mutedKeys.formIntersection(living)
    }

    var mutedCount: Int { mutedKeys.count }
}

// MARK: - 判断の集約

/// 通知・サウンド・自動展開を出してよいかを一括で判断する。
///
/// 呼び出し側（AppCoordinator / SessionWatcher）はここだけを見ればよく、
/// 設定項目が増えても分岐が各所へ散らばらない。
enum AlertGate {

    /// セッション個別のミュート状態。AppCoordinator が保持する実体を指す。
    static var sessionMutes: SessionMuteStore { AppCoordinator.shared.sessionMutes }

    /// 通知バナーを出してよいか
    static func allowsNotification(
        _ event: NotificationEvent,
        session: SessionInfo,
        now: Date = Date()
    ) -> Bool {
        guard NotificationPreferences.masterEnabled else { return false }
        guard event.isEnabled else { return false }
        guard !isSilenced(session: session) else { return false }
        return !isSuppressedByQuietHours(event, now: now)
    }

    /// アラート音を鳴らしてよいか。
    /// セッションに紐づかない音（アプリ起動・送信音）は session に nil を渡す。
    static func allowsSound(
        _ sound: AlertSound,
        session: SessionInfo?,
        now: Date = Date()
    ) -> Bool {
        guard SoundAlerts.isEnabled, sound.isEnabled else { return false }
        if let session, isSilenced(session: session) { return false }
        // 静穏時間では、答えないと止まるイベントの音だけ設定に応じて通す
        if QuietHours.isQuietNow(now) {
            guard let event = sound.notificationEvent else { return false }
            return event.isBlocking && QuietHours.allowsBlockingEvents
        }
        return true
    }

    /// ノッチを自動で展開してよいか。
    /// 静穏時間は画面を光らせないほうがよいので、通知と同じ基準で抑える。
    static func allowsAutoExpand(
        _ event: NotificationEvent,
        session: SessionInfo,
        now: Date = Date()
    ) -> Bool {
        guard !isSilenced(session: session) else { return false }
        return !isSuppressedByQuietHours(event, now: now)
    }

    /// エージェント単位・セッション単位のどちらかでミュートされているか
    private static func isSilenced(session: SessionInfo) -> Bool {
        if AgentMutePreferences.isMuted(profileID: session.profile.id) { return true }
        return sessionMutes.isMuted(session)
    }

    private static func isSuppressedByQuietHours(
        _ event: NotificationEvent,
        now: Date
    ) -> Bool {
        guard QuietHours.isQuietNow(now) else { return false }
        // 承認・質問は放置するとCLIが止まるため、設定で通すことを選べる
        return !(event.isBlocking && QuietHours.allowsBlockingEvents)
    }
}

// MARK: - 通知全体の設定

nonisolated enum NotificationPreferences {
    static let masterKey = "notificationsEnabled"
    /// 承認・質問の通知を集中モードでも割り込ませるか
    static let timeSensitiveKey = "notificationTimeSensitive"

    static var masterEnabled: Bool {
        NotchPreferences.bool(forKey: masterKey, default: true)
    }

    static var timeSensitiveEnabled: Bool {
        NotchPreferences.bool(forKey: timeSensitiveKey, default: true)
    }
}

// MARK: - サウンドとの対応

extension AlertSound {
    /// 対応する通知イベント（対になるものが無い音は nil）
    var notificationEvent: NotificationEvent? {
        switch self {
        case .completed: return .completed
        case .error: return .error
        case .approval: return .approval
        case .question: return .question
        case .appLaunched, .sessionStart, .promptSent, .contextLimit: return nil
        }
    }
}
