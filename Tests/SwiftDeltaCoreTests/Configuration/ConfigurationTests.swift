//===--- ConfigurationTests.swift - SwiftDelta ------------------------------------------===//
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
import XCTest

final class ConfigurationTests: XCTestCase {
func testConfigurationLoadsSDKArchitectureAndAppliesOverrides() throws {
        let directory = try TestDirectory(name: "configuration")
        let config = try directory.write(
            ".swiftdelta.json",
            """
            {
              "baselineXcodePath": "/Synthetic/Xcode-Old.app",
              "candidateXcodePath": "/Synthetic/Xcode-New.app",
              "sdkIdentifiers": ["macosx", "iphoneos"],
              "activeCompilationConditions": ["FEATURE_A"],
              "minimumSeverity": "warning",
              "minimumConfidence": "high",
              "ciFailureLevel": "error",
              "outputFormat": "json"
            }
            """
        )

        let loaded = try ConfigurationLoader.load(
            projectRoot: directory.url,
            explicitURL: config
        )
        let updated = try loaded.applying(
            ConfigurationOverrides(
                sdkIdentifiers: ["macosx"],
                activeCompilationConditions: ["FEATURE_B"],
                minimumConfidence: .medium
            )
        )

        XCTAssertEqual(updated.baselineXcodePath, "/Synthetic/Xcode-Old.app")
        XCTAssertEqual(updated.candidateXcodePath, "/Synthetic/Xcode-New.app")
        XCTAssertEqual(updated.sdkIdentifiers, ["macosx"])
        XCTAssertEqual(updated.activeCompilationConditions, ["FEATURE_B"])
        XCTAssertEqual(updated.minimumConfidence, .medium)
        XCTAssertNoThrow(try updated.validate(requireXcodePair: true))
    }

    func testConfigurationRejectsMissingPairDuplicatesAndInvalidConditions() {
        XCTAssertThrowsError(
            try SwiftDeltaConfiguration(
                baselineXcodePath: "/Synthetic/Xcode.app"
            ).validate(requireXcodePair: true)
        )
        XCTAssertThrowsError(
            try SwiftDeltaConfiguration(
                sdkIdentifiers: ["macosx", "macosx"]
            ).validate()
        )
        XCTAssertThrowsError(
            try SwiftDeltaConfiguration(
                activeCompilationConditions: ["FEATURE-A"]
            ).validate()
        )
    }
}
