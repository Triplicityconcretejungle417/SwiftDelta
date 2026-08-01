//===--- BuildContextSelectionValidator.swift - SwiftDelta ------------------------------------------===//
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

public enum BuildContextSelectionValidator {
    public static func validate(
        sdkIdentifiers: [String],
        destination: String?
    ) throws {
        guard let destination, !destination.isEmpty else {
            return
        }
        guard sdkIdentifiers.count <= 1 else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "sdk/destination",
                reason:
                    "one destination cannot verify multiple SDK selections; "
                    + "run a separate comparison for each platform context"
            )
        }
        guard let sdk = sdkIdentifiers.first else {
            return
        }
        let lowerDestination = destination.lowercased()
        let simulatorSDKs = Set([
            "iphonesimulator", "appletvsimulator", "watchsimulator",
            "xrsimulator",
        ])
        let sdkIsSimulator = simulatorSDKs.contains(sdk.lowercased())
        if lowerDestination.contains("simulator"), !sdkIsSimulator {
            throw SwiftDeltaError.invalidConfiguration(
                field: "sdk/destination",
                reason:
                    "destination '\(destination)' selects a simulator but SDK "
                    + "'\(sdk)' selects a device platform"
            )
        }
        if sdkIsSimulator,
           lowerDestination.contains("platform="),
           !lowerDestination.contains("simulator")
        {
            throw SwiftDeltaError.invalidConfiguration(
                field: "sdk/destination",
                reason:
                    "SDK '\(sdk)' selects a simulator but destination "
                    + "'\(destination)' does not"
            )
        }
    }
}
