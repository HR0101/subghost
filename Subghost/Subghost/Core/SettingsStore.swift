//
//  SettingsStore.swift
//  Subghost
//
//  設定そのものを扱う操作（初期化・書き出し・読み込み）と、開発用の記録フラグ。
//
//  フック導入のようにアプリ外の設定も持つため、アプリ内設定を一度まっさらに
//  戻せる導線を用意しておく。書き出し／読み込みは、環境を移すときと、
//  不具合の報告に設定内容を添えたいときのため。
//

import Foundation

// MARK: - 開発用の記録

/// UserDefaults から読むだけで有効になる記録フラグ。
/// 以前は `defaults write` でしか切り替えられず、事実上使えなかったため設定へ出す。
nonisolated enum DiagnosticsPreferences {
    static let writeStateDumpKey = "writeStateDump"
    static let logDisplaySelectionKey = "logDisplaySelection"

    /// フック受信とセッション状態をファイルへ書き出す
    static var writeStateDump: Bool {
        NotchPreferences.bool(forKey: writeStateDumpKey, default: false)
    }

    /// ノッチをどの画面に置くと判断したかをコンソールへ記録する
    static var logDisplaySelection: Bool {
        NotchPreferences.bool(forKey: logDisplaySelectionKey, default: false)
    }

    /// 状態ダンプの書き出し先（診断画面から開けるようにする）
    static var stateDumpDirectory: URL {
        HookInstaller.supportDirectory.appendingPathComponent("run", isDirectory: true)
    }
}

// MARK: - 設定の初期化・入出力

enum SettingsStore {

    enum SettingsError: LocalizedError {
        case noDomain
        case unreadable
        case tooLarge
        case malformed

        var errorDescription: String? {
            switch self {
            case .noDomain: return "設定の保存領域を特定できませんでした。"
            case .unreadable: return "ファイルを読み込めませんでした。"
            case .tooLarge: return "設定ファイルが大きすぎます。"
            case .malformed: return "設定ファイルの形式が正しくありません。"
            }
        }
    }

    /// 設定ファイルは小さなplistのため、異常なファイルを丸ごとメモリへ載せない。
    static let maximumImportSize = 1_048_576

    private static var domainName: String? {
        Bundle.main.bundleIdentifier
    }

    /// Subghostが公開設定として扱う固定キー。
    /// 案内、移行番号、履歴、選択中セッションなどの端末固有状態は含めない。
    private static let fixedPortableKeys: Set<String> = [
        "pollInterval", "preferredTerminal", DisplayPreference.userDefaultsKey,
        NotchPreferences.hoverExpansionEnabledKey,
        NotchPreferences.hoverDelayKey,
        NotchPreferences.expansionAnimationDurationKey,
        NotchPreferences.smartNotificationSuppressionKey,
        NotchPreferences.hideInFullScreenKey,
        NotchPreferences.hideWhenNoSessionsKey,
        NotchPreferences.notificationDisplayDurationKey,
        NotchPreferences.collapseOnMouseExitKey,
        NotchPreferences.closeOnOutsideClickKey,
        NotchPreferences.hideUnmonitorableSessionsKey,
        NotchPreferences.hideInactiveSessionsKey,
        NotchPreferences.inactiveSessionThresholdKey,
        SleepPreferences.countdownKey,
        SleepPreferences.includesErrorKey,
        SleepPreferences.repeatsKey,
        AppearancePreferences.panelOpacityKey,
        AppearancePreferences.ghostAnimationEnabledKey,
        AppearancePreferences.sessionListMaxRowsKey,
        AppearancePreferences.expandedCornerRadiusKey,
        AppearancePreferences.hidePreviewTextKey,
        ActivityPreferences.limitKey,
        ActivityPreferences.recordingEnabledKey,
        NotificationPreferences.masterKey,
        "soundEnabled", "soundVolume",
        QuietHours.enabledKey, QuietHours.startKey, QuietHours.endKey,
        UsagePreferences.codexCollectionEnabledKey,
        UsagePreferences.warningKey, UsagePreferences.criticalKey,
        DiagnosticsPreferences.writeStateDumpKey,
        DiagnosticsPreferences.logDisplaySelectionKey,
    ]

    /// イベントやCLIごとに生成されるキーも、現在サポートしている値だけを許可する。
    static func isPortableKey(_ key: String) -> Bool {
        if fixedPortableKeys.contains(key) { return true }
        if HotkeyAction.allCases.contains(where: { $0.userDefaultsKey == key }) { return true }
        if NotificationEvent.allCases.contains(where: { $0.enabledKey == key }) { return true }
        if AlertSound.allCases.contains(where: { $0.enabledKey == key }) { return true }
        if ActivityKind.allCases.contains(where: { ActivityPreferences.kindKey($0) == key }) {
            return true
        }
        return CLIProfile.builtins.contains {
            AgentMutePreferences.key(profileID: $0.id) == key
        }
    }

    static func portableValues(from domain: [String: Any]) -> [String: Any] {
        domain.filter { isPortableKey($0.key) }
    }

    /// すべての設定を消して初期状態へ戻す。
    /// フックの導入といったアプリ外への変更には触れない。
    static func resetAll() throws {
        guard let domainName else { throw SettingsError.noDomain }
        UserDefaults.standard.removePersistentDomain(forName: domainName)
        UserDefaults.standard.synchronize()
    }

    /// 現在の設定を書き出す。
    /// Data を含む値も欠落なく往復させたいので、JSONではなくplistで持つ。
    static func export(to url: URL) throws {
        guard let domainName,
              let domain = UserDefaults.standard.persistentDomain(forName: domainName)
        else { throw SettingsError.noDomain }

        let portable = portableValues(from: domain)
        let data = try PropertyListSerialization.data(
            fromPropertyList: portable,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// 書き出した設定を読み込んで適用する。
    /// 既存の設定へ上書きで重ねる（ファイルに無いキーは今の値のまま残す）。
    @discardableResult
    static func importSettings(from url: URL) throws -> Int {
        guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = resourceValues.fileSize
        else { throw SettingsError.unreadable }
        guard size <= maximumImportSize else { throw SettingsError.tooLarge }
        guard let data = try? Data(contentsOf: url), data.count <= maximumImportSize
        else { throw SettingsError.unreadable }
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let values = plist as? [String: Any]
        else { throw SettingsError.malformed }

        let defaults = UserDefaults.standard
        var applied = 0
        for (key, value) in values where isPortableKey(key) {
            defaults.set(value, forKey: key)
            applied += 1
        }
        return applied
    }

    /// 書き出しの既定ファイル名
    static var suggestedFileName: String { "Subghost設定.plist" }
}
