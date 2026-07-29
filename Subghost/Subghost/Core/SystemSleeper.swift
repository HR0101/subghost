//
//  SystemSleeper.swift
//  Subghost
//
//  追補: Macを今すぐスリープさせる。
//
//  「寝かせてよいか」の判断は SleepScheduler が持ち、ここは寝かせることだけを行う。
//
//  手段は /usr/bin/pmset sleepnow。管理者権限を必要とせず、
//  AppleScript（System Events）と違ってオートメーションの許可ダイアログも出ない。
//  ユーザーが席を外している前提の機能なので、許可を求めて止まる経路は使えない。
//

import Foundation

nonisolated enum SystemSleeper {

    /// pmset の実体。GUIアプリはPATHが最小構成のため絶対パスで指定する。
    static let toolPath = "/usr/bin/pmset"

    enum SleepError: Error, LocalizedError {
        case toolMissing
        case launchFailed(String)
        case commandFailed(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return "スリープに使う pmset が見つかりませんでした。"
            case .launchFailed(let message):
                return "スリープコマンドを実行できませんでした: \(message)"
            case .commandFailed(let code, let message):
                let detail = message.isEmpty ? "終了コード \(code)" : message
                return "スリープに失敗しました: \(detail)"
            }
        }
    }

    /// 即座にスリープさせる。
    ///
    /// コマンドの終了は待つが、実際に画面が消えるのは非同期に起きる。
    /// 失敗を握り潰すと「予約したのに寝ない」理由が分からなくなるため、
    /// 終了コードと標準エラー出力を添えて投げ返す。
    static func sleepNow() async throws {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw SleepError.toolMissing
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = ["sleepnow"]

            let stderrPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SleepError.commandFailed(
                        code: proc.terminationStatus,
                        message: message
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: SleepError.launchFailed(error.localizedDescription))
            }
        }
    }
}
