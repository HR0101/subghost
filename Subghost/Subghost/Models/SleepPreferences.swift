//
//  SleepPreferences.swift
//  Subghost
//
//  追補: 指定したCLIのタスクが終わったらMacをスリープさせる
//
//  「どのCLIを対象にするか」「今スリープへ進んでよいか」の判断をまとめた場所。
//
//  スリープは取り消せないうえ、ユーザーが席を外している前提で起きる。
//  誤って寝かせたときの代償が大きいため、判断はI/Oを持たない純粋ロジックとして
//  ここへ隔離し、固定値で単体テストできるようにしてある。
//  実際に寝かせる副作用は SystemSleeper、待ち時間の管理は SleepScheduler が持つ。
//

import Foundation

// MARK: - スリープ予約の対象

/// 「何が終わったら寝るか」の指定。
nonisolated enum SleepTarget: Hashable, Sendable {
    /// CLIの種類ごと（"claude" | "codex" | "antigravity"）。
    /// そのCLIのセッションがすべて手離れした時点で発火する。
    case agent(profileID: String)
    /// セッション1本ごと。ttyは使い回されるため、PIDと組で識別する。
    case session(tty: String, pid: Int32)
}

// MARK: - 判断に使うセッションの写し

/// 判断の入力にする、その時点のセッションの値。
///
/// MonitoredSession は状態を持ち続ける参照型で、判断のあいだにも変化しうる。
/// 純粋ロジック側へは値の写しだけを渡し、テストでも組み立てられるようにする。
nonisolated struct SleepSessionSnapshot: Hashable, Sendable {
    let tty: String
    let pid: Int32
    let profileID: String
    let state: AIState

    init(tty: String, pid: Int32, profileID: String, state: AIState) {
        self.tty = tty
        self.pid = pid
        self.profileID = profileID
        self.state = state
    }

    init(info: SessionInfo, state: AIState) {
        self.init(tty: info.tty, pid: info.pid, profileID: info.profile.id, state: state)
    }
}

// MARK: - 待ち時間を進めてよいか

/// スリープへ進めない理由。進めてよい場合は `.none`。
///
/// 単なる真偽値にせず理由まで返すのは、ノッチに「なぜ寝ないのか」を出すため。
/// 予約したのに寝ないという状況で、理由が分からないのが一番困る。
nonisolated enum SleepHold: Hashable, Sendable {
    /// 進めてよい
    case none
    /// 対象のセッションが見当たらない（CLIが終了した等）
    case targetMissing
    /// 対象がまだ作業中
    case targetBusy
    /// 承認・質問の回答を待っているセッションがある
    case awaitingResponse

    var isHolding: Bool { self != .none }

    /// 待たせている理由の説明（ノッチと読み上げに使う）
    var message: String? {
        switch self {
        case .none: return nil
        case .targetMissing: return "対象のセッションが見つかりません"
        case .targetBusy: return "対象がまだ作業中のため待っています"
        case .awaitingResponse: return "回答待ちのセッションがあるため待っています"
        }
    }
}

// MARK: - 発火条件の判断 (純粋ロジック)

nonisolated enum SleepCondition {

    /// このセッションが予約の対象に含まれるか
    static func covers(_ target: SleepTarget, _ snapshot: SleepSessionSnapshot) -> Bool {
        switch target {
        case .agent(let profileID):
            return snapshot.profileID == profileID
        case .session(let tty, let pid):
            return snapshot.tty == tty && snapshot.pid == pid
        }
    }

    /// 「タスクが終わった」とみなす状態か。
    /// エラーを終了に含めるかは設定で選べる（含めないと、失敗して止まったまま
    /// 永久に寝ないことになる。含めると失敗に気づかないまま寝る）。
    static func isFinished(_ state: AIState, includesError: Bool) -> Bool {
        switch state {
        case .completed: return true
        case .error: return includesError
        case .idle, .thinking, .awaitingApproval, .awaitingAnswer: return false
        }
    }

    /// 完了イベントを受け取ったとき、スリープまでの待ち時間へ入ってよいか。
    ///
    /// 予約は複数持てる。**そのすべてが終わるまで待つ**ので、1つ終わっただけでは
    /// 進まない（最後の1つが終わった時点で待ち時間に入る）。
    ///
    /// 待ち時間へ入るのは「対象が終わった」ときだけで、`idle` のセッションを
    /// 見ただけでは始めない。予約した瞬間に何も動いていないと、
    /// 何ひとつ待たずに寝てしまうため。
    static func shouldStartCountdown(
        targets: [SleepTarget],
        finished: SleepSessionSnapshot,
        sessions: [SleepSessionSnapshot],
        includesError: Bool
    ) -> Bool {
        guard targets.contains(where: { covers($0, finished) }) else { return false }
        guard isFinished(finished.state, includesError: includesError) else { return false }
        return hold(targets: targets, sessions: sessions) == .none
    }

    /// 予約のうち、対象のセッションが今も動いているものだけを返す。
    ///
    /// 途中で終了したCLIは待つ相手がいない。これを除かずに数えると、
    /// 消えた1つのせいで残りが終わっても永久に寝られなくなる。
    static func liveTargets(
        _ targets: [SleepTarget],
        sessions: [SleepSessionSnapshot]
    ) -> [SleepTarget] {
        targets.filter { target in sessions.contains { covers(target, $0) } }
    }

    /// 待ち時間を進めてよいか。進めない場合はその理由を返す。
    ///
    /// 予約が複数あるときは、生きている対象が**すべて**手離れして初めて進む。
    /// 回答待ちだけは対象かどうかに関わらず止める。答えるまでCLIは停止したままで、
    /// そのまま寝るとユーザーは「終わったはずなのに何も進んでいない」状態で戻ってくる。
    static func hold(targets: [SleepTarget], sessions: [SleepSessionSnapshot]) -> SleepHold {
        let live = liveTargets(targets, sessions: sessions)
        guard !live.isEmpty else { return .targetMissing }
        if sessions.contains(where: { $0.state.needsUserResponse }) { return .awaitingResponse }
        let matched = sessions.filter { session in live.contains { covers($0, session) } }
        if matched.contains(where: { $0.state == .thinking }) { return .targetBusy }
        return .none
    }
}

// MARK: - 設定値

nonisolated enum SleepPreferences {
    static let countdownKey = "sleepCountdownSeconds"
    static let includesErrorKey = "sleepIncludesError"
    static let repeatsKey = "sleepRepeatsReservation"

    static let defaultCountdown: TimeInterval = 30
    /// 猶予に0を許さないのは、取り消す機会を必ず残すため。
    static let countdownRange: ClosedRange<TimeInterval> = 5...300

    /// スリープするまでの猶予（秒）
    static var countdown: TimeInterval {
        normalizedCountdown(NotchPreferences.number(forKey: countdownKey, default: defaultCountdown))
    }

    /// 保存値を安全な範囲へ補正する。
    /// 0秒を許すと、取り消す間もなく寝てしまう設定を作れてしまう。
    static func normalizedCountdown(_ value: TimeInterval) -> TimeInterval {
        min(max(value, countdownRange.lowerBound), countdownRange.upperBound)
    }

    /// エラーで終わった場合も「タスクが終わった」とみなすか
    static var includesError: Bool {
        NotchPreferences.bool(forKey: includesErrorKey, default: true)
    }

    /// 一度スリープした後も予約を残すか。既定では1回で解除する
    /// （復帰するたびに何度も寝てしまうのを避けるため）。
    static var repeats: Bool {
        NotchPreferences.bool(forKey: repeatsKey, default: false)
    }
}
