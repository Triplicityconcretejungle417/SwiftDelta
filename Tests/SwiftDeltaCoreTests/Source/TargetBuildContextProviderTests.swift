//===--- TargetBuildContextProviderTests.swift - SwiftDelta ------------------------------------------===//
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

final class TargetBuildContextProviderTests: XCTestCase {
    func testSameNamedTargetsInDifferentProjectsHaveDistinctContextIdentities() {
        func context(project: String) -> TargetBuildContext {
            TargetBuildContext(
                toolchainRole: "candidate",
                xcodeApplicationPath: "/Synthetic/Xcode.app",
                sdkIdentifier: "iphonesimulator",
                sdkPath: "/Synthetic/iPhoneSimulator.sdk",
                platform: "iphonesimulator",
                platformVariant: "simulator",
                containerPath: "/Synthetic/Workspace.xcworkspace",
                projectPath: project,
                scheme: "Application",
                target: "SharedName",
                moduleName: "SharedName",
                configuration: "Debug",
                destination: "platform=iOS Simulator,name=Fictional Device",
                architecture: "arm64",
                deploymentTarget: "17.0",
                sourceFiles: [],
                compilerArguments: [],
                evidenceSource: .xcodeBuildSettings,
                isAuthoritative: false
            )
        }

        let first = context(project: "/Synthetic/First.xcodeproj")
        let second = context(project: "/Synthetic/Second.xcodeproj")

        XCTAssertNotEqual(first.contextIdentity, second.contextIdentity)
        XCTAssertEqual(Set([first.contextIdentity, second.contextIdentity]).count, 2)
    }

