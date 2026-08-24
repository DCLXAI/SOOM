import Foundation

public enum DeliveryMode: String, CaseIterable, Identifiable, Sendable {
    case localOnly
    case share

    public var id: String { rawValue }
    public var title: String { self == .localOnly ? "Local Only" : "Share" }
    public var subtitle: String {
        self == .localOnly ? "영상이 Mac 밖으로 나가지 않습니다" : "선택한 녹화만 암호화 업로드합니다"
    }
}

public enum SharePrivacy: String, CaseIterable, Identifiable, Codable, Sendable {
    case `private`
    case password
    case `public`

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .private: return "비공개 링크"
        case .password: return "비밀번호 보호"
        case .public: return "공개"
        }
    }
}

public struct ShareUploadConfiguration: Sendable {
    public let baseURL: URL
    public let token: String
    public let privacy: SharePrivacy
    public let password: String?
    public let expirationDays: Int?
    public let allowDownload: Bool

    public init(baseURL: URL, token: String, privacy: SharePrivacy, password: String?, expirationDays: Int?, allowDownload: Bool) {
        self.baseURL = baseURL
        self.token = token
        self.privacy = privacy
        self.password = password
        self.expirationDays = expirationDays
        self.allowDownload = allowDownload
    }
}

public struct ShareUploadReceipt: Sendable {
    public let uploadID: String
    public let shareURL: URL
}

private struct PersistentUploadState: Codable {
    var baseURL: String
    var uploadID: String
    var shareURL: String
    var ownerToken: String
    var chunkSize: Int
    var totalBytes: Int64
    var completedParts: [Int]
    var mediaCompleted: Bool
    var metadataCompleted: Bool?
}

private struct CreateUploadRequest: Encodable {
    let sessionId: String
    let title: String
    let totalBytes: Int64
    let mimeType = "video/mp4"
    let privacy: SharePrivacy
    let password: String?
    let expiresAt: String?
    let allowDownload: Bool
}

private struct CreateUploadResponse: Decodable {
    let uploadId: String
    let chunkSize: Int
    let ownerToken: String
    let shareURL: String
}

private struct CompleteUploadResponse: Decodable {
    let status: String
}

enum ShareUploadError: LocalizedError {
    case invalidConfiguration
    case invalidResponse(Int, String)
    case missingArtifact(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "공유 서버 주소와 업로드 토큰을 확인해 주세요."
        case let .invalidResponse(status, message):
            return "공유 서버 오류 (\(status)): \(message)"
        case let .missingArtifact(name):
            return "공유할 \(name) 파일을 찾을 수 없습니다."
        }
    }
}

