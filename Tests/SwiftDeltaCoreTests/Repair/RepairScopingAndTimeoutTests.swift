//===--- RepairScopingAndTimeoutTests.swift - SwiftDelta ------------------------------------------===//
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

final class RepairScopingAndTimeoutTests: XCTestCase {
    func testSelectedFileScopesReferenceAndSDKWorkAndPreservesRequestedTimeout() throws {
        let directory = try TestDirectory(name: "repair-file-scope")
        let baseline = try makeSyntheticXcode(in: directory, name: "Baseline")
        let candidate = try makeSyntheticXcode(in: directory, name: "Candidate")
        let frontend = try directory.write(
            "Candidate.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            "#!/bin/sh\nexit 0\n"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: frontend.path
        )
        let sdk = try directory.makeDirectory("Fictional.sdk")
        let selected = try directory.write(
            "Sources/Selected.swift",
            "import FictionalSDK\nfunc selected() { fictionalCall() }\n"
        )
        let unrelated = try directory.write(
            "Sources/Unrelated.swift",
            "import UnrelatedSDK\nfunc unrelated() { unrelatedCall() }\n"
        )
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild" {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("Xcode 27.0\nBuild version 27A1\n".utf8),
                    standardError: Data()
                )
            }
            if call.executable == "/usr/bin/xcrun" {
                if call.arguments.contains("--show-sdk-path") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data((sdk.path + "\n").utf8),
                        standardError: Data()
                    )
                }
                if call.arguments.contains("--show-sdk-version") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("27.0\n".utf8),
                        standardError: Data()
                    )
                }
                if call.arguments == ["swift", "--version"] {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("Swift 6.4\n".utf8),
                        standardError: Data()
                    )
                }
                if call.arguments == ["--find", "swiftc"] {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("/Synthetic/swiftc\n".utf8),
                        standardError: Data()
                    )
                }
                if call.arguments == ["--find", "swift-symbolgraph-extract"] {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("/Synthetic/swift-symbolgraph-extract\n".utf8),
                        standardError: Data()
                    )
                }
            }
            if call.executable == "/Synthetic/swiftc" {
                var ast = Data()
                for (sourcePath, module, usr) in [
                    (selected.path, "FictionalSDK", "usr.fictional.call"),
                    (unrelated.path, "UnrelatedSDK", "usr.unrelated.call"),
                ] where call.arguments.contains(sourcePath) {
                    ast.append(
                        try JSONSerialization.data(
                            withJSONObject: [
                                "_kind": "source_file",
                                "filename": sourcePath,
                                "items": [
                                    [
                                        "_kind": "import_decl",
                                        "module_path": [module],
                                    ],
                                    [
                                        "_kind": "declref_expr",
                                        "range": ["start": 39, "end": 53],
                                        "decl": ["decl_usr": usr],
                                    ],
                                ],
                            ],
                            options: [.sortedKeys]
                        )
                    )
                    ast.append(0x0A)
                }
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: ast,
                    standardError: Data()
                )
            }
            if call.executable == "/Synthetic/swift-symbolgraph-extract" {
                let moduleIndex = try XCTUnwrap(
                    call.arguments.firstIndex(of: "-module-name")
                )
                let module = call.arguments[moduleIndex + 1]
                let outputIndex = try XCTUnwrap(
                    call.arguments.firstIndex(of: "-output-dir")
                )
                let output = URL(fileURLWithPath: call.arguments[outputIndex + 1])
                    .appendingPathComponent("\(module).symbols.json")
                try Data(
                    """
                    {
                      "module": {"name": "\(module)"},
                      "symbols": [{
                        "kind": {"identifier": "swift.func"},
                        "identifier": {"precise": "\(module).call"},
                        "pathComponents": ["call()"],
                        "names": {"title": "call()"}
                      }],
                      "relationships": []
                    }
                    """.utf8
                ).write(to: output)
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            if call.executable == frontend.path {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        _ = try RepairPlanningEngine(runner: runner).plan(
            RepairPlanningRequest(
                root: directory.url,
                configuration: SwiftDeltaConfiguration(
                    baselineXcodePath: baseline.path,
                    candidateXcodePath: candidate.path,
                    sdkIdentifiers: ["macosx"]
                ),
                selectedSourcePaths: ["Sources/Selected.swift"],
                timeoutPerFile: 1_800,
                sdkCachePolicy: .disabled
            )
        )

        let compilerReferenceCalls = runner.calls.filter {
            $0.executable == "/Synthetic/swiftc"
        }
        XCTAssertEqual(compilerReferenceCalls.count, 2)
        XCTAssertTrue(
            compilerReferenceCalls.allSatisfy {
                $0.arguments.contains(selected.path)
                    && !$0.arguments.contains(unrelated.path)
            }
        )

        let extractionCalls = runner.calls.filter {
            $0.executable == "/Synthetic/swift-symbolgraph-extract"
        }
        XCTAssertEqual(extractionCalls.count, 2)
        XCTAssertEqual(extractionCalls.map(\.timeout), [1_800, 1_800])
        XCTAssertTrue(
            extractionCalls.allSatisfy {
                $0.arguments.contains("FictionalSDK")
                    && !$0.arguments.contains("UnrelatedSDK")
            }
        )
        let fixItCall = try XCTUnwrap(
            runner.calls.first { $0.executable == frontend.path }
        )
        XCTAssertTrue(fixItCall.arguments.contains(selected.path))
        XCTAssertFalse(fixItCall.arguments.contains(unrelated.path))
        XCTAssertEqual(fixItCall.timeout, 1_800)

        let callCountBeforeFullAnalysis = runner.calls.count
        _ = try RepairPlanningEngine(runner: runner).plan(
            RepairPlanningRequest(
                root: directory.url,
                configuration: SwiftDeltaConfiguration(
                    baselineXcodePath: baseline.path,
                    candidateXcodePath: candidate.path,
                    sdkIdentifiers: ["macosx"]
                ),
                timeoutPerFile: 1_800,
                sdkCachePolicy: .disabled
            )
        )
        let fullAnalysisCalls = Array(runner.calls.dropFirst(callCountBeforeFullAnalysis))
        XCTAssertEqual(
            fullAnalysisCalls.filter { $0.executable == "/Synthetic/swiftc" }.count,
            2
        )
        XCTAssertEqual(
            fullAnalysisCalls.filter {
                $0.executable == "/Synthetic/swift-symbolgraph-extract"
            }.count,
            4
        )
        XCTAssertEqual(
            fullAnalysisCalls.filter { $0.executable == frontend.path }.count,
            1,
            "Fix-it evidence is produced only by the candidate compiler."
        )
    }
}
