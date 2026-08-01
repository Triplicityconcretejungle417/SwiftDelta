//===--- SDKSnapshotExtractorTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKSnapshotExtractorTests: XCTestCase {
func testSnapshotExtractorUsesSelectedToolchainAndTemporaryOutputs() throws {
        let directory = try TestDirectory(name: "snapshot-extractor")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode-Fictional")
        let sdkPath = try directory.makeDirectory("Fictional.sdk")
        let graph = Data(
            """
            {
              "module": {"name": "FictionalSDK"},
              "symbols": [
                {
                  "kind": {"identifier": "swift.struct", "displayName": "Structure"},
                  "identifier": {"precise": "usr.fictional.gizmo", "interfaceLanguage": "swift"},
                  "pathComponents": ["Gizmo"],
                  "names": {"title": "Gizmo"},
                  "declarationFragments": [
                    {"kind": "keyword", "spelling": "struct"},
                    {"kind": "text", "spelling": " Gizmo"}
                  ]
                }
              ],
              "relationships": []
            }
            """.utf8
        )
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild" {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("Xcode 17.0\nBuild version 17A200\n".utf8),
                    standardError: Data()
                )
            }
            if call.executable == "/usr/bin/xcrun" {
                if call.arguments.contains("--show-sdk-path") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data((sdkPath.path + "\n").utf8),
                        standardError: Data()
                    )
                }
                if call.arguments.contains("--show-sdk-version") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data("21.0\n".utf8),
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
                let index = try XCTUnwrap(call.arguments.firstIndex(of: "-output-dir"))
                let output = URL(fileURLWithPath: call.arguments[index + 1])
                    .appendingPathComponent("FictionalSDK.symbols.json")
                try graph.write(to: output)
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            }
            return ProcessResult(exitStatus: 1, standardOutput: Data(), standardError: Data())
        }
        let identity = SDKInstallationIdentity(
            xcodeApplicationPath: xcode.path,
            developerDirectory: xcode.path + "/Contents/Developer",
            xcodeVersion: "17.0",
            xcodeBuild: "17A200",
            platform: "macOS",
            sdkIdentifier: "macosx",
            sdkVersion: "21.0",
            sdkPath: sdkPath.path,
            swiftVersion: "Swift 6.4"
        )

        let measurements = SDKProgressMeasurementCapture()
        let progress = OperationProgress(
            measurementSink: measurements.append,
            sink: { _ in }
        )
        let snapshot = try SDKSnapshotExtractor(
            runner: runner,
            progress: progress
        ).extract(
            SDKSnapshotRequest(
                xcodeApplicationPath: xcode.path,
                sdkIdentifier: "macosx",
                modules: ["FictionalSDK"],
                cachePolicy: .disabled,
                installationIdentity: identity
            )
        )

        XCTAssertEqual(snapshot.identity.xcodeVersion, "17.0")
        XCTAssertEqual(snapshot.identity.xcodeBuild, "17A200")
        XCTAssertEqual(snapshot.identity.sdkVersion, "21.0")
        XCTAssertEqual(snapshot.symbols.first?.preciseIdentifier, "usr.fictional.gizmo")
        let extraction = try XCTUnwrap(
            runner.calls.first { $0.executable == "/Synthetic/swift-symbolgraph-extract" }
        )
        XCTAssertEqual(extraction.environment["DEVELOPER_DIR"], xcode.path + "/Contents/Developer")
        XCTAssertTrue(extraction.arguments.contains("-module-cache-path"))
        XCTAssertFalse(
            runner.calls.contains {
                $0.executable == "/usr/bin/xcodebuild"
                    || $0.arguments.contains("--show-sdk-path")
                    || $0.arguments.contains("--show-sdk-version")
            }
        )
        let outputIndex = try XCTUnwrap(extraction.arguments.firstIndex(of: "-output-dir"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extraction.arguments[outputIndex + 1])
        )
        XCTAssertTrue(
            measurements.values.contains(
                OperationProgressMeasurement(
                    completed: 0,
                    total: 1,
                    label: "SDK modules"
                )
            )
        )
        XCTAssertTrue(
            measurements.values.contains(
                OperationProgressMeasurement(
                    completed: 1,
                    total: 1,
                    label: "SDK modules"
                )
            )
        )
    }

func testInstalledToolchainRunsSnapshotAndReferencePipelineOnSyntheticSource() throws {
        let xcodePath = try selectedRealToolchains().candidate
        let xcode = URL(fileURLWithPath: xcodePath)
        _ = try XcodeInstallation.validate(applicationPath: xcode.path)

        let directory = try TestDirectory(name: "installed-sdk-smoke")
        try directory.write(
            "Sources/FictionalFixture.swift",
            """
            import Foundation

            public struct FictionalFixture {
                public init() {}
            }
            """
        )
        let cacheDirectory = try directory.makeDirectory("SDKCache")
        let runner = SDKInvocationCountingRunner()
        let extractor = SDKSnapshotExtractor(runner: runner)
        let request = SDKSnapshotRequest(
            xcodeApplicationPath: xcode.path,
            sdkIdentifier: "macosx",
            modules: ["Foundation"],
            timeout: 180,
            cachePolicy: .use,
            cacheDirectory: cacheDirectory
        )
        let coldStart = Date()
        let snapshot = try extractor.extract(request)
        let coldDuration = Date().timeIntervalSince(coldStart)
        let extractionCountAfterColdScan = runner.symbolGraphExtractionInvocations
        let warmStart = Date()
        let warmSnapshot = try extractor.extract(request)
        let warmDuration = Date().timeIntervalSince(warmStart)

        XCTAssertEqual(snapshot.identity.xcodeBuild, warmSnapshot.identity.xcodeBuild)
        XCTAssertEqual(snapshot.symbols, warmSnapshot.symbols)
        XCTAssertTrue(snapshot.successfullyExtractedModules.contains("Foundation"))
        XCTAssertGreaterThan(extractionCountAfterColdScan, 0)
        XCTAssertEqual(
            runner.symbolGraphExtractionInvocations,
            extractionCountAfterColdScan,
            "The warm scan must reuse valid cached SDK evidence."
        )
        print(
            "SDK_CACHE_BENCHMARK cold=\(coldDuration) warm=\(warmDuration)"
        )
    }
}

private final class SDKProgressMeasurementCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OperationProgressMeasurement] = []

    var values: [OperationProgressMeasurement] {
        lock.withLock { storage }
    }

    func append(_ value: OperationProgressMeasurement?) {
        guard let value else { return }
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class SDKInvocationCountingRunner:
    ProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let underlying = ProcessRunner()
    private var referenceInvocations = 0
    private var symbolGraphInvocations = 0

    var referenceResolutionInvocations: Int {
        lock.withLock { referenceInvocations }
    }

    var symbolGraphExtractionInvocations: Int {
        lock.withLock { symbolGraphInvocations }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        if arguments.contains("-dump-ast-format") {
            lock.withLock {
                referenceInvocations += 1
            }
        }
        if executable.contains("swift-symbolgraph-extract") {
            lock.withLock {
                symbolGraphInvocations += 1
            }
        }
        return try underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: cancellation
        )
    }
}