public actor ShareUploadClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func uploadMedia(
        sessionDirectory: URL,
        sessionID: String,
        title: String,
        recordingURL: URL,
        configuration: ShareUploadConfiguration,
        onCreated: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ShareUploadReceipt {
        guard configuration.baseURL.scheme == "https" || configuration.baseURL.host == "localhost",
              !configuration.token.isEmpty else { throw ShareUploadError.invalidConfiguration }
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw ShareUploadError.missingArtifact("녹화")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: recordingURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard totalBytes > 0 else { throw ShareUploadError.missingArtifact("녹화") }

        let stateURL = sessionDirectory.appendingPathComponent("share-upload.json")
        var state = try loadState(from: stateURL)
        if state?.baseURL != configuration.baseURL.absoluteString || state?.totalBytes != totalBytes {
            state = nil
        }
        if state == nil {
            let expiresAt = configuration.expirationDays.map {
                ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0 * 86_400)))
            }
            let response: CreateUploadResponse = try await jsonRequest(
                endpoint(configuration.baseURL, "api", "uploads"),
                method: "POST",
                token: configuration.token,
                body: CreateUploadRequest(
                    sessionId: sessionID,
                    title: title,
                    totalBytes: totalBytes,
                    privacy: configuration.privacy,
                    password: configuration.privacy == .password ? configuration.password : nil,
                    expiresAt: expiresAt,
                    allowDownload: configuration.allowDownload
                )
            )
            state = PersistentUploadState(
                baseURL: configuration.baseURL.absoluteString,
                uploadID: response.uploadId,
                shareURL: response.shareURL,
                ownerToken: response.ownerToken,
                chunkSize: response.chunkSize,
                totalBytes: totalBytes,
                completedParts: [],
                mediaCompleted: false,
                metadataCompleted: false
            )
            try writeState(state!, to: stateURL)
        }
        guard var state, let shareURL = URL(string: state.shareURL) else {
            throw ShareUploadError.invalidConfiguration
        }
        onCreated(shareURL)
        if state.mediaCompleted {
            onProgress(1)
            return ShareUploadReceipt(uploadID: state.uploadID, shareURL: shareURL)
        }

        let file = try FileHandle(forReadingFrom: recordingURL)
        defer { try? file.close() }
        let partCount = Int((totalBytes + Int64(state.chunkSize) - 1) / Int64(state.chunkSize))
        for partNumber in 1...partCount where !state.completedParts.contains(partNumber) {
            let offset = Int64(partNumber - 1) * Int64(state.chunkSize)
            try file.seek(toOffset: UInt64(offset))
            let count = Int(min(Int64(state.chunkSize), totalBytes - offset))
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw ShareUploadError.missingArtifact("녹화 데이터")
            }
            let url = endpoint(configuration.baseURL, "api", "uploads", state.uploadID, "parts", String(partNumber))
            try await retrying {
                var request = self.authorizedRequest(url, method: "PUT", token: configuration.token)
                request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
                let (responseData, response) = try await self.session.data(for: request)
                try Self.validate(responseData, response: response)
            }
            state.completedParts.append(partNumber)
            try writeState(state, to: stateURL)
            onProgress(Double(state.completedParts.count) / Double(partCount))
        }

        let completed: CompleteUploadResponse = try await jsonRequest(
            endpoint(configuration.baseURL, "api", "uploads", state.uploadID, "complete"),
            method: "POST",
            token: configuration.token,
            body: Optional<String>.none
        )
        guard completed.status == "processing" else { throw ShareUploadError.invalidResponse(500, "처리 큐 등록 실패") }
        state.mediaCompleted = true
        try writeState(state, to: stateURL)
        onProgress(1)
        return ShareUploadReceipt(uploadID: state.uploadID, shareURL: shareURL)
    }

    public func uploadMetadata(
        sessionDirectory: URL,
        receipt: ShareUploadReceipt,
        configuration: ShareUploadConfiguration,
        durationMs: Int?
    ) async throws {
        let transcriptURL = sessionDirectory.appendingPathComponent("transcript.json")
        let taskSpecURL = sessionDirectory.appendingPathComponent("taskspec.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { throw ShareUploadError.missingArtifact("자막") }
        guard FileManager.default.fileExists(atPath: taskSpecURL.path) else { throw ShareUploadError.missingArtifact("TaskSpec") }
        let transcript = try JSONSerialization.jsonObject(with: Data(contentsOf: transcriptURL))
        let networkTaskSpecData = try NetworkSafeTaskSpec.encodedProjection(
            of: Data(contentsOf: taskSpecURL),
            using: encoder
        )
        let taskSpec = try JSONSerialization.jsonObject(with: networkTaskSpecData)
        let payload: [String: Any] = [
            "transcript": transcript,
            "taskSpec": taskSpec,
            "durationMs": durationMs as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let url = endpoint(configuration.baseURL, "api", "uploads", receipt.uploadID, "metadata")
        try await retrying {
            var request = self.authorizedRequest(url, method: "PUT", token: configuration.token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let (responseData, response) = try await self.session.data(for: request)
            try Self.validate(responseData, response: response)
        }
        let stateURL = sessionDirectory.appendingPathComponent("share-upload.json")
        if var state = try loadState(from: stateURL) {
            state.metadataCompleted = true
            try writeState(state, to: stateURL)
        }
    }

    public func needsResume(sessionDirectory: URL) -> Bool {
        let stateURL = sessionDirectory.appendingPathComponent("share-upload.json")
        guard let state = try? loadState(from: stateURL) else { return false }
        return !state.mediaCompleted || state.metadataCompleted != true
    }

    public func existingShareURL(sessionDirectory: URL) -> URL? {
        let stateURL = sessionDirectory.appendingPathComponent("share-upload.json")
        guard let state = try? loadState(from: stateURL) else { return nil }
        return URL(string: state.shareURL)
    }

    private func jsonRequest<RequestBody: Encodable, ResponseBody: Decodable>(
        _ url: URL,
        method: String,
        token: String,
        body: RequestBody?
    ) async throws -> ResponseBody {
        try await retrying {
            var request = self.authorizedRequest(url, method: method, token: token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { request.httpBody = try self.encoder.encode(body) }
            let (data, response) = try await self.session.data(for: request)
            try Self.validate(data, response: response)
            return try self.decoder.decode(ResponseBody.self, from: data)
        }
    }

    private func retrying<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await operation() }
            catch let error as ShareUploadError {
                if case let .invalidResponse(status, _) = error, status != 408, status != 429, status < 500 { throw error }
                lastError = error
            } catch { lastError = error }
            if attempt < 2 { try await Task.sleep(for: .seconds(pow(2, Double(attempt)))) }
        }
        throw lastError ?? ShareUploadError.invalidResponse(500, "업로드 실패")
    }

    private func loadState(from url: URL) throws -> PersistentUploadState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(PersistentUploadState.self, from: Data(contentsOf: url))
    }

    private func writeState(_ state: PersistentUploadState, to url: URL) throws {
        try encoder.encode(state).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func endpoint(_ baseURL: URL, _ components: String...) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }

    private func authorizedRequest(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("SOOM-macOS/0.6", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func validate(_ data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ShareUploadError.invalidResponse(0, "응답 없음") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "요청 실패"
            throw ShareUploadError.invalidResponse(http.statusCode, message)
        }
    }
}
