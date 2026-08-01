//===--- PackageAnalyzerTests.swift - SwiftDelta ------------------------------------------===//
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

final class PackageAnalyzerTests: XCTestCase {
func testPackageAnalyzerCollectsMetadataWithoutRuleFindings() throws {
        let directory = try TestDirectory(name: "package-metadata")
        let manifest = try directory.write(
            "Package.swift",
            packageManifest(
                toolsVersion: "6.0",
                platforms: ".macOS(.v13)",
                extraTargets: ",\n        .plugin(name: \"FictionalPlugin\", capability: .buildTool())"
            )
        )
        try directory.write(
            "Package.resolved",
            """
            {
              "pins": [
                {
                  "identity": "fictional-local-pin",
                  "kind": "localSourceControl",
                  "location": "/Synthetic/Dependency",
                  "state": {"revision": "0000000000000000000000000000000000000000"}
                }
              ],
              "version": 3
            }
            """
        )

        let result = try PackageAnalyzer().analyze(manifestURL: manifest)

        XCTAssertEqual(result.metadata.toolsVersion, "6.0")
        XCTAssertEqual(result.metadata.minimumPlatforms["macOS"], "13")
        XCTAssertTrue(result.metadata.resolvedFilePresent)
        XCTAssertEqual(result.metadata.resolvedDependencyCount, 1)
        XCTAssertEqual(result.metadata.pluginCount, 1)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testPackageAnalyzerDoesNotWriteGeneratedArtifactsIntoFixture() throws {
        let directory = try TestDirectory(name: "package-artifacts")
        let manifest = try directory.write("Package.swift", packageManifest())
        _ = try PackageAnalyzer().analyze(manifestURL: manifest)

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent).sorted(), ["Package.swift"])
    }
}
