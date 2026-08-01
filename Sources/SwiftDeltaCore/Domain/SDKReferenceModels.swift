//===--- SDKReferenceModels.swift - SwiftDelta ------------------------------------------===//
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

public enum SymbolResolutionMethod: String, Codable, Hashable, Sendable {
    case compilerUSR
    case compilerQualifiedDeclaration
    case uncertainText
}

public struct SDKSymbolReference: Codable, Hashable, Sendable {
    public let preciseIdentifier: String?
    public let moduleName: String?
    public let fullyQualifiedName: String?
    public let sourceLocation: SourceLocation
    public let resolutionMethod: SymbolResolutionMethod
    public let isActiveCompilationBranch: Bool
    public let target: String?
    public let buildContextIdentity: String?

    public init(
        preciseIdentifier: String? = nil,
        moduleName: String? = nil,
        fullyQualifiedName: String? = nil,
        sourceLocation: SourceLocation,
        resolutionMethod: SymbolResolutionMethod,
        isActiveCompilationBranch: Bool = true,
        target: String? = nil,
        buildContextIdentity: String? = nil
    ) {
        self.preciseIdentifier = preciseIdentifier
        self.moduleName = moduleName
        self.fullyQualifiedName = fullyQualifiedName
        self.sourceLocation = sourceLocation
        self.resolutionMethod = resolutionMethod
        self.isActiveCompilationBranch = isActiveCompilationBranch
        self.target = target
        self.buildContextIdentity = buildContextIdentity
    }
}

public struct SDKFindingEvidence: Codable, Hashable, Sendable {
    public let baseline: SDKInstallationIdentity
    public let candidate: SDKInstallationIdentity
    public let platform: String
    public let moduleName: String
    public let preciseIdentifier: String?
    public let fullyQualifiedName: String
    public let sourceLocation: SourceLocation
    public let changeKind: SDKChangeKind
    public let observedChange: String
    public let oldDeclaration: String?
    public let newDeclaration: String?
    public let oldAvailability: [SDKAvailability]
    public let newAvailability: [SDKAvailability]
    public let migrationMessage: String?
    public let resolutionMethod: SymbolResolutionMethod

    public init(
        baseline: SDKInstallationIdentity,
        candidate: SDKInstallationIdentity,
        platform: String,
        moduleName: String,
        preciseIdentifier: String?,
        fullyQualifiedName: String,
        sourceLocation: SourceLocation,
        changeKind: SDKChangeKind,
        observedChange: String,
        oldDeclaration: String?,
        newDeclaration: String?,
        oldAvailability: [SDKAvailability],
        newAvailability: [SDKAvailability],
        migrationMessage: String?,
        resolutionMethod: SymbolResolutionMethod
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.platform = platform
        self.moduleName = moduleName
        self.preciseIdentifier = preciseIdentifier
        self.fullyQualifiedName = fullyQualifiedName
        self.sourceLocation = sourceLocation
        self.changeKind = changeKind
        self.observedChange = observedChange
        self.oldDeclaration = oldDeclaration
        self.newDeclaration = newDeclaration
        self.oldAvailability = oldAvailability
        self.newAvailability = newAvailability
        self.migrationMessage = migrationMessage
        self.resolutionMethod = resolutionMethod
    }
}
