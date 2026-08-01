//===--- BuildSettingsTests.swift - SwiftDelta ------------------------------------------===//
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

final class BuildSettingsTests: XCTestCase {
func testBuildSettingsDifferencesAreEvidenceBackedWithoutRecommendations() throws {
        let old = BuildSettingsSnapshot(
            target: "SyntheticTarget",
            configuration: "Debug",
            settings: [
                "ARCHS": "arm64",
                "DEFINES_MODULE": "NO",
                "VALID_ARCHS": "arm64",
            ]
        )
        let new = BuildSettingsSnapshot(
            target: "SyntheticTarget",
            configuration: "Debug",
            settings: [
                "ARCHS": "arm64 x86_64",
                "DEFINES_MODULE": "YES",
            ]
        )
        let analyzer = BuildSettingsAnalyzer()
        let differences = analyzer.differences(old: [old], new: [new])
        let findings = analyzer.findings(
            for: differences,
            targetXcodeVersion: "17.0"
        )

        XCTAssertEqual(
            Set(differences.map(\.name)),
            ["ARCHS", "DEFINES_MODULE", "VALID_ARCHS"]
        )
        XCTAssertEqual(findings.count, 3)
        XCTAssertTrue(findings.allSatisfy { $0.migrationMessage == nil })
        XCTAssertTrue(findings.allSatisfy { $0.origin == .buildSettings })
    }

func testSDKIdentifiersRetainEverySupportedBuildContext() {
        let snapshots = [
            BuildSettingsSnapshot(
                settings: [
                    "SDKROOT": "/Synthetic/SDKs/MacOSX21.0.sdk",
                    "SUPPORTED_PLATFORMS":
                        "iphoneos iphonesimulator macosx",
                ]
            ),
        ]

        XCTAssertEqual(
            BuildSettingsAnalyzer().sdkIdentifiers(in: snapshots),
            ["iphoneos", "iphonesimulator", "macosx"]
        )
    }

func testEnvironmentInspectorSelectsMacOSSDKUnderExplicitDeveloperDirectory() {
        let selectedDeveloperDirectory = "/Synthetic/Xcode.app/Contents/Developer"
        let runner = StubProcessRunner { call in
            if call.arguments == ["-version"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("Xcode 1.0\nBuild version 1A1\n".utf8),
                    standardError: Data()
                )
            }
            if call.arguments == ["swift", "--version"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("Swift 1.0\n".utf8),
                    standardError: Data()
                )
            }
            if call.arguments == ["--sdk", "macosx", "--show-sdk-version"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("1.0\n".utf8),
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let environment = EnvironmentInspector(runner: runner).inspect(
            developerDirectory: selectedDeveloperDirectory
        )

        XCTAssertEqual(environment.sdkVersion, "1.0")
        XCTAssertTrue(
            runner.calls.allSatisfy {
                $0.environment["DEVELOPER_DIR"] == selectedDeveloperDirectory
            }
        )
    }

    func testDeploymentTargetDifferencesAreFilteredToSelectedSDKPlatform() {
        let old = [
            BuildSettingsSnapshot(
                target: "Synthetic",
                configuration: "Debug",
                settings: [
                    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                    "TVOS_DEPLOYMENT_TARGET": "17.0",
                    "WATCHOS_DEPLOYMENT_TARGET": "10.0",
                ]
            ),
        ]
        let new = [
            BuildSettingsSnapshot(
                target: "Synthetic",
                configuration: "Debug",
                settings: [
                    "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
                    "TVOS_DEPLOYMENT_TARGET": "18.0",
                    "WATCHOS_DEPLOYMENT_TARGET": "11.0",
                ]
            ),
        ]

        let differences = BuildSettingsAnalyzer().differences(
            old: old,
            new: new,
            selectedSDKIdentifiers: ["iphoneos"]
        )

        XCTAssertEqual(differences.map(\.name), ["IPHONEOS_DEPLOYMENT_TARGET"])
    }

    func testSDKAndDestinationMustDescribeOneCompatibleBuildContext() throws {
        XCTAssertNoThrow(
            try BuildContextSelectionValidator.validate(
                sdkIdentifiers: ["iphonesimulator"],
                destination: "generic/platform=iOS Simulator"
            )
        )
        XCTAssertThrowsError(
            try BuildContextSelectionValidator.validate(
                sdkIdentifiers: ["iphoneos"],
                destination: "generic/platform=iOS Simulator"
            )
        )
        XCTAssertThrowsError(
            try BuildContextSelectionValidator.validate(
                sdkIdentifiers: ["iphoneos", "macosx"],
                destination: "generic/platform=iOS"
            )
        )
    }
}
