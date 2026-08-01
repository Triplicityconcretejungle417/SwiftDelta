//===--- SDKTimeoutAndFallbackTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKTimeoutAndFallbackTests: XCTestCase {
    func testRequestedTimeoutReachesBaselineAndCandidateSymbolGraphExtraction() throws {
        let directory = try TestDirectory(name: "sdk-timeout-propagation")
        let baselineXcode = try makeSyntheticXcode(in: directory, name: "Baseline")
        let candidateXcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let sdk = try directory.makeDirectory("Fictional.sdk")
        let source = try directory.write(
            "Sources/Fixture.swift",
            "import FictionalSDK\nfunc exercise() { fictionalCall() }\n"
        )
        let ast = try compilerAST(path: source.path)
        let graph = symbolGraph()
        let runner = StubProcessRunner { call in
            switch call.executable {
            case "/usr/bin/xcodebuild":
                let candidate = call.environment["DEVELOPER_DIR"]?.contains("Candidate") == true
                let value = candidate
                    ? "Xcode 27.0\nBuild version 27A1\n"
                    : "Xcode 26.0\nBuild version 26A1\n"
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(value.utf8),
                    standardError: Data()
                )
            case "/usr/bin/xcrun":
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
            case "/Synthetic/swiftc":
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: ast,
                    standardError: Data()
                )
            case "/Synthetic/swift-symbolgraph-extract":
                let index = try XCTUnwrap(call.arguments.firstIndex(of: "-output-dir"))
                let output = URL(fileURLWithPath: call.arguments[index + 1])
                    .appendingPathComponent("FictionalSDK.symbols.json")
                try graph.write(to: output)
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            default:
                break
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }

        _ = try SDKAnalysisEngine(runner: runner).analyze(
            discovery: DiscoveryResult(
                root: directory.url.path,
                containers: [],
                swiftFiles: [source.path]
            ),
            configuration: SwiftDeltaConfiguration(
                baselineXcodePath: baselineXcode.path,
                candidateXcodePath: candidateXcode.path,
                sdkIdentifiers: ["macosx"]
            ),
            timeoutPerOperation: 1_800,
            sdkCachePolicy: .disabled
        )

        let extractions = runner.calls.filter {
            $0.executable == "/Synthetic/swift-symbolgraph-extract"
        }
        XCTAssertEqual(extractions.count, 2)
        XCTAssertEqual(extractions.map(\.timeout), [1_800, 1_800])
        XCTAssertEqual(
            Set(extractions.compactMap { $0.environment["DEVELOPER_DIR"] }),
            Set([
                baselineXcode.path + "/Contents/Developer",
                candidateXcode.path + "/Contents/Developer",
            ])
        )
    }

    func testSymbolGraphTimeoutUsesSwiftInterfaceFallbackAndRecordsContext() throws {
        let directory = try TestDirectory(name: "sdk-timeout-fallback")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let sdk = try directory.makeDirectory("Fictional.sdk")
        try directory.write(
            "Fictional.sdk/System/Library/Frameworks/FictionalSDK.framework/Modules/FictionalSDK.swiftmodule/arm64.swiftinterface",
            "public struct FallbackValue {}\n"
        )
        let runner = metadataRunner(
            sdk: sdk,
            extraction: {
                throw SwiftDeltaError.processTimedOut(
                    executable: "swift-symbolgraph-extract",
                    seconds: 1_800
                )
            }
        )
        let cache = try directory.makeDirectory("Cache")
        let request = SDKSnapshotRequest(
            xcodeApplicationPath: xcode.path,
            sdkIdentifier: "macosx",
            modules: ["FictionalSDK"],
            timeout: 1_800,
            cachePolicy: .use,
            cacheDirectory: cache
        )

        let snapshot = try SDKSnapshotExtractor(runner: runner).extract(
            request
        )
        _ = try SDKSnapshotExtractor(runner: runner).extract(request)

        XCTAssertEqual(snapshot.moduleExtractions.first?.source, .swiftInterface)
        XCTAssertTrue(snapshot.moduleExtractions.first?.succeeded == true)
        let warning = try XCTUnwrap(snapshot.extractionWarnings.first)
        XCTAssertTrue(warning.contains("module FictionalSDK"))
        XCTAssertTrue(warning.contains("SDK macosx 27.0"))
        XCTAssertTrue(warning.contains("Xcode 27.0 (27A1)"))
        XCTAssertTrue(warning.contains("effective timeout 1800.0 seconds"))
        XCTAssertEqual(
            runner.calls.count {
                $0.executable == "/Synthetic/swift-symbolgraph-extract"
            },
            2
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: cache,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.isEmpty
        )
        XCTAssertTrue(warning.contains("Swift-interface fallback was used"))
    }

    func testBothExtractionPathsFailWithoutCreatingRemovalEvidence() throws {
        let directory = try TestDirectory(name: "sdk-double-failure")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let sdk = try directory.makeDirectory("Fictional.sdk")
        let runner = metadataRunner(
            sdk: sdk,
            extraction: {
                throw SwiftDeltaError.processTimedOut(
                    executable: "swift-symbolgraph-extract",
                    seconds: 2
                )
            }
        )
        let failed = try SDKSnapshotExtractor(runner: runner).extract(
            SDKSnapshotRequest(
                xcodeApplicationPath: xcode.path,
                sdkIdentifier: "macosx",
                modules: ["FictionalSDK"],
                timeout: 2,
                cachePolicy: .disabled
            )
        )
        let symbol = makeSDKSymbol(
            "usr.fictional.removed",
            "Container.value()",
            declaration: "func value()"
        )
        let baseline = SDKSnapshot(
            identity: failed.identity,
            modules: ["FictionalSDK"],
            symbols: [symbol]
        )

        XCTAssertEqual(failed.moduleExtractions.first?.source, .failed)
        XCTAssertTrue(
            SDKSnapshotDiffer.compare(
                baseline: baseline,
                candidate: failed
            ).isEmpty
        )
    }

    private func metadataRunner(
        sdk: URL,
        extraction: @escaping @Sendable () throws -> ProcessResult
    ) -> StubProcessRunner {
        StubProcessRunner { call in
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
                if call.arguments == ["--find", "swift-symbolgraph-extract"] {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("/Synthetic/swift-symbolgraph-extract\n".utf8),
                        standardError: Data()
                    )
                }
            }
            if call.executable == "/Synthetic/swift-symbolgraph-extract" {
                return try extraction()
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }
    }

    private func compilerAST(path: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "_kind": "source_file",
                "filename": path,
                "items": [
                    [
                        "_kind": "import_decl",
                        "module_path": ["FictionalSDK"],
                    ],
                    [
                        "_kind": "declref_expr",
                        "range": ["start": 40, "end": 55],
                        "decl": ["decl_usr": "usr.fictional.call"],
                    ],
                ],
            ],
            options: [.sortedKeys]
        )
    }

    private func symbolGraph() -> Data {
        Data(
            """
            {
              "module": {"name": "FictionalSDK"},
              "symbols": [{
                "kind": {"identifier": "swift.func", "displayName": "Function"},
                "identifier": {"precise": "usr.fictional.call", "interfaceLanguage": "swift"},
                "pathComponents": ["fictionalCall()"],
                "names": {"title": "fictionalCall()"}
              }],
              "relationships": []
            }
            """.utf8
        )
    }
}
