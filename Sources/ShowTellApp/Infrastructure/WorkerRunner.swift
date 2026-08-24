import Foundation

struct WorkerEvent: Decodable, Sendable {
    let type: String
    let stage: String?
    let fraction: Double?
    let taskSpecPath: String?
    let exportPath: String?
    let exportStatus: String?
    let exportError: WorkerExportFailure?
    let message: String?
}

struct WorkerExportFailure: Decodable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
}

enum WorkerRunnerError: LocalizedError {
    case helperMissing
    case failed(Int32, String)
    case noCompletion

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "AI worker 실행 파일을 찾을 수 없습니다. 앱을 다시 빌드해 주세요."
        case let .failed(_, message): return message
        case .noCompletion: return "AI worker가 완료 결과를 반환하지 않았습니다."
        }
    }
}

final class WorkerRunner {
    private var process: Process?

    func processSession(
        session: URL,
        exportDirectory: URL,
        apiKey: String,
        onProgress: @escaping @Sendable (WorkerEvent) -> Void
    ) async throws -> WorkerEvent {
        guard let helper = resolveHelper() else { throw WorkerRunnerError.helperMissing }
        let process = Process()
        self.process = process
        process.executableURL = helper
        process.arguments = ["process", "--session", session.path, "--export", exportDirectory.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "SOOM_API_KEY_STDIN": "1"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        let secretInput = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = secretInput

        return try await withCheckedThrowingContinuation { continuation in
            let outputState = WorkerOutputState()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                outputState.consume(chunk, onProgress: onProgress)
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                outputState.consume(stdout.fileHandleForReading.readDataToEndOfFile(), onProgress: onProgress)
                // Drain diagnostics so the helper cannot block, but never put
                // request IDs, usage payloads, or internal JSON in the UI.
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                let completed = outputState.completedEvent()
                if process.terminationStatus != 0 {
                    let message = outputState.errorEvent()?.message ?? "TaskSpec 처리 중 오류가 발생했습니다. 세션은 보존되었습니다."
                    continuation.resume(throwing: WorkerRunnerError.failed(process.terminationStatus, message))
                } else if let completed {
                    continuation.resume(returning: completed)
                } else {
                    continuation.resume(throwing: WorkerRunnerError.noCompletion)
                }
            }

            do {
                try process.run()
                // Avoid exposing the BYOK secret through argv or the child
                // environment. The helper reads this inherited pipe once and
                // immediately closes it before making network requests.
                secretInput.fileHandleForWriting.write(Data(apiKey.utf8))
                try? secretInput.fileHandleForWriting.close()
            } catch {
                try? secretInput.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func resolveHelper() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/soom-worker")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["SOOM_WORKER_PATH"]
            ?? ProcessInfo.processInfo.environment["SHOWTELL_WORKER_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("worker/dist/soom-worker")
        return FileManager.default.isExecutableFile(atPath: local.path) ? local : nil
#else
        return nil
#endif
    }
}

private final class WorkerOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var completion: WorkerEvent?
    private var terminalError: WorkerEvent?

    func consume(_ chunk: Data, onProgress: @escaping @Sendable (WorkerEvent) -> Void) {
        guard !chunk.isEmpty else { return }
        var events: [WorkerEvent] = []
        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(WorkerEvent.self, from: Data(line)) {
                if event.type == "complete" { completion = event }
                if event.type == "error" { terminalError = event }
                events.append(event)
            }
        }
        lock.unlock()
        for event in events { onProgress(event) }
    }

    func completedEvent() -> WorkerEvent? {
        lock.lock(); defer { lock.unlock() }
        return completion
    }

    func errorEvent() -> WorkerEvent? {
        lock.lock(); defer { lock.unlock() }
        return terminalError
    }
}
