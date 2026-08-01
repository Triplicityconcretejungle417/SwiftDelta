//===--- FindingModels.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import CryptoKit
import Foundation

public enum Severity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case notice

    public var rank: Int {
        switch self {
        case .notice: 1
        case .warning: 2
        case .error: 3
        }
    }

    public func isAtLeast(_ other: Severity) -> Bool {
        rank >= other.rank
    }
}

public enum Confidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    public var rank: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public func isAtLeast(_ other: Confidence) -> Bool {
        rank >= other.rank
    }
}

public enum FindingCategory: String, Codable, CaseIterable, Sendable {
    case source
    case compiler
    case sdk
    case buildSetting
    case package
    case dependency
    case configuration
}

public enum FindingOrigin: String, Codable, Sendable {
    case sdk
    case compiler
    case buildSettings
    case package
}

public struct SourceLocation: Codable, Hashable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

public struct Finding: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let findingID: String
    public let category: FindingCategory
    public let title: String
    public let explanation: String
    public let severity: Severity
    public let confidence: Confidence
    public let location: SourceLocation?
    public let targetVersion: String?
    public let migrationMessage: String?
    public let referenceURL: URL?
    public let origin: FindingOrigin
    public let automaticRemediationSupported: Bool
    public let target: String?
    public let configuration: String?
    public let sdkEvidence: SDKFindingEvidence?

    public init(
        id: UUID? = nil,
        findingID: String,
        category: FindingCategory,
        title: String,
        explanation: String,
        severity: Severity,
        confidence: Confidence,
        location: SourceLocation? = nil,
        targetVersion: String? = nil,
        migrationMessage: String? = nil,
        referenceURL: URL? = nil,
        origin: FindingOrigin,
        automaticRemediationSupported: Bool = false,
        target: String? = nil,
        configuration: String? = nil,
        sdkEvidence: SDKFindingEvidence? = nil,
        identityDiscriminator: String? = nil
    ) {
        self.id = id ?? Self.stableUUID(
            findingID: findingID,
            location: location,
            target: target,
            configuration: configuration,
            explanation: explanation,
            identityDiscriminator: identityDiscriminator
        )
        self.findingID = findingID
        self.category = category
        self.title = title
        self.explanation = explanation
        self.severity = severity
        self.confidence = confidence
        self.location = location
        self.targetVersion = targetVersion
        self.migrationMessage = migrationMessage
        self.referenceURL = referenceURL
        self.origin = origin
        self.automaticRemediationSupported = automaticRemediationSupported
        self.target = target
        self.configuration = configuration
        self.sdkEvidence = sdkEvidence
    }

    public var stableKey: String {
        [
            findingID,
            location?.path ?? "",
            location?.line.map(String.init) ?? "",
            location?.column.map(String.init) ?? "",
            target ?? "",
            configuration ?? "",
        ].joined(separator: "|")
    }

    private static func stableUUID(
        findingID: String,
        location: SourceLocation?,
        target: String?,
        configuration: String?,
        explanation: String,
        identityDiscriminator: String?
    ) -> UUID {
        let value = [
            findingID,
            location?.path ?? "",
            location?.line.map(String.init) ?? "",
            location?.column.map(String.init) ?? "",
            target ?? "",
            configuration ?? "",
            identityDiscriminator ?? explanation,
        ].joined(separator: "\u{1F}")
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct AnalysisFailure: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fileRead
        case parse
        case discovery
        case build
    }

    public let kind: Kind
    public let message: String
    public let location: SourceLocation?

    public init(kind: Kind, message: String, location: SourceLocation? = nil) {
        self.kind = kind
        self.message = message
        self.location = location
    }
}
