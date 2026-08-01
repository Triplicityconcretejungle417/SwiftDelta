//===--- XCResultReaderTests.swift - SwiftDelta ------------------------------------------===//
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

final class XCResultReaderTests: XCTestCase {
func testModernStructuredXCResultOutputIsPreferredAndDeduplicated() throws {
        let directory = try TestDirectory(name: "xcresult-modern")
        let bundle = try directory.makeDirectory("Build.xcresult")
        let payload = Data(
            """
            {
              "issues": [
                {
                  "issueType": "Swift Compiler Warning",
                  "message": "synthetic warning",
                  "sourceURL": "file:///Synthetic/File.swift#StartingLineNumber=4&StartingColumnNumber=2",
                  "targetName": "SyntheticTarget"
                },
                {
                  "issueType": "Swift Compiler Warning",
                  "message": "synthetic warning",
                  "sourceURL": "file:///Synthetic/File.swift#StartingLineNumber=4&StartingColumnNumber=2",
                  "targetName": "SyntheticTarget"
                }
              ]
            }
            """.utf8
        )
        let runner = StubProcessRunner { call in
            if call.arguments == ["xcresulttool", "help", "get", "build-results"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("USAGE: xcresulttool get build-results".utf8),
                    standardError: Data()
                )
            }
            if call.arguments.contains("build-results") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: payload,
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = XCResultReader(runner: runner).read(
            bundleURL: bundle,
            developerDirectory: "/Synthetic/Xcode.app/Contents/Developer"
        )

        let diagnostics = outcome.diagnostics
        XCTAssertEqual(outcome.strategy, .modernStructured)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].message, "synthetic warning")
        XCTAssertEqual(diagnostics[0].target, "SyntheticTarget")
        XCTAssertTrue(runner.calls.contains { $0.arguments.contains("build-results") })
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--legacy") })
    }

func testLegacyStructuredXCResultOutputIsUsedWhenModernCommandIsUnsupported() throws {
        let directory = try TestDirectory(name: "xcresult-legacy")
        let bundle = try directory.makeDirectory("Build.xcresult")
        let payload = Data(
            """
            {
              "issues": {
                "_values": [
                  {
                    "issueType": {"_value": "Swift Compiler Error"},
                    "message": {"_value": "legacy synthetic error"},
                    "documentLocationInCreatingWorkspace": {
                      "url": {
                        "_value": "file:///Synthetic/Legacy.swift#StartingLineNumber=8&StartingColumnNumber=3"
                      }
                    }
                  }
                ]
              }
            }
            """.utf8
        )
        let runner = StubProcessRunner { call in
            if call.arguments == ["xcresulttool", "help", "get", "build-results"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("SUBCOMMANDS: object".utf8),
                    standardError: Data()
                )
            }
            if call.arguments.contains("object") && call.arguments.contains("--legacy") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: payload,
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = XCResultReader(runner: runner).read(
            bundleURL: bundle,
            developerDirectory: "/Synthetic/Xcode.app/Contents/Developer"
        )

        let diagnostics = outcome.diagnostics
        XCTAssertEqual(outcome.strategy, .legacyStructured)
        XCTAssertEqual(diagnostics.first?.message, "legacy synthetic error")
        XCTAssertEqual(diagnostics.first?.location?.line, 8)
        XCTAssertFalse(
            runner.calls.contains {
                $0.arguments.starts(
                    with: ["xcresulttool", "get", "build-results"]
                )
            }
        )
        XCTAssertTrue(runner.calls.contains { $0.arguments.contains("--legacy") })
    }

