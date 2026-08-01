//===--- SDKSymbol.swift - SwiftDelta ------------------------------------------===//
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

public struct SDKSymbol: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let moduleName: String
    public let preciseIdentifier: String?
    public let fullyQualifiedName: String
    public let baseName: String
    public let kind: String
    public let declaration: String?
    public let signature: String?
    public let parameters: [SDKFunctionParameter]
    public let returnType: String?
    public let availability: [SDKAvailability]
    public let isUnavailable: Bool
    public let renamedDestination: String?
    public let migrationMessage: String?
    public let concurrency: SDKConcurrencyMetadata
    public let relationships: [SDKSymbolRelationship]
    public let propertyReadable: Bool?
    public let propertyWritable: Bool?
    public let isProtocolRequirement: Bool

    public init(
        id: String,
        moduleName: String,
        preciseIdentifier: String? = nil,
        fullyQualifiedName: String,
        baseName: String,
        kind: String,
        declaration: String? = nil,
        signature: String? = nil,
        parameters: [SDKFunctionParameter] = [],
        returnType: String? = nil,
        availability: [SDKAvailability] = [],
        isUnavailable: Bool = false,
        renamedDestination: String? = nil,
        migrationMessage: String? = nil,
        concurrency: SDKConcurrencyMetadata = SDKConcurrencyMetadata(),
        relationships: [SDKSymbolRelationship] = [],
        propertyReadable: Bool? = nil,
        propertyWritable: Bool? = nil,
        isProtocolRequirement: Bool = false
    ) {
        self.id = id
        self.moduleName = moduleName
        self.preciseIdentifier = preciseIdentifier
        self.fullyQualifiedName = fullyQualifiedName
        self.baseName = baseName
        self.kind = kind
        self.declaration = declaration
        self.signature = signature
        self.parameters = parameters
        self.returnType = returnType
        self.availability = availability
        self.isUnavailable = isUnavailable
        self.renamedDestination = renamedDestination
        self.migrationMessage = migrationMessage
        self.concurrency = concurrency
        self.relationships = relationships
        self.propertyReadable = propertyReadable
        self.propertyWritable = propertyWritable
        self.isProtocolRequirement = isProtocolRequirement
    }
}
