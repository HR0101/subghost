//
//  SleepScheduler.swift
//  Subghost
//
//  追補: 指定したCLIのタスクが終わったらMacをスリープさせる（予約と待ち時間の管理）
//
//  「寝てよいか」の判断そのものは SleepCondition（純粋ロジック）が持ち、
//  ここは予約の保持・待ち時間の消化・実行という副作用だけを受け持つ。
//
//  設計の要点は、待ち時間を「減らさない」条件を持たせたこと。
//  対象が動き出した／どこかで回答を待っている／ユーザーがノッチへ入力中、
//  のいずれかであればカウントを止めて理由を出し、予約は残したまま待ち続ける。
//  取り消すのではなく止めるのは、少し席へ戻っただけで予約が消えると
//  「終わったら寝る」という当初の意図まで失われてしまうため。
//
//  予約は複数持てる。複数ある場合は**そのすべてが終わるまで待つ**（最後の1つが
//  終わった時点で待ち時間へ入る）。途中でCLIが終了して対象が消えた予約は、
//  待つ相手がいないため判断から外す。そうしないと、消えた1つのせいで
//  残りが終わっても永久に寝られない。
//
//  予約はあえて永続化していない。「この作業が終わったら寝たい」は一時的な意図で、
//  保存すると忘れた頃に別の作業で勝手にスリープしてしまう。
//

import Foundation
import Observation

@Observable
final class SleepScheduler {

    /// 進行中の予約1件
    struct Reservation: Equatable, Identifiable {
        let target: SleepTarget
        /// 表示名（"Claude Code" / "subghost（ttys004）"）
        let label: String

        var id: SleepTarget { target }
    }

    /// スリープまでの待ち時間
    struct Countdown: Equatable {
        /// 対象の表示名を並べたもの（"Claude Code、Codex"）
        let label: String
        /// 待っていた予約の件数（「すべて終わりました」と出し分けるため）
        let targetCount: Int
        /// 残り秒数
        var remaining: TimeInterval
        /// 進めない理由（`.none` なら進行中）
        var hold: SleepHold
        /// ノッチへ入力中などでユーザーが操作していて止めているか
        var pausedByUser: Bool

        var isPaused: Bool { hold.isHolding || pausedByUser }

        /// なぜ止まっているのかの説明
        var holdMessage: String? {
            if pausedByUser { return "操作中のため待っています" }
            return hold.message
        }

        /// 「◯◯ のタスクが（すべて）終わりました」の主部
        var completionText: String {
            targetCount > 1
                ? "\(label) のタスクがすべて終わりました"
                : "\(label) のタスクが終わりました"
        }
    }

    /// 現在の予約。空なら何も狙っていない。
    private(set) var reservations: [Reservation] = []
    /// 待ち時間の消化中だけ値が入る
    private(set) var countdown: Countdown?
    /// 直近の結果（取り消しの理由・失敗の理由）。ノッチと設定画面に出す。
    private(set) var statusMessage: String?

    /// 現在のセッション一覧を取り出す（AppCoordinator が結線する）
    @ObservationIgnored var sessionsProvider: () -> [SleepSessionSnapshot] = { [] }
    /// ユーザーが今ノッチを操作中か（入力中は待ち時間を進めない）
    @ObservationIgnored var isUserInteracting: () -> Bool = { false }
    /// 待ち時間の開始・終了をUIへ知らせる
    @ObservationIgnored var onCountdownStarted: (() -> Void)?
    @ObservationIgnored var onCountdownFinished: (() -> Void)?
    /// 実際にスリープさせる処理。テストから差し替えられるようにしてある。
    @ObservationIgnored var sleepAction: () async throws -> Void = {
        try await SystemSleeper.sleepNow()
    }
    /// 1秒ごとに自分で時間を進めるか。
    /// 実際に寝てよいかの判断は時間経過と絡むため、テストではここを切って
    /// `tick()` を必要な回数だけ直接呼び、待たずに検証する。
    @ObservationIgnored var automaticTicking = true

    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    /// 止まったまま放置された待ち時間を畳むまでの猶予。
    /// 席へ戻って作業を再開した場合に、いつまでも「まもなくスリープ」を
    /// 抱えたままにしないための上限。
    private static let maximumHoldInterval: TimeInterval = 600

    /// 止まっている状態が続いた秒数
    @ObservationIgnored private var holdingSeconds: TimeInterval = 0

    // MARK: - 予約

    var isReserved: Bool { !reservations.isEmpty }

    /// 予約中の対象
    var targets: [SleepTarget] { reservations.map(\.target) }

    /// 予約の表示名を並べたもの（"Claude Code、Codex"）
    var reservationLabel: String { reservations.map(\.label).joined(separator: "、") }

    /// セッション1本を狙った予約だけ（設定画面の一覧に出す）
    var sessionReservations: [Reservation] {
        reservations.filter { if case .session = $0.target { return true } else { return false } }
    }

    /// 対象を予約へ加える（同じ対象がすでにあれば何もしない）。
    ///
    /// 待ち時間の最中に対象が増えたら、そのカウントは前提が変わっている。
    /// 数え直しにして、次にどれかが完了した時点で全体を評価しなおす。
    func reserve(_ target: SleepTarget, label: String) {
        guard !reservations.contains(where: { $0.target == target }) else { return }
        cancelCountdown(message: nil)
        reservations.append(Reservation(target: target, label: label))
        statusMessage = nil
        startMonitor()
    }

    /// 指定した対象の予約だけを外す（他の予約は残す）
    func cancelReservation(_ target: SleepTarget) {
        reservations.removeAll { $0.target == target }
        statusMessage = nil
        if reservations.isEmpty { cancelAllReservations(message: nil) }
    }

