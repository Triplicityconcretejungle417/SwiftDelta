//===--- SDKFixtures.swift - SwiftDelta ------------------------------------------===//
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
import SwiftDeltaCore

func makeSDKIdentity(
    xcode: String,
    build: String,
    sdk: String,
    path: String
) -> SDKInstallationIdentity {
    SDKInstallationIdentity(
        xcodeApplicationPath: path,
        developerDirectory: "\(path)/Contents/Developer",
        xcodeVersion: xcode,
        xcodeBuild: build,
        platform: "SyntheticOS",
        sdkIdentifier: "syntheticos",
        sdkVersion: sdk,
        sdkPath: "/Synthetic/SDK\(sdk).sdk",
        swiftVersion: "Swift \(xcode)"
    )
}

func makeSDKSymbol(
    _ id: String,
    _ name: String,
    kind: String = "swift.method",
    declaration: String,
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
) -> SDKSymbol {
    SDKSymbol(
        id: id,
        moduleName: "FictionalSDK",
        preciseIdentifier: id,
        fullyQualifiedName: "FictionalSDK.\(name)",
        baseName: name.split(separator: ".").last?
            .split(separator: "(").first.map(String.init) ?? name,
        kind: kind,
        declaration: declaration,
        signature: declaration,
        parameters: parameters,
        returnType: returnType,
        availability: availability,
        isUnavailable: isUnavailable,
        renamedDestination: renamedDestination,
        migrationMessage: migrationMessage,
        concurrency: concurrency,
        relationships: relationships,
        propertyReadable: propertyReadable,
        propertyWritable: propertyWritable,
        isProtocolRequirement: isProtocolRequirement
    )
}