    func testXcodeContextUsesSelectedTargetMembershipAndEffectiveDestination()
        throws
    {
        let directory = try TestDirectory(name: "target-build-context")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let fixture = try makeSyntheticXcodeProject(
            in: directory,
            candidateOnlyWarning: false
        )
        let projectFile = fixture.project.appendingPathComponent(
            "project.pbxproj"
        )
        let projectText = try String(
            contentsOf: projectFile,
            encoding: .utf8
        )
        try (projectText + "\n// PBXFileSystemSynchronizedRootGroup\n")
            .write(to: projectFile, atomically: true, encoding: .utf8)
        let unrelated = try directory.write(
            "SyntheticXcodeProject/Unrelated/SyntheticFixture.swift",
            "import Foundation\nstruct Unrelated {}\n"
        )
        let bridgingHeader = try directory.write(
            "SyntheticXcodeProject/Support/Bridge.h",
            "typedef int FictionalValue;\n"
        )
        let sdk = try directory.makeDirectory("iPhoneSimulator27.0.sdk")
        let destination = "platform=iOS Simulator,name=Fictional Device"
        let settings: [String: String] = [
            "ARCHS": "arm64 x86_64",
            "CURRENT_ARCH": "arm64",
            "EFFECTIVE_PLATFORM_NAME": "-iphonesimulator",
            "FRAMEWORK_SEARCH_PATHS": "/tmp/FictionalFrameworks",
            "HEADER_SEARCH_PATHS": "/tmp/FictionalHeaders",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.2",
            "OTHER_SWIFT_FLAGS": "-enable-library-evolution",
            "PLATFORM_NAME": "iphonesimulator",
            "PRODUCT_MODULE_NAME": "SyntheticIntegration",
            "PROJECT_FILE_PATH": fixture.project.path,
            "SOURCE_ROOT": fixture.root.path,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS":
                "DEBUG TARGET_FEATURE $(inherited)",
            "SWIFT_INCLUDE_PATHS": "/tmp/FictionalModules",
            "SWIFT_OBJC_BRIDGING_HEADER":
                bridgingHeader.path.replacingOccurrences(
                    of: fixture.root.path + "/",
                    with: ""
                ),
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_VERSION": "6.0",
            "TARGET_NAME": fixture.scheme,
        ]
        let settingsData = try JSONSerialization.data(
            withJSONObject: [[
                "target": fixture.scheme,
                "configuration": "Profile",
                "buildSettings": settings,
            ]],
            options: [.sortedKeys]
        )
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild" {
                if call.arguments.contains("-list") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data(
                            """
                            {
                              "project": {
                                "configurations": ["Debug", "Profile"],
                                "schemes": ["\(fixture.scheme)"],
                                "targets": ["\(fixture.scheme)"]
                              }
                            }
                            """.utf8
                        ),
                        standardError: Data()
                    )
                }
                if call.arguments.contains("-showBuildSettings") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: settingsData,
                        standardError: Data()
                    )
                }
                if call.arguments.contains("build") {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data(
                            """
                            SwiftDriver normal arm64 (in target '\(fixture.scheme)' from project 'SyntheticXcodeProject')
                                builtin-SwiftDriver -- /Synthetic/Toolchain/usr/bin/swiftc -module-name SyntheticIntegration -sdk \(sdk.path) -target arm64-apple-ios17.2-simulator -swift-version 6 -D DEBUG -import-objc-header \(bridgingHeader.path) \(fixture.source.path)
                            """.utf8
                        ),
                        standardError: Data()
                    )
                }
                if call.arguments == ["-version"] {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: Data(
                            "Xcode 27.0\nBuild version 27A5228h\n".utf8
                        ),
                        standardError: Data()
                    )
                }
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
                        standardOutput: Data(
                            "Apple Swift version 6.4 (swiftlang-6.4)\n".utf8
                        ),
                        standardError: Data()
                    )
                }
            }
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data("unexpected synthetic command".utf8)
            )
        }
        let discovery = try ProjectDiscovery().discover(root: fixture.root)
        let resolution = try TargetBuildContextProvider(runner: runner).resolve(
            discovery: discovery,
            configuration: SwiftDeltaConfiguration(
                defaultProject: fixture.project.path,
                defaultScheme: fixture.scheme,
                activeCompilationConditions: ["COMMAND_LINE_FEATURE"]
            ),
            xcodeApplicationPath: xcode.path,
            toolchainRole: "candidate",
            sdkIdentifier: "iphonesimulator",
            buildConfiguration: "Profile",
            destination: destination,
            timeout: 600
        )

        let context = try XCTUnwrap(resolution.contexts.only)
        XCTAssertTrue(context.isAuthoritative)
        XCTAssertEqual(context.evidenceSource, .exactCompilerInvocation)
        XCTAssertEqual(
            context.capturedCompilerExecutable,
            "/Synthetic/Toolchain/usr/bin/swiftc"
        )
        XCTAssertFalse(context.capturedCompilerArguments.isEmpty)
        XCTAssertFalse(context.compilerArguments.isEmpty)
        XCTAssertTrue(context.compilerArguments.contains(fixture.source.path))
        XCTAssertTrue(context.compilerArguments.contains(
            "arm64-apple-ios17.2-simulator"
        ))
        XCTAssertEqual(context.containerPath, fixture.project.path)
        XCTAssertEqual(context.projectPath, fixture.project.path)
        XCTAssertEqual(context.sourceFiles, [fixture.source.path])
        XCTAssertEqual(context.analysisSourceFiles, [fixture.source.path])
        XCTAssertEqual(resolution.excludedSourceFiles, [unrelated.path])
        XCTAssertEqual(context.scheme, fixture.scheme)
        XCTAssertEqual(context.target, fixture.scheme)
        XCTAssertEqual(context.configuration, "Profile")
        XCTAssertEqual(context.sdkIdentifier, "iphonesimulator")
        XCTAssertEqual(context.platform, "iphonesimulator")
        XCTAssertEqual(context.platformVariant, "simulator")
        XCTAssertEqual(context.destination, destination)
        XCTAssertEqual(context.architecture, "arm64")
        XCTAssertEqual(context.deploymentTarget, "17.2")
        XCTAssertNotEqual(context.deploymentTarget, "27.0")
        XCTAssertEqual(context.swiftLanguageVersion, "6")
        XCTAssertEqual(
            context.activeCompilationConditions,
            ["COMMAND_LINE_FEATURE", "DEBUG", "TARGET_FEATURE"]
        )
        XCTAssertEqual(context.otherSwiftFlags, ["-enable-library-evolution"])
        XCTAssertEqual(context.bridgingHeader, bridgingHeader.path)
        XCTAssertEqual(context.strictConcurrency, "complete")
        let settingsCall = try XCTUnwrap(
            runner.calls.first { $0.arguments.contains("-showBuildSettings") }
        )
        XCTAssertTrue(settingsCall.arguments.contains("iphonesimulator"))
        XCTAssertTrue(settingsCall.arguments.contains(destination))
        XCTAssertTrue(settingsCall.arguments.contains("Profile"))
        let derivedDataPath = try argumentValue(
            after: "-derivedDataPath",
            in: settingsCall.arguments
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: derivedDataPath)
        )
        XCTAssertTrue(
            runner.calls.allSatisfy {
                $0.environment["DEVELOPER_DIR"]
                    == xcode.path + "/Contents/Developer"
            }
        )

        let preflight = try TargetBuildContextProvider(runner: runner).resolve(
            discovery: discovery,
            configuration: SwiftDeltaConfiguration(
                defaultProject: fixture.project.path,
                defaultScheme: fixture.scheme
            ),
            xcodeApplicationPath: xcode.path,
            toolchainRole: "candidate",
            sdkIdentifier: "iphonesimulator",
            buildConfiguration: "Profile",
            destination: destination,
            timeout: 600,
            captureExactCompilerInvocations: false
        )
        let preflightContext = try XCTUnwrap(preflight.contexts.only)
        XCTAssertFalse(preflightContext.isAuthoritative)
        XCTAssertEqual(preflightContext.evidenceSource, .xcodeBuildSettings)
        XCTAssertFalse(preflightContext.compilerArguments.isEmpty)
        XCTAssertTrue(
            preflight.preflightDeferredFailures.contains {
                $0.message.contains("build-derived source membership")
            }
        )
        XCTAssertTrue(
            Set(preflight.preflightDeferredFailures)
                .isSubset(of: Set(preflight.failures))
        )
    }

    func testPackageDescriptionRetainsDependenciesAndMarksMacroContextIncomplete()
        throws
    {
        let directory = try TestDirectory(name: "package-target-context")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        try directory.write(
            "Package.swift",
            packageManifest(platforms: ".macOS(.v13)")
        )
        let app = try directory.write(
            "Sources/SyntheticApp/App.swift",
            "struct SyntheticApp {}\n"
        )
        let macro = try directory.write(
            "Sources/SyntheticMacro/Macro.swift",
            "struct SyntheticMacro {}\n"
        )
        let sdk = try directory.makeDirectory("MacOSX27.sdk")
        let swift = xcode.appendingPathComponent(
            "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        ).path
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcodebuild" {
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
                            {"name": "macos", "version": "13.0"}
                          ],
                          "targets": [
                            {
                              "name": "SyntheticApp",
                              "path": "Sources/SyntheticApp",
                              "sources": ["App.swift"],
                              "target_dependencies": ["SyntheticMacro"],
                              "type": "library",
                              "module_type": "SwiftTarget"
                            },
                            {
                              "name": "SyntheticMacro",
                              "path": "Sources/SyntheticMacro",
                              "sources": ["Macro.swift"],
                              "target_dependencies": [],
                              "type": "macro",
                              "module_type": "MacroTarget"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    standardError: Data()
                )
            }
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        let discovery = try ProjectDiscovery().discover(root: directory.url)
        let resolution = try TargetBuildContextProvider(runner: runner).resolve(
            discovery: discovery,
            configuration: SwiftDeltaConfiguration(),
            xcodeApplicationPath: xcode.path,
            toolchainRole: "candidate",
            sdkIdentifier: "macosx",
            buildConfiguration: "Debug",
            timeout: 60
        )

        XCTAssertEqual(resolution.contexts.count, 2)
        let appContext = try XCTUnwrap(
            resolution.contexts.first { $0.target == "SyntheticApp" }
        )
        let macroContext = try XCTUnwrap(
            resolution.contexts.first { $0.target == "SyntheticMacro" }
        )
        XCTAssertEqual(appContext.sourceFiles, [app.path])
        XCTAssertEqual(appContext.targetDependencies, ["SyntheticMacro"])
        XCTAssertFalse(appContext.isAuthoritative)
        XCTAssertEqual(macroContext.sourceFiles, [macro.path])
        XCTAssertFalse(macroContext.isAuthoritative)
        XCTAssertTrue(
            resolution.failures.contains {
                $0.message.contains("macro or compiler plugin context")
            }
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