    /// 予約をすべて解除する
    func cancelAllReservations(message: String? = nil) {
        cancelCountdown(message: nil)
        monitorTask?.cancel()
        monitorTask = nil
        reservations = []
        statusMessage = message
    }

    /// このセッションが予約の対象に含まれるか（一覧の表示に使う）
    func isReserved(_ snapshot: SleepSessionSnapshot) -> Bool {
        reservations.contains { SleepCondition.covers($0.target, snapshot) }
    }

    /// このセッション1本を狙った予約があるか（CLI単位の予約とは区別する）
    func isReservedSession(tty: String, pid: Int32) -> Bool {
        reservations.contains { $0.target == .session(tty: tty, pid: pid) }
    }

    /// このCLIが予約の対象か（設定画面の選択状態に使う）
    func isReservedAgent(profileID: String) -> Bool {
        reservations.contains { $0.target == .agent(profileID: profileID) }
    }

    // MARK: - 完了イベントの受け取り

    /// セッションが完了・エラーになったことを受け取る。
    /// 予約の対象で、他の予約も含めて手が離せる状態になっていれば待ち時間へ入る。
    func noteFinished(_ finished: SleepSessionSnapshot) {
        guard !reservations.isEmpty, countdown == nil else { return }
        guard SleepCondition.shouldStartCountdown(
            targets: targets,
            finished: finished,
            sessions: sessionsProvider(),
            includesError: SleepPreferences.includesError
        ) else { return }
        startCountdown()
    }

    // MARK: - 待ち時間

    private func startCountdown() {
        holdingSeconds = 0
        statusMessage = nil
        countdown = Countdown(
            label: reservationLabel,
            targetCount: reservations.count,
            remaining: SleepPreferences.countdown,
            hold: .none,
            pausedByUser: false
        )
        startMonitor()
        onCountdownStarted?()
    }

    /// 待ち時間を取り消す（予約自体は残す）
    func cancelCountdown(message: String?) {
        guard countdown != nil else {
            if let message { statusMessage = message }
            return
        }
        countdown = nil
        holdingSeconds = 0
        statusMessage = message
        onCountdownFinished?()
    }

    /// 待たずに今すぐ寝る（ノッチのボタンから）
    func sleepImmediately() {
        guard countdown != nil else { return }
        Task { await fire() }
    }

    // MARK: - 監視

    /// 予約がある間だけ1秒ごとに様子を見る。
    /// 待ち時間の消化と、対象セッションの生存確認を兼ねる。
    private func startMonitor() {
        guard automaticTicking, monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.reservations.isEmpty else { return }
                await self.tick()
            }
        }
    }

    /// 1秒ぶん時間を進める。待ち時間の消化と、対象セッションの生存確認を行う。
    func tick() async {
        guard !reservations.isEmpty else { return }
        let sessions = sessionsProvider()

        // 対象のCLIが終了した予約を先に片付ける。
        // 残さないのは、待つ相手のいない予約が1つあるだけで
        // 「すべて終わったか」の判断が永久に成立しなくなるため。
        pruneDeadSessionReservations(sessions: sessions)
        guard !reservations.isEmpty, var current = countdown else { return }

        current.hold = SleepCondition.hold(targets: targets, sessions: sessions)
        current.pausedByUser = isUserInteracting()

        if current.isPaused {
            holdingSeconds += 1
            countdown = current
            // 止まったままの状態が続くなら、いったん畳んで予約だけ残す。
            // 次に対象が完了した時点で、改めて待ち時間から始まる。
            if holdingSeconds >= Self.maximumHoldInterval {
                cancelCountdown(
                    message: "作業が続いているため、スリープをいったん取り消しました。予約は残しています。")
            }
            return
        }

        holdingSeconds = 0
        // 0で止める。実行直前の再確認で見送った場合、次の秒でまた試せるようにするため。
        current.remaining = max(0, current.remaining - 1)
        countdown = current

        if current.remaining <= 0 { await fire() }
    }

    /// 対象のセッションが終了した「セッション指定」の予約を外す。
    ///
    /// CLI指定は残す。そのCLIをまた起動して使う可能性があり、
    /// 一時的に0本になっただけで予約が消えるほうが不便なため。
    private func pruneDeadSessionReservations(sessions: [SleepSessionSnapshot]) {
        let dead = sessionReservations.filter { reservation in
            !sessions.contains { SleepCondition.covers(reservation.target, $0) }
        }
        guard !dead.isEmpty else { return }

        let deadTargets = Set(dead.map(\.target))
        reservations.removeAll { deadTargets.contains($0.target) }
        let names = dead.map(\.label).joined(separator: "、")
        if reservations.isEmpty {
            cancelAllReservations(message: "\(names) が終了したため、スリープ予約を解除しました。")
        } else {
            statusMessage = "\(names) が終了したため、残りの予約だけを待ちます。"
        }
    }

    // MARK: - 実行

    private func fire() async {
        guard !reservations.isEmpty, let current = countdown else { return }

        // 直前にもう一度確かめる。1秒の間に承認待ちが現れることがある。
        let hold = SleepCondition.hold(targets: targets, sessions: sessionsProvider())
        guard !hold.isHolding, !isUserInteracting() else { return }

        countdown = nil
        onCountdownFinished?()

        do {
            try await sleepAction()
            let message = "\(current.label) の完了によりスリープしました。"
            // 既定では1回で解除する。残したままだと、復帰して作業を再開するたびに
            // また寝てしまい、解除の操作を思い出せないと使い物にならない。
            if SleepPreferences.repeats {
                statusMessage = message
            } else {
                cancelAllReservations(message: message)
            }
        } catch {
            // 失敗を黙って捨てると「予約したのに寝ない」理由が分からなくなる
            NSLog("Subghost: スリープに失敗しました: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
        }
    }
}
