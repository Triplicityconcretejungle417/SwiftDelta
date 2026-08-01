//===--- XcodeProjectBuilderTests.swift - SwiftDelta ------------------------------------------===//
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

final class XcodeProjectBuilderTests: XCTestCase {
func testXcodeProjectBuilderUsesIsolatedPathsNoSigningAndTextFallback() throws {
        let directory = try TestDirectory(name: "xcode-builder")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let project = try directory.makeDirectory("Project With 空格.xcodeproj")
        let runner = StubProcessRunner { call in
            if call.arguments.contains("-showBuildSettings") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(
                        """
                        [{"target":"SyntheticTarget","buildSettings":{"SWIFT_VERSION":"6.0"}}]
                        """.utf8
                    ),
                    standardError: Data()
                )
            }
            if call.executable == "/usr/bin/xcodebuild" {
                return ProcessResult(
                    exitStatus: 65,
                    standardOutput: Data(
                        "\(project.deletingLastPathComponent().path)/Sources/File.swift:3:2: error: synthetic build failure\n".utf8
                    ),
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = try XcodeProjectBuilder(runner: runner).build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "SyntheticTarget",
                timeout: 10
            ),
            cancellation: { false }
        )

        XCTAssertEqual(outcome.exitStatus, 65)
        XCTAssertEqual(outcome.diagnostics.first?.message, "synthetic build failure")
        XCTAssertEqual(outcome.diagnosticSource, .xcodebuildText)
        XCTAssertEqual(outcome.buildSettings.first?.settings["SWIFT_VERSION"], "6.0")
        let buildCall = try XCTUnwrap(
            runner.calls.first {
                $0.executable == "/usr/bin/xcodebuild" && $0.arguments.contains("build")
            }
        )
        XCTAssertTrue(buildCall.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertTrue(buildCall.arguments.contains("-disableAutomaticPackageResolution"))
        XCTAssertTrue(
            buildCall.arguments.contains(where: {
                $0.hasPrefix("CLANG_MODULE_CACHE_PATH=")
            })
        )
        XCTAssertTrue(
            buildCall.arguments.contains(where: {
                $0.hasPrefix("INDEX_DATA_STORE_DIR=")
            })
        )
        XCTAssertNotNil(buildCall.environment["HOME"])
        XCTAssertNotNil(buildCall.environment["TMPDIR"])
        XCTAssertNotNil(buildCall.environment["CLANG_MODULE_CACHE_PATH"])
        XCTAssertEqual(
            buildCall.environment["DEVELOPER_DIR"],
            xcode.appendingPathComponent("Contents/Developer").path
        )
        let derivedData = try argumentValue(
            after: "-derivedDataPath",
            in: buildCall.arguments
        )
        let resultBundle = try argumentValue(
            after: "-resultBundlePath",
            in: buildCall.arguments
        )
        let settingsCall = try XCTUnwrap(
            runner.calls.first {
                $0.arguments.contains("-showBuildSettings")
            }
        )
        XCTAssertEqual(
            try argumentValue(
                after: "-derivedDataPath",
                in: settingsCall.arguments
            ),
            derivedData
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedData))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultBundle))
    }

    func testStatus70ReportsMissingDestinationWithSelectedBuildContext() throws {
        let directory = try TestDirectory(name: "xcode-destination-failure")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild",
               call.arguments.contains("build")
            {
                return ProcessResult(
                    exitStatus: 70,
                    standardOutput: Data(),
                    standardError: Data(
                        """
                        xcodebuild: error: Unable to find a destination matching the provided destination specifier:
                        { generic:1, platform:iOS }
                        Ineligible destinations for the "Synthetic" scheme:
                        { platform:iOS, error:iOS 26.2 is not installed. }
                        """.utf8
                    )
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = try XcodeProjectBuilder(runner: runner).build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "Synthetic",
                destination: "generic/platform=iOS",
                timeout: 10,
                sdkIdentifiers: ["iphoneos"],
                xcodeIdentity: "Xcode 26.3 (17C529)"
            ),
            cancellation: { false }
        )

        let diagnostic = try XCTUnwrap(outcome.diagnostics.first)
        XCTAssertEqual(outcome.exitStatus, 70)
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertTrue(diagnostic.message.contains("Destination selection failed"))
        XCTAssertTrue(diagnostic.message.contains("Xcode 26.3 (17C529)"))
        XCTAssertTrue(diagnostic.message.contains("Synthetic.xcodeproj"))
        XCTAssertTrue(diagnostic.message.contains("scheme Synthetic"))
        XCTAssertTrue(diagnostic.message.contains("SDK iphoneos"))
        XCTAssertTrue(diagnostic.message.contains("generic/platform=iOS"))
        XCTAssertLessThan(diagnostic.message.count, 1_000)
    }

    func testMissingSDKFailureIsActionableAndConcise() throws {
        let directory = try TestDirectory(name: "xcode-missing-sdk")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild",
               call.arguments.contains("build")
            {
                return ProcessResult(
                    exitStatus: 70,
                    standardOutput: Data(),
                    standardError: Data(
                        "xcodebuild: error: SDK \"iphoneos\" cannot be located.\n".utf8
                    )
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = try XcodeProjectBuilder(runner: runner).build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "Synthetic",
                timeout: 10,
                sdkIdentifiers: ["iphoneos"],
                xcodeIdentity: "Xcode 26.3 (17C529)"
            ),
            cancellation: { false }
        )

        let diagnostic = try XCTUnwrap(outcome.diagnostics.first)
        XCTAssertTrue(diagnostic.message.contains("requested SDK is unavailable"))
        XCTAssertTrue(diagnostic.message.contains("iphoneos"))
        XCTAssertLessThan(diagnostic.message.count, 1_000)
    }
}
