//===--- SwiftPackageBuilderTests.swift - SwiftDelta ------------------------------------------===//
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

final class SwiftPackageBuilderTests: XCTestCase {
func testPureSwiftPackageBuildUsesSelectedToolchainAndFullyIsolatedOfflinePaths() throws {
        let directory = try TestDirectory(name: "package-builder")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let manifest = try directory.write(
            "SyntheticPackage/Package.swift",
            packageManifest()
        )
        try directory.write(
            "SyntheticPackage/Sources/SyntheticTarget/File.swift",
            "public struct FictionalValue {}\n"
        )
        let runner = StubProcessRunner { call in
            ProcessResult(
                exitStatus: 0,
                standardOutput: Data(
                    "\(manifest.deletingLastPathComponent().path)/Sources/SyntheticTarget/File.swift:1:1: warning: synthetic warning\n".utf8
                ),
                standardError: Data()
            )
        }

        let outcome = try XcodeProjectBuilder(runner: runner).build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .package, path: manifest.path),
                configuration: "Release",
                timeout: 10
            ),
            cancellation: { false }
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.diagnostics.first?.message, "synthetic warning")
        XCTAssertEqual(outcome.diagnosticSource, .swiftBuildText)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(
            call.executable,
            xcode.appendingPathComponent(
                "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            ).path
        )
        XCTAssertEqual(call.environment["DEVELOPER_DIR"], xcode.path + "/Contents/Developer")
        XCTAssertTrue(call.arguments.contains("--disable-automatic-resolution"))
        XCTAssertTrue(call.arguments.contains("--disable-experimental-prebuilts"))
        XCTAssertTrue(call.arguments.contains("--disable-prefetching"))
        XCTAssertTrue(call.arguments.contains("--skip-update"))
        XCTAssertEqual(
            try argumentValue(after: "--configuration", in: call.arguments),
            "release"
        )
        for option in [
            "--scratch-path",
            "--cache-path",
            "--config-path",
            "--security-path",
        ] {
            let path = try argumentValue(after: option, in: call.arguments)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(path.hasPrefix(manifest.deletingLastPathComponent().path))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: manifest.deletingLastPathComponent()
                    .appendingPathComponent(".build").path
            )
        )
    }

func testPurePackageStopsWithExactOfflineDependencyBlocker() throws {
        let directory = try TestDirectory(name: "offline-blocker")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let manifest = try directory.write("SyntheticPackage/Package.swift", packageManifest())
        try directory.write(
            "SyntheticPackage/Package.resolved",
            """
            {
              "pins": [
                {
                  "identity": "fictional-dependency-that-is-not-cached",
                  "kind": "remoteSourceControl",
                  "location": "https://invalid.example/fictional.git",
                  "state": {"revision": "0000000000000000000000000000000000000000"}
                }
              ],
              "version": 3
            }
            """
        )
        let runner = StubProcessRunner()

        XCTAssertThrowsError(
            try XcodeProjectBuilder(runner: runner).build(
                BuildInvocation(
                    xcodePath: xcode.path,
                    container: ProjectContainer(kind: .package, path: manifest.path),
                    timeout: 10
                ),
                cancellation: { false }
            )
        ) { error in
            guard case let SwiftDeltaError.offlineDependencyUnavailable(message) = error else {
                return XCTFail("Expected offline dependency blocker, received \(error)")
            }
            XCTAssertTrue(message.contains("fictional-dependency-that-is-not-cached"))
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNonMacPackageBuildUsesSelectedSDKAndManifestDeploymentTarget()
        throws
    {
        let directory = try TestDirectory(name: "package-ios-context")
        let xcode = try makeSyntheticXcode(in: directory, name: "Xcode")
        let manifest = try directory.write(
            "SyntheticPackage/Package.swift",
            packageManifest(platforms: ".iOS(.v17)")
        )
        try directory.write(
            "SyntheticPackage/Sources/SyntheticTarget/File.swift",
            "public struct FictionalValue {}\n"
        )
        let sdk = try directory.makeDirectory("iPhoneSimulator27.0.sdk")
        let swift = xcode.appendingPathComponent(
            "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        ).path
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild",
               call.arguments == ["-version"]
            {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(
                        "Xcode 27.0\nBuild version 27A1\n".utf8
                    ),
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
            }
            if call.executable == swift,
               call.arguments.contains("describe")
            {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(
                        """
                        {
                          "platforms": [
                            {"name": "ios", "version": "17.0"}
                          ],
                          "targets": []
                        }
                        """.utf8
                    ),
                    standardError: Data()
                )
            }
            if call.executable == swift,
               call.arguments.first == "build"
            {
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

        let outcome = try XcodeProjectBuilder(runner: runner).build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(
                    kind: .package,
                    path: manifest.path
                ),
                configuration: "Debug",
                destination: "generic/platform=iOS Simulator",
                timeout: 60,
                sdkIdentifiers: ["iphonesimulator"]
            ),
            cancellation: { false }
        )

        XCTAssertTrue(outcome.succeeded)
        let build = try XCTUnwrap(
            runner.calls.first {
                $0.executable == swift && $0.arguments.first == "build"
            }
        )
        XCTAssertEqual(
            try argumentValue(after: "--sdk", in: build.arguments),
            sdk.path
        )
        XCTAssertEqual(
            try argumentValue(after: "--triple", in: build.arguments),
            "arm64-apple-ios17.0-simulator"
        )
        XCTAssertEqual(
            build.environment["DEVELOPER_DIR"],
            xcode.path + "/Contents/Developer"
        )
    }

func testInstalledToolchainBuildsSyntheticPurePackageOffline() throws {
        let xcodePath = try selectedRealToolchains().candidate
        let xcode = URL(fileURLWithPath: xcodePath)
        _ = try XcodeInstallation.validate(applicationPath: xcode.path)

        let directory = try TestDirectory(name: "installed-package-smoke")
        let manifest = try directory.write(
            "Package.swift",
            packageManifest(platforms: ".macOS(.v13)")
        )
        try directory.write(
            "Sources/SyntheticTarget/File.swift",
            "public struct FictionalPackageValue { public init() {} }\n"
        )
        let outcome = try XcodeProjectBuilder().build(
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .package, path: manifest.path),
                configuration: "Debug",
                timeout: 120
            ),
            cancellation: { false }
        )
        if !outcome.succeeded,
           outcome.diagnostics.contains(where: {
               $0.message.contains("sandbox_apply: Operation not permitted")
           })
        {
            throw XCTSkip("The enclosing test sandbox does not permit SwiftPM's nested manifest sandbox")
        }

        XCTAssertTrue(
            outcome.succeeded,
            outcome.diagnostics.map(\.message).joined(separator: "\n")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.url.appendingPathComponent(".build").path
            )
        )
    }

}
