import Foundation
import Testing
@testable import ShowTellShare

private final class UploadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var bodies: [String: Data] = [:]
    private static var shouldFailPartTwo = true

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]
        bodies = [:]
        shouldFailPartTwo = true
    }

    static func allowPartTwo() {
        lock.lock(); defer { lock.unlock() }
        shouldFailPartTwo = false
    }

    static func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key, default: 0]
    }

    static func body(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bodies[key]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let key = "\(method) \(path)"
        Self.lock.lock()
        Self.counts[key, default: 0] += 1
        if let body = requestBody() { Self.bodies[key] = body }
        let failPartTwo = Self.shouldFailPartTwo && path.hasSuffix("/parts/2")
        Self.lock.unlock()

        let status: Int
        let json: String
        if failPartTwo {
            status = 500
            json = #"{"error":"temporary"}"#
        } else if method == "POST", path == "/api/uploads" {
            status = 201
            json = #"{"uploadId":"upload-1","chunkSize":16,"ownerToken":"owner","shareURL":"https://share.test/s/demo?token=owner"}"#
        } else if method == "PUT", path.contains("/parts/") {
            status = 200
            let number = path.split(separator: "/").last ?? "1"
            json = "{\"partNumber\":\(number),\"etag\":\"etag-\(number)\",\"sizeBytes\":16}"
        } else if method == "POST", path.hasSuffix("/complete") {
            status = 200
            json = #"{"status":"processing"}"#
        } else if method == "PUT", path.hasSuffix("/metadata") {
            status = 200
            json = #"{"ok":true}"#
        } else {
            status = 404
            json = #"{"error":"not found"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Resumable private share upload")
struct ShareUploadClientTests {
    @Test("completed chunks survive a transient failure and metadata follows media")
    func resumesAtChunkBoundary() async throws {
        UploadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let client = ShareUploadClient(session: URLSession(configuration: configuration))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("recording.mp4")
        try Data(repeating: 0x42, count: 40).write(to: recording)
        let shareConfiguration = ShareUploadConfiguration(
            baseURL: URL(string: "https://share.test")!, token: "secret", privacy: .private,
            password: nil, expirationDays: 7, allowDownload: false
        )

        do {
            _ = try await client.uploadMedia(
                sessionDirectory: directory, sessionID: "session-1", title: "Test", recordingURL: recording,
                configuration: shareConfiguration, onCreated: { _ in }, onProgress: { _ in }
            )
            Issue.record("The first upload should fail after retrying part two")
        } catch {}

        #expect(UploadURLProtocol.count("POST /api/uploads") == 1)
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/parts/1") == 1)
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/parts/2") == 3)

        UploadURLProtocol.allowPartTwo()
        let receipt = try await client.uploadMedia(
            sessionDirectory: directory, sessionID: "session-1", title: "Test", recordingURL: recording,
            configuration: shareConfiguration, onCreated: { _ in }, onProgress: { _ in }
        )
        #expect(receipt.shareURL.host == "share.test")
        #expect(UploadURLProtocol.count("POST /api/uploads") == 1)
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/parts/1") == 1)
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/parts/2") == 4)
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/parts/3") == 1)
        #expect(UploadURLProtocol.count("POST /api/uploads/upload-1/complete") == 1)
        #expect(await client.needsResume(sessionDirectory: directory))
        #expect(await client.existingShareURL(sessionDirectory: directory)?.host == "share.test")

        try Data(#"{"text":"테스트","words":[]}"#.utf8).write(to: directory.appendingPathComponent("transcript.json"))
        let rootPathCanary = "/Users/private/CANARY-customer-project"
        let windowTitleCanary = "CANARY secret customer roadmap"
        let taskSpec = """
        {
          "schemaVersion": "1.0",
          "sessionId": "session-1",
          "project": {
            "name": "landing-page",
            "rootPath": "\(rootPathCanary)",
            "gitBranch": "feature/hero",
            "headCommit": "0123456789abcdef"
          },
          "goal": "Hero 수정",
          "summary": "Hero 높이를 줄인다.",
          "tasks": [{
            "id": "task-1",
            "title": "Hero 높이 축소",
            "target": {
              "description": "상단 Hero",
              "app": "Browser",
              "windowTitle": "\(windowTitleCanary)",
              "region": null
            },
            "change": { "instruction": "높이를 줄인다.", "value": "30%" },
            "constraints": [],
            "acceptanceCriteria": ["Hero가 30% 낮다."],
            "evidence": [{
              "kind": "speech",
              "tMs": 100,
              "frame": null,
              "quote": "높이를 줄여줘",
              "position": null
            }],
            "confidence": 0.9,
            "assumptions": []
          }],
          "unresolvedQuestions": []
        }
        """
        try Data(taskSpec.utf8).write(to: directory.appendingPathComponent("taskspec.json"))
        try await client.uploadMetadata(
            sessionDirectory: directory, receipt: receipt, configuration: shareConfiguration, durationMs: 1_000
        )
        #expect(UploadURLProtocol.count("PUT /api/uploads/upload-1/metadata") == 1)
        let metadataBody = try #require(UploadURLProtocol.body("PUT /api/uploads/upload-1/metadata"))
        let encodedMetadata = String(decoding: metadataBody, as: UTF8.self)
        #expect(!encodedMetadata.contains(rootPathCanary))
        #expect(!encodedMetadata.contains(windowTitleCanary))
        #expect(!encodedMetadata.contains("rootPath"))
        #expect(!encodedMetadata.contains("windowTitle"))
        let metadataJSON = try #require(JSONSerialization.jsonObject(with: metadataBody) as? [String: Any])
        let networkTaskSpec = try #require(metadataJSON["taskSpec"] as? [String: Any])
        let networkProject = try #require(networkTaskSpec["project"] as? [String: Any])
        #expect(networkProject["gitBranch"] as? String == "feature/hero")
        #expect(await client.needsResume(sessionDirectory: directory) == false)
    }

    @Test("local-only remains the default delivery mode")
    func localOnlyDefault() {
        #expect(DeliveryMode.localOnly.rawValue == "localOnly")
        #expect(SharePrivacy.private.rawValue == "private")
    }
}
