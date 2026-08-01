//===--- SDKExtractionFailureTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKExtractionFailureTests: XCTestCase {
func testFailedCandidateModuleExtractionCannotAppearAsAPIRemoval() {
        let identity = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode.app",
            developerDirectory: "/Synthetic/Xcode.app/Contents/Developer",
            xcodeVersion: "1",
            xcodeBuild: "1A1",
            platform: "SyntheticOS",
            sdkIdentifier: "syntheticos",
            sdkVersion: "1",
            sdkPath: "/Synthetic/SDK.sdk"
        )
        let symbol = SDKSymbol(
            id: "usr.fictional.value",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.fictional.value",
            fullyQualifiedName: "FictionalSDK.Value",
            baseName: "Value",
            kind: "swift.struct"
        )
        let baseline = SDKSnapshot(
            identity: identity,
            modules: ["FictionalSDK"],
            symbols: [symbol],
            moduleExtractions: [
                SDKModuleExtraction(
                    moduleName: "FictionalSDK",
                    source: .symbolGraph,
                    symbolCount: 1
                ),
            ]
        )
        let candidate = SDKSnapshot(
            identity: identity,
            modules: ["FictionalSDK"],
            symbols: [],
            moduleExtractions: [
                SDKModuleExtraction(
                    moduleName: "FictionalSDK",
                    source: .failed,
                    symbolCount: 0,
                    detail: "synthetic extraction failure"
                ),
            ]
        )

        XCTAssertTrue(
            SDKSnapshotDiffer.compare(
                baseline: baseline,
                candidate: candidate
            ).isEmpty
        )
    }
}
