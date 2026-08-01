//===--- RealSDKAndXcodeProjectIntegrationTests.swift - SwiftDelta ------------------------------------------===//
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

final class RealSDKAndXcodeProjectIntegrationTests: XCTestCase {
    func testRealTwoXcodeWorkspaceBuildComparison() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-two-xcode-workspace")
        let fixture = try makeSyntheticXcodeProject(
            in: directory,
            candidateOnlyWarning: false
        )
        let workspace = try directory.makeDirectory(
            "SyntheticXcodeProject/SyntheticIntegration.xcworkspace"
        )
        try directory.write(
            "SyntheticXcodeProject/SyntheticIntegration.xcworkspace/"
                + "contents.xcworkspacedata",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version="1.0">
              <FileRef location="group:SyntheticIntegration.xcodeproj">
              </FileRef>
            </Workspace>
            """
        )
        let runner = RecordingProcessRunner()
        let container = ProjectContainer(
            kind: .workspace,
            path: workspace.path
        )
        let comparison = try BuildComparator(
            builder: XcodeProjectBuilder(runner: runner)
        ).compare(
            old: BuildInvocation(
                xcodePath: toolchains.baseline,
                container: container,
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            new: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: container,
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            )
        )

        XCTAssertTrue(
            comparison.oldBuild.succeeded,
            comparison.oldBuild.diagnostics.map(\.message)
                .joined(separator: "\n")
        )
        XCTAssertTrue(
            comparison.newBuild.succeeded,
            comparison.newBuild.diagnostics.map(\.message)
                .joined(separator: "\n")
        )
        XCTAssertEqual(comparison.oldBuild.diagnosticSource, .modernXCResult)
        XCTAssertEqual(comparison.newBuild.diagnosticSource, .modernXCResult)
        let calls = runner.calls.filter {
            $0.executable == "/usr/bin/xcodebuild"
                && $0.arguments.contains("build")
                && $0.arguments.contains("-workspace")
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            Set(calls.compactMap { $0.environment["DEVELOPER_DIR"] }),
            Set([
                toolchains.baseline + "/Contents/Developer",
                toolchains.candidate + "/Contents/Developer",
            ])
        )
    }

    func testRealTwoXcodeSDKAndProjectPipeline() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-two-xcode-project")
        let fixture = try makeSyntheticXcodeProject(in: directory)
        let runner = RecordingProcessRunner()
        let discovery = try ProjectDiscovery().discover(root: fixture.root)
        let analysis = try SDKAnalysisEngine(runner: runner).analyze(
            discovery: discovery,
            configuration: SwiftDeltaConfiguration(
                defaultProject: fixture.project.path,
                defaultScheme: fixture.scheme,
                baselineXcodePath: toolchains.baseline,
                candidateXcodePath: toolchains.candidate,
                sdkIdentifiers: ["macosx"]
            ),
            timeoutPerOperation: 300,
            sdkCachePolicy: .disabled,
            buildConfiguration: "Debug",
            destination: "platform=macOS"
        )
        let failureSummary = analysis.failures.map(\.message)
            .joined(separator: "\n")
        let contextSummary = (
            analysis.baselineBuildContexts
                + analysis.candidateBuildContexts
        ).map {
            "\($0.toolchainRole) \($0.evidenceSource.rawValue) "
                + "authoritative=\($0.isAuthoritative)\n"
                + $0.compilerArguments.joined(separator: "\n")
        }.joined(separator: "\n---\n")
        let baseline = try XCTUnwrap(
            analysis.baselineSnapshots.first,
            "Analysis failures:\n\(failureSummary)\nContexts:\n\(contextSummary)"
        )
        let candidate = try XCTUnwrap(
            analysis.candidateSnapshots.first,
            "Analysis failures:\n\(failureSummary)"
        )
        try assertSDKIdentity(baseline.identity, expected: toolchains.baselineExpected)
        try assertSDKIdentity(candidate.identity, expected: toolchains.candidateExpected)
        XCTAssertEqual(baseline.modules, ["Foundation"])
        XCTAssertEqual(candidate.modules, ["Foundation"])
        XCTAssertTrue(baseline.successfullyExtractedModules.contains("Foundation"))
        XCTAssertTrue(candidate.successfullyExtractedModules.contains("Foundation"))
        XCTAssertFalse(baseline.symbols.isEmpty)
        XCTAssertFalse(candidate.symbols.isEmpty)
        XCTAssertNotEqual(
            baseline.identity.developerDirectory,
            candidate.identity.developerDirectory
        )
        XCTAssertNotEqual(baseline.identity.sdkPath, candidate.identity.sdkPath)

        let coverage = analysis.referenceResolutionCoverage
        XCTAssertEqual(coverage.count, 2)
        XCTAssertEqual(
            Set(coverage.compactMap(\.toolchainRole)),
            ["baseline", "candidate"]
        )
        let coverageSummary = coverage.map {
            "\($0.toolchainRole ?? "unknown") sdk=\($0.sdkIdentifier) "
                + "scheme=\($0.scheme ?? "nil") target=\($0.target ?? "nil") "
                + "configuration=\($0.configuration ?? "nil") "
                + "destination=\($0.destination ?? "nil") "
                + "deployment=\($0.deploymentTarget ?? "nil") "
                + "requested=\($0.filesRequested) analyzed=\($0.filesAnalyzed) "
                + "failed=\($0.filesFailed) complete=\($0.isComplete) "
                + "exit=\($0.compilerExitStatus.map(String.init) ?? "nil") "
                + "reasons=\($0.unresolvedReasons) files=\($0.sourceFiles)"
        }.joined(separator: "\n")
        XCTAssertTrue(
            coverage.allSatisfy {
                $0.sdkIdentifier == "macosx"
                    && $0.scheme == fixture.scheme
                    && $0.target == "SyntheticIntegration"
                    && $0.configuration == "Debug"
                    && $0.destination == "platform=macOS"
                    && $0.deploymentTarget == "13.0"
                    && $0.filesRequested == 1
                    && $0.filesAnalyzed == 1
                    && $0.filesFailed == 0
                    && $0.isComplete
            },
            coverageSummary + "\nFailures:\n" + failureSummary
        )
        XCTAssertFalse(
            analysis.failures.contains {
                $0.message.contains("exact isolated-build compiler invocation")
            }
        )
        XCTAssertEqual(
            Set(
                analysis.moduleSelections
                    .filter { $0.moduleName == "Foundation" }
                    .map(\.toolchainRole)
            ),
            ["baseline", "candidate"]
        )

        _ = SDKSnapshotDiffer.compare(
            baseline: baseline,
            candidate: candidate
        )
        let sdkFindings = analysis.findings
        for finding in sdkFindings {
            let evidence = try XCTUnwrap(finding.sdkEvidence)
            XCTAssertEqual(evidence.baseline.xcodeBuild, baseline.identity.xcodeBuild)
            XCTAssertEqual(evidence.candidate.xcodeBuild, candidate.identity.xcodeBuild)
            XCTAssertEqual(evidence.baseline.sdkVersion, baseline.identity.sdkVersion)
            XCTAssertEqual(evidence.candidate.sdkVersion, candidate.identity.sdkVersion)
            XCTAssertEqual(evidence.platform, "macOS")
            XCTAssertEqual(evidence.moduleName, "Foundation")
            XCTAssertFalse(evidence.fullyQualifiedName.isEmpty)
            XCTAssertEqual(evidence.sourceLocation.path, fixture.source.path)
        }

        let container = ProjectContainer(kind: .project, path: fixture.project.path)
        let comparison = try BuildComparator(
            builder: XcodeProjectBuilder(runner: runner)
        ).compare(
            old: BuildInvocation(
                xcodePath: toolchains.baseline,
                container: container,
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            new: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: container,
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            staticFindings: sdkFindings,
            targetVersion: candidate.identity.xcodeVersion
        )
        XCTAssertTrue(comparison.oldBuild.succeeded)
        XCTAssertTrue(
            comparison.newBuild.succeeded,
            "Candidate diagnostics: \(comparison.newBuild.diagnostics)"
        )
        XCTAssertEqual(comparison.oldBuild.xcodePath, toolchains.baseline)
        XCTAssertEqual(comparison.newBuild.xcodePath, toolchains.candidate)
        XCTAssertEqual(comparison.oldBuild.diagnosticSource, .modernXCResult)
        XCTAssertEqual(comparison.newBuild.diagnosticSource, .modernXCResult)
        XCTAssertTrue(
            comparison.introducedDiagnostics.contains {
                $0.message.lowercased()
                    .contains("synthetic candidate-only project diagnostic")
                    && $0.location?.path == fixture.source.path
            }
        )

        let report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: fixture.root.path,
            targetXcodeVersion: candidate.identity.xcodeVersion,
            baselineEnvironment: environmentSnapshot(from: baseline.identity),
            candidateEnvironment: environmentSnapshot(from: candidate.identity),
            referenceResolutionCoverage: coverage,
            findings: comparison.findings,
            failures: analysis.failures
        )
        for format in ReportFormat.allCases {
            let output = directory.url.appendingPathComponent(
                "Report-\(format.rawValue).\(format == .terminal ? "txt" : format.rawValue)"
            )
            let data = try ReportRenderer.render(report, format: format)
            try ReportRenderer.write(data, to: output)
            XCTAssertFalse(data.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(
            ExitStatusEvaluator.status(
                for: comparison.findings,
                failureLevel: .error
            ),
            0
        )
        XCTAssertEqual(
            ExitStatusEvaluator.status(
                for: comparison.findings,
                failureLevel: .warning
            ),
            1
        )

        let buildCalls = runner.calls.filter {
            $0.executable == "/usr/bin/xcodebuild" && $0.arguments.contains("build")
        }
        XCTAssertEqual(buildCalls.count, 4)
        XCTAssertEqual(
            Set(buildCalls.compactMap { $0.environment["DEVELOPER_DIR"] }),
            Set([
                baseline.identity.developerDirectory,
                candidate.identity.developerDirectory,
            ])
        )
        try assertUniqueArgumentPaths("-derivedDataPath", calls: buildCalls)
        let comparisonBuildCalls = buildCalls.filter {
            $0.arguments.contains("-resultBundlePath")
        }
        XCTAssertEqual(comparisonBuildCalls.count, 2)
        try assertUniqueArgumentPaths(
            "-resultBundlePath",
            calls: comparisonBuildCalls
        )
        XCTAssertTrue(
            runner.calls.filter { $0.arguments.contains("xcresulttool") }.allSatisfy {
                let selected = $0.environment["DEVELOPER_DIR"]
                return selected == baseline.identity.developerDirectory
                    || selected == candidate.identity.developerDirectory
            }
        )
    }
}
