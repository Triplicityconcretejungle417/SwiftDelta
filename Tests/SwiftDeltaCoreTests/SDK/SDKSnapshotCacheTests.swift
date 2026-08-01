//===--- SDKSnapshotCacheTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDeltaCore
import XCTest

final class SDKSnapshotCacheTests: XCTestCase {
    func testCacheHitMissRefreshDisabledAndIdentityInvalidation() throws {
        let directory = try TestDirectory(name: "sdk-cache-policy")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode-Fictional")
        let sdk = try directory.makeDirectory("Fictional.sdk")
        let cache = try directory.makeDirectory("Cache")
        let graph = symbolGraph(module: "FictionalSDK", identifier: "usr.cache.value")
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild" {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("Xcode 27.0\nBuild version 27A100\n".utf8),
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
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        let extractor = SDKSnapshotExtractor(runner: runner)
        func request(_ policy: SDKSnapshotCachePolicy) -> SDKSnapshotRequest {
            SDKSnapshotRequest(
                xcodeApplicationPath: xcode.path,
                sdkIdentifier: "macosx",
                modules: ["FictionalSDK"],
                cachePolicy: policy,
                cacheDirectory: cache
            )
        }

        _ = try extractor.extract(request(.use))
        _ = try extractor.extract(request(.use))
        XCTAssertEqual(extractionCount(runner), 1)

        _ = try extractor.extract(request(.refresh))
        XCTAssertEqual(extractionCount(runner), 2)

        _ = try extractor.extract(request(.disabled))
        _ = try extractor.extract(request(.disabled))
        XCTAssertEqual(extractionCount(runner), 4)

        let entries = try cacheEntries(in: cache)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: entries[0])
            ) is [String: Any]
        )
    }

    func testCorruptEntryIsRejectedAndReplaced() throws {
        let directory = try TestDirectory(name: "sdk-cache-corruption")
        let root = try directory.makeDirectory("Cache")
        let cache = SDKSnapshotCache(root: root)
        let identity = cacheIdentity()
        let module = cachedModule()

        cache.write(module, identity: identity)
        let entry = try XCTUnwrap(cacheEntries(in: root).first)
        try Data("{corrupt".utf8).write(to: entry)

        XCTAssertNil(cache.read(identity: identity))
        cache.write(module, identity: identity)
        XCTAssertEqual(cache.read(identity: identity)?.symbols, module.symbols)
    }

    func testFailedOrIncompleteExtractionIsNeverCached() throws {
        let directory = try TestDirectory(name: "sdk-cache-failed")
        let root = try directory.makeDirectory("Cache")
        let cache = SDKSnapshotCache(root: root)
        let identity = cacheIdentity()
        cache.write(
            CachedSDKModule(
                symbols: [],
                extraction: SDKModuleExtraction(
                    moduleName: "FictionalSDK",
                    source: .failed,
                    symbolCount: 0,
                    detail: "synthetic extraction failure"
                )
            ),
            identity: identity
        )

        XCTAssertNil(cache.read(identity: identity))
        XCTAssertTrue(try cacheEntries(in: root).isEmpty)
    }

    func testConcurrentWritersLeaveOneValidatedCompleteEntry() throws {
        let directory = try TestDirectory(name: "sdk-cache-concurrency")
        let root = try directory.makeDirectory("Cache")
        let cache = SDKSnapshotCache(root: root)
        let identity = cacheIdentity()
        let module = cachedModule()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "org.swiftdelta.tests.cache",
            attributes: .concurrent
        )

        for _ in 0..<12 {
            group.enter()
            queue.async {
                cache.write(module, identity: identity)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try cacheEntries(in: root).count, 1)
        XCTAssertEqual(cache.read(identity: identity)?.symbols, module.symbols)
    }

    func testEveryEvidenceIdentityComponentChangesTheCacheKey() throws {
        let directory = try TestDirectory(name: "sdk-cache-identity")
        let cache = SDKSnapshotCache(root: try directory.makeDirectory("Cache"))
        let module = cachedModule()
        let original = cacheIdentity()
        cache.write(module, identity: original)

        let changed = SDKSnapshotCacheIdentity(
            installation: SDKInstallationIdentity(
                xcodeApplicationPath: "/Synthetic/Other.app",
                developerDirectory: "/Synthetic/Other.app/Contents/Developer",
                xcodeVersion: "27.0",
                xcodeBuild: "27A101",
                platform: "macOS",
                sdkIdentifier: "macosx",
                sdkVersion: "27.0",
                sdkPath: "/Synthetic/Other.sdk",
                swiftVersion: "Swift 6.4.1"
            ),
            targetTriple: "arm64-apple-macosx27.0",
            moduleName: "FictionalSDK",
            extractionOptions: ["-skip-inherited-docs"],
            minimumAccessLevel: "public",
            requestedExtractionMode: SDKModuleExtractionSource.symbolGraph.rawValue
        )

        XCTAssertNotEqual(original, changed)
        XCTAssertNil(cache.read(identity: changed))
    }

    func testCacheManagementReportsPrunesAndClearsOnlyOwnedEntries() throws {
        let directory = try TestDirectory(name: "sdk-cache-management")
        let root = try directory.makeDirectory("Cache")
        let cache = SDKSnapshotCache(root: root)
        let first = cacheIdentity()
        let second = SDKSnapshotCacheIdentity(
            installation: SDKInstallationIdentity(
                xcodeApplicationPath: "/Synthetic/Xcode.app",
                developerDirectory: "/Synthetic/Xcode.app/Contents/Developer",
                xcodeVersion: "27.0",
                xcodeBuild: "27A100",
                platform: "macOS",
                sdkIdentifier: "macosx",
                sdkVersion: "27.0",
                sdkPath: "/Synthetic/MacOSX.sdk",
                swiftVersion: "Swift 6.4"
            ),
            targetTriple: "x86_64-apple-macosx27.0",
            moduleName: "FictionalSDK",
            extractionOptions: ["-skip-inherited-docs"],
            minimumAccessLevel: "public",
            requestedExtractionMode: SDKModuleExtractionSource.symbolGraph.rawValue
        )
        cache.write(cachedModule(), identity: first)
        cache.write(cachedModule(), identity: second)
        let entries = try cacheEntries(in: root).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        XCTAssertEqual(entries.count, 2)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: entries[0].path
        )
        let unrelated = try directory.write("Cache/unrelated.txt", "keep\n")
        let manager = SDKCacheManager(root: root)

        let initial = try manager.status()
        XCTAssertEqual(initial.entryCount, 2)
        XCTAssertEqual(initial.invalidEntryCount, 0)
        XCTAssertGreaterThan(initial.byteCount, 0)

        let pruned = try manager.prune(
            maximumAge: 100,
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(pruned.removedEntries, 1)
        XCTAssertEqual(pruned.remainingEntries, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        try Data("{corrupt".utf8).write(
            to: root.appendingPathComponent("corrupt.json")
        )
        XCTAssertEqual(try manager.status().invalidEntryCount, 1)
        let invalidPrune = try manager.prune()
        XCTAssertEqual(invalidPrune.removedEntries, 1)

        let cleared = try manager.clear()
        XCTAssertEqual(cleared.removedEntries, 1)
        XCTAssertEqual(try manager.status().entryCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func extractionCount(_ runner: StubProcessRunner) -> Int {
        runner.calls.count {
            $0.executable == "/Synthetic/swift-symbolgraph-extract"
        }
    }

    private func cacheEntries(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func cacheIdentity() -> SDKSnapshotCacheIdentity {
        SDKSnapshotCacheIdentity(
            installation: SDKInstallationIdentity(
                xcodeApplicationPath: "/Synthetic/Xcode.app",
                developerDirectory: "/Synthetic/Xcode.app/Contents/Developer",
                xcodeVersion: "27.0",
                xcodeBuild: "27A100",
                platform: "macOS",
                sdkIdentifier: "macosx",
                sdkVersion: "27.0",
                sdkPath: "/Synthetic/MacOSX.sdk",
                swiftVersion: "Swift 6.4"
            ),
            targetTriple: "arm64-apple-macosx27.0",
            moduleName: "FictionalSDK",
            extractionOptions: ["-skip-inherited-docs"],
            minimumAccessLevel: "public",
            requestedExtractionMode: SDKModuleExtractionSource.symbolGraph.rawValue
        )
    }

    private func cachedModule() -> CachedSDKModule {
        let symbol = makeSDKSymbol(
            "usr.cache.value",
            "Container.value()",
            declaration: "func value()"
        )
        return CachedSDKModule(
            symbols: [symbol],
            extraction: SDKModuleExtraction(
                moduleName: "FictionalSDK",
                source: .symbolGraph,
                symbolCount: 1
            )
        )
    }

    private func symbolGraph(
        module: String,
        identifier: String
    ) -> Data {
        Data(
            """
            {
              "module": {"name": "\(module)"},
              "symbols": [{
                "kind": {"identifier": "swift.func"},
                "identifier": {"precise": "\(identifier)"},
                "pathComponents": ["Container", "value()"],
                "names": {"title": "value()"}
              }],
              "relationships": []
            }
            """.utf8
        )
    }
}
