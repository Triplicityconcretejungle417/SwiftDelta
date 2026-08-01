//===--- SDKMetadata.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Foundation

public struct SDKInstallationIdentity: Codable, Hashable, Sendable {
    public let xcodeApplicationPath: String
    public let developerDirectory: String
    public let xcodeVersion: String
    public let xcodeBuild: String
    public let platform: String
    public let sdkIdentifier: String
    public let sdkVersion: String
    public let sdkPath: String
    public let swiftVersion: String?

    public init(
        xcodeApplicationPath: String,
        developerDirectory: String,
        xcodeVersion: String,
        xcodeBuild: String,
        platform: String,
        sdkIdentifier: String,
        sdkVersion: String,
        sdkPath: String,
        swiftVersion: String? = nil
    ) {
        self.xcodeApplicationPath = xcodeApplicationPath
        self.developerDirectory = developerDirectory
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.platform = platform
        self.sdkIdentifier = sdkIdentifier
        self.sdkVersion = sdkVersion
        self.sdkPath = sdkPath
        self.swiftVersion = swiftVersion
    }
}

public struct SDKAvailability: Codable, Hashable, Sendable, CustomStringConvertible {
    public let domain: String
    public let introduced: String?
    public let deprecated: String?
    public let obsoleted: String?
    public let isUnconditionallyDeprecated: Bool
    public let isUnconditionallyUnavailable: Bool
    public let renamed: String?
    public let message: String?

    public init(
        domain: String,
        introduced: String? = nil,
        deprecated: String? = nil,
        obsoleted: String? = nil,
        isUnconditionallyDeprecated: Bool = false,
        isUnconditionallyUnavailable: Bool = false,
        renamed: String? = nil,
        message: String? = nil
    ) {
        self.domain = domain
        self.introduced = introduced
        self.deprecated = deprecated
        self.obsoleted = obsoleted
        self.isUnconditionallyDeprecated = isUnconditionallyDeprecated
        self.isUnconditionallyUnavailable = isUnconditionallyUnavailable
        self.renamed = renamed
        self.message = message
    }

    public var description: String {
        var parts = [domain]
        if let introduced {
            parts.append("introduced \(introduced)")
        }
        if let deprecated {
            parts.append("deprecated \(deprecated)")
        }
        if let obsoleted {
            parts.append("obsoleted \(obsoleted)")
        }
        if isUnconditionallyDeprecated {
            parts.append("unconditionally deprecated")
        }
        if isUnconditionallyUnavailable {
            parts.append("unavailable")
        }
        if let renamed {
            parts.append("renamed \(renamed)")
        }
        if let message {
            parts.append("message: \(message)")
        }
        return parts.joined(separator: ", ")
    }
}

public struct SDKFunctionParameter: Codable, Hashable, Sendable {
    public let name: String?
    public let externalName: String?
    public let type: String?
    public let hasDefaultValue: Bool?

    public init(
        name: String? = nil,
        externalName: String? = nil,
        type: String? = nil,
        hasDefaultValue: Bool? = nil
    ) {
        self.name = name
        self.externalName = externalName
        self.type = type
        self.hasDefaultValue = hasDefaultValue
    }
}

public struct SDKConcurrencyMetadata: Codable, Hashable, Sendable {
    public let actorIsolation: String?
    public let isAsync: Bool
    public let isSendable: Bool
    public let isNonisolated: Bool
    public let isPreconcurrency: Bool

    public init(
        actorIsolation: String? = nil,
        isAsync: Bool = false,
        isSendable: Bool = false,
        isNonisolated: Bool = false,
        isPreconcurrency: Bool = false
    ) {
        self.actorIsolation = actorIsolation
        self.isAsync = isAsync
        self.isSendable = isSendable
        self.isNonisolated = isNonisolated
        self.isPreconcurrency = isPreconcurrency
    }
}

public struct SDKSymbolRelationship: Codable, Hashable, Sendable {
    public let kind: String
    public let target: String

    public init(kind: String, target: String) {
        self.kind = kind
        self.target = target
    }
}
