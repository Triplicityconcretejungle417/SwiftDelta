//===--- RealSwiftPackageIntegrationTests.swift - SwiftDelta ------------------------------------------===//
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

final class RealSwiftPackageIntegrationTests: XCTestCase {
    func testRealTwoXcodePurePackageComparison() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-two-xcode-package")
        let plainManifest = try directory.write(
            "PlainPackage/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        try directory.write(
            "PlainPackage/Sources/SyntheticTarget/File.swift",
            "public struct SyntheticValue { public init() {} }\n"
        )
        let warningManifest = try directory.write(
            "WarningPackage/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        try directory.write(
            "WarningPackage/Sources/SyntheticTarget/File.swift",
            """
            #if compiler(>=6.4)
            #warning("synthetic candidate-only package diagnostic")
            #endif

            public struct SyntheticValue {
                public init() {}
            }
            """
        )
        let plainManifestBefore = try Data(contentsOf: plainManifest)
        let warningManifestBefore = try Data(contentsOf: warningManifest)
        let runner = RecordingProcessRunner()
        let comparator = BuildComparator(
            builder: XcodeProjectBuilder(runner: runner)
        )

        let plain = try comparator.compare(
            old: realPackageInvocation(
                xcode: toolchains.baseline,
                manifest: plainManifest
            ),
            new: realPackageInvocation(
                xcode: toolchains.candidate,
                manifest: plainManifest
            )
        )
        XCTAssertTrue(plain.oldBuild.succeeded)
        XCTAssertTrue(plain.newBuild.succeeded)
        XCTAssertTrue(plain.introducedDiagnostics.isEmpty)
        XCTAssertEqual(plain.oldBuild.diagnosticSource, .swiftBuildText)
        XCTAssertEqual(plain.newBuild.diagnosticSource, .swiftBuildText)

        let discovery = try ProjectDiscovery().discover(
            root: plainManifest.deletingLastPathComponent()
        )
        for (role, xcode) in [
            ("baseline", toolchains.baseline),
            ("candidate", toolchains.candidate),
        ] {
            let resolution = try TargetBuildContextProvider(
                runner: runner
            ).resolve(
                discovery: discovery,
                configuration: SwiftDeltaConfiguration(),
                xcodeApplicationPath: xcode,
                toolchainRole: role,
                sdkIdentifier: "macosx",
                buildConfiguration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            )
            let context = try XCTUnwrap(
                resolution.contexts.first {
                    $0.target == "SyntheticTarget"
                }
            )
            XCTAssertTrue(context.isAuthoritative)
            XCTAssertEqual(context.evidenceSource, .exactCompilerInvocation)
            XCTAssertFalse(context.capturedCompilerArguments.isEmpty)
            let references = try CompilerReferenceResolver(
                runner: runner
            ).resolve(
                CompilerReferenceRequest(
                    buildContext: context,
                    projectRoot: plainManifest.deletingLastPathComponent(),
                    timeoutPerFile: 300
                )
            )
            XCTAssertTrue(references.coverage.isComplete)
            XCTAssertEqual(references.coverage.filesRequested, 1)
            XCTAssertEqual(references.coverage.filesAnalyzed, 1)
        }

        let warning = try comparator.compare(
            old: realPackageInvocation(
                xcode: toolchains.baseline,
                manifest: warningManifest
            ),
            new: realPackageInvocation(
                xcode: toolchains.candidate,
                manifest: warningManifest
            )
        )
        XCTAssertTrue(warning.oldBuild.succeeded)
        XCTAssertTrue(warning.newBuild.succeeded)
        XCTAssertTrue(
            warning.introducedDiagnostics.contains {
                $0.message.contains("synthetic candidate-only package diagnostic")
            }
        )

        XCTAssertEqual(try Data(contentsOf: plainManifest), plainManifestBefore)
        XCTAssertEqual(try Data(contentsOf: warningManifest), warningManifestBefore)
        for manifest in [plainManifest, warningManifest] {
            let root = manifest.deletingLastPathComponent()
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Package.resolved").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(".build").path
                )
            )
        }

        let swiftBuildCalls = runner.calls.filter {
            $0.arguments.first == "build"
                && $0.executable.hasSuffix("/usr/bin/swift")
        }
        XCTAssertEqual(swiftBuildCalls.count, 6)
        XCTAssertEqual(Set(swiftBuildCalls.map(\.executable)).count, 2)
        for option in [
            "--scratch-path",
            "--cache-path",
            "--config-path",
            "--security-path",
        ] {
            try assertUniqueArgumentPaths(option, calls: swiftBuildCalls)
        }
        XCTAssertTrue(
            swiftBuildCalls.allSatisfy {
                $0.arguments.contains("--disable-automatic-resolution")
                    && $0.arguments.contains("--disable-prefetching")
                    && $0.arguments.contains("--skip-update")
            }
        )
    }
}