func testMissingAndMalformedResultBundlesReturnNoStructuredDiagnostics() throws {
        let directory = try TestDirectory(name: "xcresult-malformed")
        let missing = directory.url.appendingPathComponent("Missing.xcresult")
        let runner = StubProcessRunner { call in
            if call.arguments == ["xcresulttool", "help", "get", "build-results"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("build-results".utf8),
                    standardError: Data()
                )
            }
            return ProcessResult(
                exitStatus: 0,
                standardOutput: Data("{malformed".utf8),
                standardError: Data()
            )
        }
        let reader = XCResultReader(runner: runner)

        XCTAssertTrue(
            reader.readDiagnostics(
                bundleURL: missing,
                developerDirectory: "/Synthetic/Xcode.app/Contents/Developer"
            ).isEmpty
        )
        XCTAssertTrue(runner.calls.isEmpty)

        let malformed = try directory.makeDirectory("Malformed.xcresult")
        XCTAssertTrue(
            reader.readDiagnostics(
                bundleURL: malformed,
                developerDirectory: "/Synthetic/Xcode.app/Contents/Developer"
            ).isEmpty
        )
    }

func testValidEmptyModernOutputDoesNotFallThroughAndUsesSelectedDeveloperDirectory() throws {
        let directory = try TestDirectory(name: "xcresult-empty-modern")
        let bundle = try directory.makeDirectory("Build.xcresult")
        let selectedDeveloperDirectory = "/Synthetic/Selected.app/Contents/Developer"
        let runner = StubProcessRunner { call in
            if call.arguments == ["xcresulttool", "help", "get", "build-results"] {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(
                        "USAGE: xcresulttool get build-results".utf8
                    ),
                    standardError: Data()
                )
            }
            if call.arguments.contains("build-results") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(#"{"issues":[]}"#.utf8),
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        let outcome = XCResultReader(runner: runner).read(
            bundleURL: bundle,
            developerDirectory: selectedDeveloperDirectory
        )

        XCTAssertEqual(outcome.strategy, .modernStructured)
        XCTAssertTrue(outcome.diagnostics.isEmpty)
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--legacy") })
        XCTAssertTrue(
            runner.calls.allSatisfy {
                $0.environment["DEVELOPER_DIR"] == selectedDeveloperDirectory
            }
        )
    }

    func testStructuredSchemasPreserveExplicitSeverityWithoutMessageInference()
        throws
    {
        let data = Data(
            """
            {
              "issues": [
                {"severity": "error", "issueType": "Swift Compiler", "message": "one"},
                {"severity": "warning", "issueType": "Swift Compiler", "message": "two"},
                {"severity": "note", "issueType": "Swift Compiler", "message": "three"},
                {"severity": "remark", "issueType": "Swift Compiler", "message": "four"},
                {"issueType": "Unknown Structured Category", "message": "five"}
              ]
            }
            """.utf8
        )

        let diagnostics = try XCResultDiagnosticParser.parse(data)
        let severities = Dictionary(uniqueKeysWithValues: diagnostics.map {
            ($0.message, $0.severity)
        })
        XCTAssertEqual(severities["one"], .error)
        XCTAssertEqual(severities["two"], .warning)
        XCTAssertEqual(severities["three"], .notice)
        XCTAssertEqual(severities["four"], .notice)
        XCTAssertEqual(severities["five"], .notice)
    }

    func testStructuredLeafInheritsSeverityFromIssueCollection() throws {
        let diagnostics = try XCResultDiagnosticParser.parse(
            Data(
                """
                {
                  "issues": {
                    "warningIssues": [
                      {
                        "issueType": "Swift Compiler Diagnostic",
                        "message": "synthetic deprecation"
                      }
                    ],
                    "errorIssues": [
                      {
                        "issueType": "Swift Compiler Diagnostic",
                        "message": "synthetic failure"
                      }
                    ]
                  }
                }
                """.utf8
            )
        )

        let severities = Dictionary(
            uniqueKeysWithValues: diagnostics.map { ($0.message, $0.severity) }
        )
        XCTAssertEqual(severities["synthetic deprecation"], .warning)
        XCTAssertEqual(severities["synthetic failure"], .error)
    }
}
