//===--- SDKSnapshotModels.swift - SwiftDelta ------------------------------------------===//
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

public enum SDKModuleExtractionSource: String, Codable, Hashable, Sendable {
    case symbolGraph
    case swiftInterface
    case failed
}

public struct SDKModuleExtraction: Codable, Hashable, Sendable {
    public let moduleName: String
    public let source: SDKModuleExtractionSource
    public let symbolCount: Int
    public let detail: String?

    public init(
        moduleName: String,
        source: SDKModuleExtractionSource,
        symbolCount: Int,
        detail: String? = nil
    ) {
        self.moduleName = moduleName
        self.source = source
        self.symbolCount = symbolCount
        self.detail = detail
    }

    public var succeeded: Bool {
        source != .failed
    }
}

public struct SDKSnapshot: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 3

    public let formatVersion: Int
    public let identity: SDKInstallationIdentity
    public let modules: [String]
    public let symbols: [SDKSymbol]
    public let moduleExtractions: [SDKModuleExtraction]
    public let extractionWarnings: [String]

    public init(
        identity: SDKInstallationIdentity,
        modules: [String],
        symbols: [SDKSymbol],
        moduleExtractions: [SDKModuleExtraction]? = nil,
        extractionWarnings: [String] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.identity = identity
        self.modules = Array(Set(modules)).sorted()
        self.symbols = symbols.sorted {
            if $0.moduleName != $1.moduleName {
                return $0.moduleName < $1.moduleName
            }
            if $0.fullyQualifiedName != $1.fullyQualifiedName {
                return $0.fullyQualifiedName < $1.fullyQualifiedName
            }
            return $0.id < $1.id
        }
        self.moduleExtractions = (
            moduleExtractions
                ?? Array(Set(modules)).sorted().map { module in
                    SDKModuleExtraction(
                        moduleName: module,
                        source: .symbolGraph,
                        symbolCount: symbols.count { $0.moduleName == module }
                    )
                }
        ).sorted { $0.moduleName < $1.moduleName }
        self.extractionWarnings = extractionWarnings
    }

    public var successfullyExtractedModules: Set<String> {
        Set(moduleExtractions.filter(\.succeeded).map(\.moduleName))
    }
}
