//
//  HookServer.swift
//  Subghost
//
//  設計書 追補: フック方式
//
//  Claude Codeのフックから接続を受けるUnixドメインソケットサーバ。
//  TCPポートを開かないためネットワークに露出せず、ファイル権限(0700)で保護できる。
//
//  プロトコルは最小限のHTTP/1.1。curlがそのまま話せるため、
//  ブリッジ側に専用バイナリを用意しなくてよい。
//    リクエスト: POST /hook?source=claude  ボディ=フックのJSON
//    レスポンス: 200 + JSON（空オブジェクトなら「介入しない」の意味）
//

import Foundation

// MARK: - リクエスト

nonisolated struct HookRequest: Sendable {
    let source: String          // "claude" 等
    let tty: String?            // ブリッジが付けるヘッダ由来。取れないこともある。
    let body: Data
}

// MARK: - サーバ

/// フック接続を待ち受ける。応答は非同期に返せる（承認待ちのあいだ接続を保持するため）。
final class HookServer: @unchecked Sendable {

    /// 接続1本を表す。応答を返すまでフック側（＝CLI）は待ち続ける。
    final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var responded = false

        init(fd: Int32) { self.fd = fd }

        /// JSONを返して接続を閉じる。二重呼び出しは無視する。
        func respond(json: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !responded else { return }
            responded = true

            let body = Array(json.utf8)
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            _ = Array(header.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            _ = body.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }

        /// 介入しない（CLI本来の挙動に任せる）
        func respondPassthrough() { respond(json: "{}") }
    }

    /// 受信ハンドラ。応答は Connection 経由で任意のタイミングに返す。
    var onRequest: ((HookRequest, Connection) -> Void)?

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - 起動/停止

    func start() throws {
        stop()

        // ソケットは親ディレクトリごと本人のみアクセス可にする
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // 前回のソケットファイルが残っていると bind に失敗する
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.socketFailed(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw HookServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw HookServerError.bindFailed(errno)
        }
        // ソケット自体も本人のみ
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HookServerError.listenFailed(errno)
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.subghost.hookserver"
        thread.start()
        self.thread = thread
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        thread = nil
    }

    // MARK: - 受信ループ

    private func acceptLoop() {
        while listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                // stop() でリスナを閉じた場合もここに来る
                if listenFD < 0 { return }
                if errno == EINTR { continue }
                return
            }
            // 1接続ずつ独立に処理する（承認待ちで長時間ブロックするため）
            Thread.detachNewThread { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        let connection = Connection(fd: clientFD)
        guard let raw = Self.readRequest(fd: clientFD) else {
            connection.respondPassthrough()
            return
        }
        guard let parsed = HTTPRequestParser.parse(raw) else {
            connection.respondPassthrough()
            return
        }
        let request = HookRequest(
            source: parsed.query["source"] ?? "unknown",
            tty: parsed.headers["x-subghost-tty"].flatMap { $0.isEmpty || $0 == "??" ? nil : $0 },
            body: parsed.body
        )
        guard let onRequest else {
            connection.respondPassthrough()
            return
        }
        onRequest(request, connection)
    }

    /// ヘッダを読み、Content-Length分の本文まで読み切る
    private static func readRequest(fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // ヘッダ終端まで
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return buffer.isEmpty ? nil : buffer }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 1_048_576 { return buffer }   // 異常に大きい入力は打ち切る
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return buffer }

        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength = headerText
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

        var bodyCount = buffer.count - headerEnd.upperBound
        while bodyCount < contentLength {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            bodyCount += n
        }
        return buffer
    }
}

// MARK: - エラー

nonisolated enum HookServerError: Error, LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong

    var errorDescription: String? {
        switch self {
        case .socketFailed(let code): return "ソケットを作成できませんでした (errno \(code))"
        case .bindFailed(let code): return "ソケットをbindできませんでした (errno \(code))"
        case .listenFailed(let code): return "ソケットをlistenできませんでした (errno \(code))"
        case .pathTooLong: return "ソケットのパスが長すぎます"
        }
    }
}

// MARK: - 最小HTTPパーサ

nonisolated enum HTTPRequestParser {

    struct Parsed: Equatable {
        var path: String
        var query: [String: String]
        var headers: [String: String]   // キーは小文字
        var body: Data
    }

    static func parse(_ raw: Data) -> Parsed? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }

        // リクエスト行: "POST /hook?source=claude HTTP/1.1"
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let target = String(requestLine[1])

        let parts = target.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "/")
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
        }

        return Parsed(
            path: path,
            query: query,
            headers: headers,
            body: Data(raw[headerEnd.upperBound...])
        )
    }
}
