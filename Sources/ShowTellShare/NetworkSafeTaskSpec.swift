import Foundation

/// An allowlisted projection of the local TaskSpec that is safe to attach to a
/// remote share. Fields that only make sense on the recording Mac (including
/// absolute project paths and captured window titles) are intentionally absent.
/// Unknown fields added to the local TaskSpec in the future are dropped by
/// `Decodable` rather than silently crossing the network boundary.
struct NetworkSafeTaskSpec: Codable, Equatable, Sendable {
    let schemaVersion: String
    let sessionId: String
    let project: Project
    let goal: String
    let summary: String
    let tasks: [Task]
    let unresolvedQuestions: [String]

    struct Project: Codable, Equatable, Sendable {
        let name: String?
        let gitBranch: String?
        let headCommit: String?
    }

    struct Task: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let target: Target
        let change: Change
        let constraints: [String]
        let acceptanceCriteria: [String]
        let evidence: [Evidence]
        let confidence: Double
        let assumptions: [String]
    }

    struct Target: Codable, Equatable, Sendable {
        let description: String
        let app: String?
        let region: Region?
    }

    struct Region: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let coordinateSpace: String
    }

    struct Change: Codable, Equatable, Sendable {
        let instruction: String
        let value: String?
    }

    struct Evidence: Codable, Equatable, Sendable {
        let kind: String
        let tMs: Int
        let frame: String?
        let quote: String?
        let position: Position?
    }

    struct Position: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let coordinateSpace: String
    }

    static func encodedProjection(of localData: Data, using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let projected = try JSONDecoder().decode(Self.self, from: localData)
        return try encoder.encode(projected)
    }
}
