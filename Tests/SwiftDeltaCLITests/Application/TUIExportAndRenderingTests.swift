//===--- TUIExportAndRenderingTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDelta
import SwiftDeltaCore
import XCTest

final class TUIExportAndRenderingTests: XCTestCase {
    func testFirstRunHasOnePrimaryActionAndRestrainedWorkflowChrome() {
        var settings = TUISettings()
        settings.workflow.baselineXcodePath = "/Synthetic/Baseline.app"
        settings.workflow.candidateXcodePath = "/Synthetic/Candidate.app"
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: true
        )
        let enabledPrimaryRows = TUIContentRows.rows(for: state).filter {
            $0.enabled && $0.prominence == .primary
        }
        XCTAssertEqual(enabledPrimaryRows.map(\.label), ["Choose project"])
        XCTAssertEqual(
            state.navigationScreens,
            [.project, .check]
        )
        XCTAssertTrue(
            TUIContentRows.rows(for: state).contains {
                $0.label == "Settings"
            }
        )

        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        let output = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).render(
            state,
            size: TerminalSize(columns: 132, rows: 34)
        ).encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined(separator: "\n")

        XCTAssertTrue(output.contains("SwiftDelta"))
        XCTAssertTrue(output.contains("Choose project"))
        XCTAssertTrue(output.contains("Project"))
        XCTAssertTrue(output.contains("Actions"))
        XCTAssertTrue(output.contains("Other"))
        XCTAssertTrue(output.contains("▀"))
        XCTAssertFalse(output.contains("┌"))
        XCTAssertTrue(output.contains("Repair"))

        state.projectWasExplicitlySelected = true
        state.selectedContainer = ProjectContainer(
            kind: .project,
            path: "/Synthetic/Project.xcodeproj"
        )
        state.settings.workflow.scheme = "Project"
        state.settings.workflow.buildConfiguration = "Debug"
        state.settings.workflow.sdkIdentifiers = ["macosx"]
        state.settings.workflow.destination = "platform=macOS"
        state.setupOrigins = [
            .baselineXcode: .saved,
            .candidateXcode: .saved,
            .sdk: .saved,
            .destination: .saved,
        ]
        XCTAssertEqual(
            TUIContentRows.rows(for: state).filter {
                $0.enabled && $0.prominence == .primary
            }.map(\.label),
            ["Doctor"]
        )
        let selectedProjectOutput = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).render(
            state,
            size: TerminalSize(columns: 80, rows: 24)
        ).encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined(separator: "\n")
        XCTAssertTrue(selectedProjectOutput.contains("▀"))
        XCTAssertTrue(selectedProjectOutput.contains("Analysis"))
        XCTAssertTrue(selectedProjectOutput.contains("Run after Doctor passes"))
    }

    func testPageHeaderUsesReadableProjectNameWithoutPathOrBrandMark() {
        var settings = TUISettings()
        settings.workflow.projectRoot = "/Synthetic/Fictional Workspace"
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: false
        )
        state.projectWasExplicitlySelected = true
        state.selectedContainer = ProjectContainer(
            kind: .project,
            path:
                "/Synthetic/Fictional Workspace/"
                + "Fictional Upgrade.xcodeproj"
        )
        state.screen = .findings
        state.report = syntheticReport()
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        let canvas = renderer.render(
            state,
            size: TerminalSize(columns: 160, rows: 36)
        )
        let lines = plainText(canvas).components(separatedBy: "\n")
        let header = lines[0].trimmingCharacters(in: .whitespaces)

        XCTAssertEqual(state.projectDisplayName, "Fictional Upgrade")
        XCTAssertEqual(header, "Fictional Upgrade")
        XCTAssertFalse(header.contains("/"))
        XCTAssertFalse(header.contains("●"))
        XCTAssertFalse(header.contains("△"))
        XCTAssertFalse(header.contains("#"))

        state.screen = .project
        let home = plainText(
            renderer.render(
                state,
                size: TerminalSize(columns: 160, rows: 36)
            )
        )
        XCTAssertTrue(home.contains("/Synthetic/Fictional Workspace"))

        state.selectedContainer = ProjectContainer(
            kind: .package,
            path: "/Synthetic/FictionalPackage/Package.swift"
        )
        XCTAssertEqual(state.projectDisplayName, "FictionalPackage")

        state.selectedContainer = ProjectContainer(
            kind: .workspace,
            path:
                "/Synthetic/"
                + String(repeating: "Long Project Name ", count: 8)
                + ".xcworkspace"
        )
        let narrowHeader = plainText(
            renderer.render(
                state,
                size: TerminalSize(columns: 80, rows: 24)
            )
        ).components(separatedBy: "\n")[0]
        XCTAssertLessThanOrEqual(
            TerminalText.displayWidth(narrowHeader),
            80
        )
        XCTAssertTrue(narrowHeader.contains("…"))
        XCTAssertFalse(narrowHeader.contains("/"))
    }

    func testTerminalJSONAndSARIFReportsExportThroughCoreAdapter() throws {
        for format in ReportFormat.allCases {
            let directory = try TUITestDirectory()
            var settings = TUISettings()
            settings.workflow.projectRoot = directory.url.path
            settings.workflow.reportFormat = format
            settings.workflow.reportOutputPath = "report.\(format.rawValue)"
            let report = syntheticReport(findings: [
                syntheticFinding(
                    identifier: "export",
                    title: "Export finding",
                    severity: .warning
                ),
            ])

            let result = try CoreTUIOperationService().perform(
                .exportReport,
                request: TUIOperationRequest(
                    settings: settings,
                    report: report,
                    repairPlan: nil,
                    selectedRepairIdentifiers: []
                ),
                cancellation: { false },
                progress: { _ in }
            )

            guard case let .reportExported(path) = result else {
                return XCTFail("Expected exported report")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertFalse(data.isEmpty)
            if format == .json {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                )
                XCTAssertEqual(object["reportFormatVersion"] as? String, "3.0")
            }
            if format == .sarif {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                )
                XCTAssertEqual(object["version"] as? String, "2.1.0")
            }
        }
    }

    func testUnavailableModelDoesNotBlockDeterministicOperations() throws {
        let directory = try TUITestDirectory()
        var settings = TUISettings()
        settings.workflow.projectRoot = directory.url.path
        settings.workflow.reportFormat = .json
        settings.workflow.reportOutputPath = "report.json"
        settings.workflow.foundationModelTimeout = 0

        let result = try CoreTUIOperationService().perform(
            .exportReport,
            request: TUIOperationRequest(
                settings: settings,
                report: syntheticReport(),
                repairPlan: nil,
                selectedRepairIdentifiers: [],
                foundationModelStatus: .unavailable
            ),
            cancellation: { false },
            progress: { _ in }
        )

        guard case .reportExported = result else {
            return XCTFail("Expected deterministic report export")
        }
    }

    func testRepairPlanDiffAndJSONExportPreserveProvenance() throws {
        for format in RepairPlanOutputFormat.allCases {
            let directory = try TUITestDirectory()
            var settings = TUISettings()
            settings.workflow.projectRoot = directory.url.path
            settings.workflow.repairPlanFormat = format
            settings.workflow.repairOutputPath = "plan.\(format.rawValue)"
            let plan = RepairPlan(
                generatedAt: Date(timeIntervalSince1970: 100),
                projectRoot: directory.url.path,
                repairs: [syntheticRepair(modelGenerated: true)]
            )
            let sourceDirectory = directory.url.appendingPathComponent(
                "Sources",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: false
            )
            try Data("old\n".utf8).write(
                to: sourceDirectory.appendingPathComponent("App.swift")
            )

            let result = try CoreTUIOperationService().perform(
                .exportRepairPlan,
                request: TUIOperationRequest(
                    settings: settings,
                    report: nil,
                    repairPlan: plan,
                    selectedRepairIdentifiers: []
                ),
                cancellation: { false },
                progress: { _ in }
            )

            guard case let .repairPlanExported(path) = result else {
                return XCTFail("Expected exported repair plan")
            }
            let text = try String(
                contentsOf: URL(fileURLWithPath: path),
                encoding: .utf8
            )
            XCTAssertTrue(text.contains("Apple Foundation Models"))
            XCTAssertTrue(text.lowercased().contains("review"))
        }
    }

    func testEmptyAndLongFindingsRenderAtSeveralTerminalSizes() {
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        var empty = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        empty.screen = .findings
        empty.report = syntheticReport()

        for size in [
            TerminalSize(columns: 80, rows: 24),
            TerminalSize(columns: 100, rows: 28),
            TerminalSize(columns: 128, rows: 32),
            TerminalSize(columns: 160, rows: 50),
        ] {
            let canvas = renderer.render(empty, size: size)
            XCTAssertEqual(canvas.rows.count, size.rows)
            XCTAssertTrue(canvas.rows.allSatisfy { $0.count == size.columns })
        }

        empty.report = syntheticReport(findings: [
            syntheticFinding(
                identifier: "long",
                title: String(repeating: "Very long diagnostic ", count: 30)
                    + "\u{1B}]52;c;unsafe\u{07}",
                severity: .error,
                path: String(repeating: "LongDirectory/", count: 20)
                    + "App.swift"
            ),
        ])
        let canvas = renderer.render(
            empty,
            size: TerminalSize(columns: 100, rows: 24)
        )
        let output = canvas.encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined()
        XCTAssertFalse(output.contains("]52;c;unsafe\u{07}"))
    }

    func testNativeTerminalBackgroundAndAdaptiveModalSurface() {
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.overlay = .message(
            title: "Technical details",
            message: "Readable on the terminal's own background.",
            details: (0..<50).map { "Line \($0)" }.joined(separator: "\n")
        )
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let theme = TerminalTheme()
        let canvas = TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        ).render(state, size: TerminalSize(columns: 128, rows: 32))
        let output = canvas.encodedLines(
            theme: theme,
            capabilities: capabilities
        ).joined()

        XCTAssertFalse(output.contains("[48;2;"))
        XCTAssertFalse(output.contains("[38;2;"))
        XCTAssertTrue(output.contains(";49m") || output.contains("[0;39;49m"))
        let reversedCells = canvas.rows.flatMap { $0 }.count {
            $0.style.reverse
        }
        XCTAssertLessThan(reversedCells, 100)
        XCTAssertTrue(output.contains("┌"))
        XCTAssertTrue(output.contains("Technical details"))
    }

    func testIncompleteResultsAndLargeRepairPlansRemainNavigable() {
        let capabilities = TerminalCapabilities(
            colorMode: .basic,
            symbolMode: .ascii,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        var results = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        results.screen = .findings
        results.report = syntheticReport(state: .incomplete)
        let resultOutput = renderer.render(
            results,
            size: TerminalSize(columns: 80, rows: 24)
        ).encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined()
        XCTAssertTrue(resultOutput.contains("INCOMPLETE"))
        XCTAssertFalse(resultOutput.contains("PASS"))

        let repairs = (0..<300).map {
            syntheticRepair(identifier: "repair.\($0)")
        }
        var repairState = results
        repairState.screen = .repair
        repairState.repairPlan = RepairPlan(
            projectRoot: "/tmp/SyntheticProject",
            repairs: repairs
        )
        repairState.contentIndex =
            TUIContentRows.rows(for: repairState).count + repairs.count - 1
        for size in [
            TerminalSize(columns: 80, rows: 24),
            TerminalSize(columns: 128, rows: 32),
        ] {
            let canvas = renderer.render(repairState, size: size)
            XCTAssertEqual(canvas.rows.count, size.rows)
            XCTAssertTrue(canvas.rows.allSatisfy { $0.count == size.columns })
        }
    }

    func testRepairReviewKeepsThreeHundredCandidatesAccessibleForOneHundredSixtyNineFindings() {
        let findings = (0..<169).map {
            syntheticFinding(
                identifier: "finding.\($0)",
                title: "Synthetic migration finding \($0)",
                severity: $0.isMultiple(of: 4) ? .error : .warning,
                path: "Sources/File\($0).swift"
            )
        }
        let repairs = (0..<300).map {
            syntheticRepair(identifier: "repair.candidate.\($0)")
        }
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.screen = .repair
        state.report = syntheticReport(findings: findings)
        state.repairPlan = RepairPlan(
            projectRoot: "/tmp/SyntheticProject",
            repairs: repairs
        )

        XCTAssertEqual(state.report?.findings.count, 169)
        XCTAssertEqual(state.displayedRepairCandidates.count, 300)

        state.contentIndex =
            TUIContentRows.rows(for: state).count + 299
        let canvas = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            )
        ).render(
            state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        XCTAssertEqual(canvas.rows.count, 28)
        XCTAssertNotNil(state.selectedRepairCandidate)
    }

    func testReducedMotionDoesNotChangeSemanticScreenContent() {
        let state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        var ordinary = TerminalCapabilities.detect(environment: [
            "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
        ])
        ordinary.reducedMotion = false
        var reduced = ordinary
        reduced.reducedMotion = true

        let first = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: ordinary
        ).render(state, size: TerminalSize(columns: 100, rows: 30))
        let second = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: reduced
        ).render(state, size: TerminalSize(columns: 100, rows: 30))

        XCTAssertEqual(first.rows, second.rows)
    }

    func testResponsiveHomeKeepsWorkflowActionsVisible() {
        var settings = TUISettings()
        settings.workflow.projectRoot = "/Synthetic/Project"
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: true
        )
        state.projectWasExplicitlySelected = true
        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .unicode,
            highContrast: true,
            reducedMotion: true,
            mouseSupported: false
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        for size in [
            TerminalSize(columns: 64, rows: 18),
            TerminalSize(columns: 88, rows: 24),
            TerminalSize(columns: 104, rows: 28),
            TerminalSize(columns: 132, rows: 34),
        ] {
            let output = renderer.render(state, size: size).encodedLines(
                theme: TerminalTheme(),
                capabilities: capabilities
            ).joined(separator: "\n")
            XCTAssertTrue(output.contains("Doctor"), "\(size)")
            XCTAssertTrue(output.contains("Analysis"), "\(size)")
            XCTAssertTrue(output.contains("Repair"), "\(size)")
        }
    }

    func testOperationAnimationHasAccessibleLifecycleAndFixedBounds() {
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.operationStatus = .running(
            .automaticSetup,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        state.progressLines = ["Inspecting synthetic project"]
        state.progressMeasurement = OperationProgressMeasurement(
            completed: 2,
            total: 4,
            label: "Project targets"
        )
        let ordinary = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: false,
            mouseSupported: false
        )
        let animatedRenderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: ordinary,
            now: { Date(timeIntervalSince1970: 102) }
        )
        let animated = animatedRenderer.render(
            state,
            size: TerminalSize(columns: 80, rows: 24)
        )
        let animatedText = animated.encodedLines(
            theme: TerminalTheme(),
            capabilities: ordinary
        ).joined(separator: "\n")
        XCTAssertTrue(
            animatedText.contains("█")
                || animatedText.contains("▀")
                || animatedText.contains("▄")
        )
        XCTAssertTrue(animatedText.contains("SETUP"))
        XCTAssertTrue(animatedText.contains("0:02"))
        XCTAssertTrue(animatedText.contains("Project targets  2 of 4 · 50%"))
        XCTAssertTrue(animatedText.contains("█"))
        XCTAssertGreaterThanOrEqual(
            animated.rows[17].filter { $0.text == "█" }.count,
            70
        )
        XCTAssertEqual(
            animated.rows[18].filter { $0.text == "█" }.count,
            0
        )
        XCTAssertEqual(animated.rows.count, 24)
        XCTAssertTrue(animated.rows.allSatisfy { $0.count == 80 })
        for size in [
            TerminalSize(columns: 80, rows: 24),
            TerminalSize(columns: 100, rows: 28),
            TerminalSize(columns: 128, rows: 32),
            TerminalSize(columns: 160, rows: 50),
        ] {
            let resized = animatedRenderer.render(state, size: size)
            XCTAssertEqual(resized.rows.count, size.rows)
            XCTAssertTrue(resized.rows.allSatisfy { $0.count == size.columns })
            let resizedText = resized.rows.flatMap { $0 }
                .filter { !$0.continuation }
                .map(\.text)
                .joined()
            XCTAssertTrue(
                resizedText.contains("█")
                    || resizedText.contains("▀")
                    || resizedText.contains("▄")
            )
        }

        var reduced = ordinary
        reduced.reducedMotion = true
        let staticText = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: reduced,
            now: { Date(timeIntervalSince1970: 102) }
        ).render(state, size: TerminalSize(columns: 80, rows: 24))
            .encodedLines(
                theme: TerminalTheme(),
                capabilities: reduced
            ).joined(separator: "\n")
        XCTAssertTrue(staticText.contains("SETUP in progress"))

        for status in [
            TUIOperationStatus.idle,
            .succeeded(.automaticSetup, message: "Done"),
            .failed(.automaticSetup, summary: "Failed", details: "Details"),
            .cancelled(.automaticSetup),
        ] {
            state.operationStatus = status
            let finishedText = TUIScreenRenderer(
                theme: TerminalTheme(),
                capabilities: reduced,
                now: { Date(timeIntervalSince1970: 102) }
            ).render(state, size: TerminalSize(columns: 80, rows: 24))
                .encodedLines(
                    theme: TerminalTheme(),
                    capabilities: reduced
                ).joined(separator: "\n")
            XCTAssertFalse(finishedText.contains("SETUP in progress"))
        }
    }

    func testProgressPanelRemainsReadableAcrossTerminalFallbacksAndSizes() {
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.operationStatus = .running(
            .compare,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        state.progressLines = [
            "[00:01] Resolving compiler context",
            "[00:02] Extracting FictionalSDK",
        ]
        let theme = TerminalTheme()
        let capabilityVariants = [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .indexed256,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: false
            ),
        ]
        for capabilities in capabilityVariants {
            for size in [
                TerminalSize(columns: 64, rows: 18),
                TerminalSize(columns: 80, rows: 24),
                TerminalSize(columns: 100, rows: 28),
                TerminalSize(columns: 128, rows: 32),
            ] {
                let canvas = TUIScreenRenderer(
                    theme: theme,
                    capabilities: capabilities,
                    now: { Date(timeIntervalSince1970: 104) }
                ).render(state, size: size)
                let text = canvas.rows.flatMap { $0 }
                    .filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                XCTAssertEqual(canvas.rows.count, size.rows)
                XCTAssertTrue(canvas.rows.allSatisfy {
                    $0.count == size.columns
                })
                XCTAssertTrue(text.contains("Extracting FictionalSDK"))
                XCTAssertTrue(
                    text.contains(
                        capabilities.symbolMode == .ascii
                            ? "Progress - working"
                            : "Progress · working"
                    )
                )
                XCTAssertTrue(
                    text.contains(
                        capabilities.symbolMode == .ascii ? "=" : "█"
                    )
                )
                if capabilities.colorMode == .trueColor,
                   capabilities.symbolMode == .unicode
                {
                    let panelHeight = min(15, size.rows - 4)
                    let panelRow = size.rows - panelHeight - 2
                    let progressRow = panelRow
                        + 2
                        + OperationPixelAnimation.Frame.height
                    let progressLabelRow = min(
                        panelRow + panelHeight - 4,
                        progressRow + 2
                    )
                    XCTAssertTrue(
                        canvas.rows[progressLabelRow + 1]
                            .contains { $0.text == "█" }
                    )
                    XCTAssertFalse(
                        canvas.rows[progressLabelRow + 2].allSatisfy {
                            $0.text == "█"
                        }
                    )
                }
            }
        }
    }

    func testPrimaryActionsRemainDistinctWithoutColor() {
        let directory = try? TUITestDirectory()
        guard let directory else {
            return XCTFail("Could not create test directory.")
        }
        let controller = makeTUIController(
            screen: .check,
            service: FakeTUIOperationService(
                .result(.doctor(TUIDoctorResult(lines: [], issues: [])))
            ),
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: [],
            issues: []
        )
        let repair = syntheticRepair()
        let values = [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: false,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .unicode,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities.detect(environment: [
                "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8",
                "NO_COLOR": "1",
            ]),
        ]
        for capabilities in values {
            let renderer = TUIScreenRenderer(
                theme: TerminalTheme(),
                capabilities: capabilities
            )
            controller.state.screen = .check
            var output = renderer.render(
                controller.state,
                size: TerminalSize(columns: 100, rows: 28)
            ).encodedLines(
                theme: TerminalTheme(),
                capabilities: capabilities
            ).joined(separator: "\n")
            XCTAssertTrue(output.contains("[ Run Doctor Again ]"))

            controller.state.screen = .findings
            output = renderer.render(
                controller.state,
                size: TerminalSize(columns: 100, rows: 28)
            ).encodedLines(
                theme: TerminalTheme(),
                capabilities: capabilities
            ).joined(separator: "\n")
            XCTAssertTrue(output.contains("[ Run Analysis ]"))

            controller.state.screen = .repair
            controller.state.repairPlan = RepairPlan(
                projectRoot: directory.url.path,
                repairs: [repair]
            )
            controller.state.selectedRepairIDs = [repair.repairIdentifier]
            output = renderer.render(
                controller.state,
                size: TerminalSize(columns: 100, rows: 28)
            ).encodedLines(
                theme: TerminalTheme(),
                capabilities: capabilities
            ).joined(separator: "\n")
            XCTAssertTrue(output.contains("[ Generate Repair Preview ]"))
            XCTAssertTrue(output.contains("[ Apply Selected Repairs ]"))
        }
    }

    func testAnalysisAndRepairActionsHaveConsistentSemanticProminence() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(),
            service: FakeTUIOperationService(.result(.report(syntheticReport()))),
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: [],
            issues: []
        )
        controller.state.settings.workflow.reportOutputPath = "report.json"

        let analysisRows = TUIContentRows.resultControls(
            for: controller.state
        )
        XCTAssertEqual(
            Set(analysisRows.filter {
                $0.prominence == .primary
            }.map(\.label)),
            Set([
                "Run Analysis Again",
                "Export",
                "Continue to Repair",
            ])
        )

        controller.state.screen = .repair
        controller.state.repairPlan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [syntheticRepair()]
        )
        let repairRows = TUIContentRows.rows(for: controller.state)
        XCTAssertEqual(
            Set(repairRows.filter {
                $0.prominence == .primary
            }.map(\.label)),
            Set([
                "Generate Repair Preview",
                "Validate Again",
                "Select Repair",
                "Export repair plan",
                "Apply Selected Repairs",
            ])
        )
        XCTAssertEqual(
            repairRows.first {
                $0.label == "Apply Selected Repairs"
            }?.prominence,
            .primary
        )
    }

    func testPrimaryDisabledAndDestructiveStylesAcrossCustomScreens() throws {
        let directory = try TUITestDirectory()
        let theme = TerminalTheme()
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        )
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(),
            service: FakeTUIOperationService(.result(.report(syntheticReport()))),
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: [],
            issues: []
        )
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.resultControls(for: controller.state)
                .firstIndex { $0.label == "Run Analysis Again" }
        )
        var analysis = renderer.render(
            controller.state,
            size: TerminalSize(columns: 132, rows: 34)
        )
        let analysisStyle = try XCTUnwrap(
            style(containing: "[ Run Analysis Again ]", in: analysis)
        )
        XCTAssertEqual(analysisStyle.foreground, theme.selectionForeground)
        XCTAssertEqual(analysisStyle.background, theme.selectionBackground)
        XCTAssertTrue(analysisStyle.bold)
        XCTAssertFalse(analysisStyle.underline)
        XCTAssertFalse(analysisStyle.reverse)

        controller.state.doctorResult = nil
        analysis = renderer.render(
            controller.state,
            size: TerminalSize(columns: 132, rows: 34)
        )
        let disabledStyle = try XCTUnwrap(
            style(containing: "[- Run Analysis Again -]", in: analysis)
        )
        XCTAssertFalse(disabledStyle.dim)
        XCTAssertFalse(disabledStyle.bold)
        XCTAssertEqual(disabledStyle.background, theme.selectionBackground)
        XCTAssertFalse(disabledStyle.underline)

        controller.state.screen = .repair
        let repair = syntheticRepair()
        controller.state.repairPlan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [repair]
        )
        controller.state.selectedRepairIDs = [repair.repairIdentifier]
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state)
                .firstIndex { $0.label == "Generate Repair Preview" }
        )
        var repairCanvas = renderer.render(
            controller.state,
            size: TerminalSize(columns: 132, rows: 34)
        )
        let generateStyle = try XCTUnwrap(
            style(containing: "[ Generate Repair Preview ]", in: repairCanvas)
        )
        XCTAssertEqual(generateStyle.foreground, theme.selectionForeground)
        XCTAssertEqual(generateStyle.background, theme.selectionBackground)
        XCTAssertTrue(generateStyle.bold)
        XCTAssertFalse(generateStyle.underline)
        XCTAssertFalse(generateStyle.reverse)
        let unfocusedApplyStyle = try XCTUnwrap(
            style(containing: "[ Apply Selected Repairs ]", in: repairCanvas)
        )
        XCTAssertEqual(
            unfocusedApplyStyle.foreground,
            theme.style(.primaryAction, highContrast: false).foreground
        )
        XCTAssertNotEqual(unfocusedApplyStyle.foreground, theme.error)

        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state)
                .firstIndex { $0.label == "Apply Selected Repairs" }
        )
        repairCanvas = renderer.render(
            controller.state,
            size: TerminalSize(columns: 132, rows: 34)
        )
        let applyStyle = try XCTUnwrap(
            style(containing: "[ Apply Selected Repairs ]", in: repairCanvas)
        )
        XCTAssertEqual(applyStyle.foreground, theme.selectionForeground)
        XCTAssertEqual(applyStyle.background, theme.selectionBackground)
        XCTAssertTrue(applyStyle.bold)
        XCTAssertFalse(applyStyle.underline)

        var home = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        home.contentIndex = 0
        let homeCanvas = renderer.render(
            home,
            size: TerminalSize(columns: 132, rows: 34)
        )
        let homePrimary = try XCTUnwrap(
            style(containing: "[ Choose project ]", in: homeCanvas)
        )
        XCTAssertEqual(homePrimary.foreground, theme.selectionForeground)
        XCTAssertEqual(homePrimary.background, theme.selectionBackground)
        XCTAssertTrue(homePrimary.bold)
        XCTAssertFalse(homePrimary.underline)
        XCTAssertFalse(homePrimary.reverse)
    }

    func testFocusedRowsUseNeutralWhiteSurfaceAcrossCapabilities() throws {
        let theme = TerminalTheme()
        XCTAssertEqual(theme.accent, .rgb(142, 104, 181))
        XCTAssertEqual(theme.selectionBackground, .rgb(255, 255, 255))
        XCTAssertEqual(theme.selectionForeground, .rgb(0, 0, 0))
        XCTAssertEqual(
            theme.style(.primaryAction, highContrast: false).foreground,
            theme.accent
        )
        for capabilities in [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .indexed256,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: false
            ),
        ] {
            var state = TUIState(
                settings: TUISettings(),
                history: TUIHistory(),
                safeMode: true
            )
            state.contentIndex = 0
            let renderer = TUIScreenRenderer(
                theme: theme,
                capabilities: capabilities
            )
            let canvas = renderer.render(
                state,
                size: TerminalSize(columns: 100, rows: 28)
            )
            let focused = try XCTUnwrap(
                style(containing: "[ Choose project ]", in: canvas)
            )
            let expected = theme.selectionStyle(
                .primary,
                capabilities: capabilities
            )
            XCTAssertEqual(focused, expected)
            for role in [
                TerminalSelectionRole.normal,
                .warning,
                .destructive,
                .disabled,
            ] {
                let semanticSelection = theme.selectionStyle(
                    role,
                    capabilities: capabilities
                )
                XCTAssertEqual(
                    semanticSelection.foreground,
                    expected.foreground
                )
                XCTAssertEqual(
                    semanticSelection.background,
                    expected.background
                )
                XCTAssertFalse(semanticSelection.dim)
                XCTAssertFalse(semanticSelection.underline)
                XCTAssertFalse(semanticSelection.reverse)
            }
            XCTAssertTrue(focused.bold)
            XCTAssertFalse(focused.underline)
            XCTAssertFalse(focused.dim)
            XCTAssertFalse(focused.reverse)

            let encoded = canvas.encodedLines(
                theme: theme,
                capabilities: capabilities
            ).joined()
            switch capabilities.colorMode {
            case .trueColor:
                XCTAssertTrue(encoded.contains(
                    "\u{1B}[0;1;38;2;0;0;0;48;2;255;255;255m"
                ))
            case .indexed256:
                XCTAssertTrue(encoded.contains(
                    "\u{1B}[0;1;38;5;16;48;5;231m"
                ))
            case .basic, .monochrome:
                XCTAssertTrue(encoded.contains(
                    "\u{1B}[0;1;30;107m"
                ))
            }
            let plain = plainText(canvas)
            XCTAssertFalse(plain.contains("› [ Choose project ]"))
            XCTAssertFalse(plain.contains("> [ Choose project ]"))
        }
    }

    func testSharedSelectionFillsEntireRowAtWideAndNarrowWidths() {
        let theme = TerminalTheme()
        let longRow = TUIRow(
            label: String(repeating: "Long selectable action ", count: 5),
            value: String(repeating: "Detailed value ", count: 6),
            detail: "Synthetic detail.",
            action: .none,
            prominence: .primary
        )
        let modes = [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .indexed256,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .basic,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: true
            ),
        ]
        for capabilities in modes {
            for width in [28, 72] {
                for surroundingBackground in [
                    TerminalColor.rgb(0, 0, 0),
                    TerminalColor.rgb(255, 255, 255),
                ] {
                    var canvas = TerminalCanvas(
                        size: TerminalSize(columns: 80, rows: 3),
                        fill: TerminalStyle(
                            foreground: .default,
                            background: surroundingBackground
                        )
                    )
                    let renderer = TUIScreenRenderer(
                        theme: theme,
                        capabilities: capabilities
                    )
                    renderer.renderControlRow(
                        longRow,
                        selected: true,
                        row: 1,
                        column: 4,
                        width: width,
                        on: &canvas
                    )
                    let expected = theme.selectionStyle(
                        .primary,
                        capabilities: capabilities
                    )
                    XCTAssertTrue(
                        canvas.rows[1][4..<(4 + width)].allSatisfy {
                            $0.style == expected
                        },
                        "\(capabilities) at width \(width)"
                    )
                    XCTAssertNotEqual(canvas.rows[1][3].style, expected)
                    XCTAssertNotEqual(
                        canvas.rows[1][4 + width].style,
                        expected
                    )
                    let text = canvas.rows[1]
                        .filter { !$0.continuation }
                        .map(\.text)
                        .joined()
                    XCTAssertFalse(text.contains("›"))
                    XCTAssertFalse(text.contains("> ["))
                }
            }
        }
    }

    func testNavigationFocusUsesFullRowSelectionWithoutCursorMarker() {
        let theme = TerminalTheme()
        for capabilities in [
            TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            ),
            TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            ),
        ] {
            var state = TUIState(
                settings: TUISettings(),
                history: TUIHistory(),
                safeMode: true
            )
            state.screen = .settings
            state.focus = .navigation
            let canvas = TUIScreenRenderer(
                theme: theme,
                capabilities: capabilities
            ).render(
                state,
                size: TerminalSize(columns: 100, rows: 28)
            )
            let expected = theme.selectionStyle(
                .normal,
                capabilities: capabilities
            )
            XCTAssertTrue(canvas.rows[1][1..<99].allSatisfy {
                $0.style == expected
            })
            let location = canvas.rows[1]
                .filter { !$0.continuation }
                .map(\.text)
                .joined()
            XCTAssertFalse(location.contains("[ Home ]"))
            XCTAssertFalse(location.hasPrefix(">"))
        }
    }

    func testOverlayActionsUsePrimaryDestructiveAndDisabledStyles() throws {
        let theme = TerminalTheme()
        let capabilities = TerminalCapabilities(
            colorMode: .indexed256,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        )
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.overlay = .textInput(
            title: "Output path",
            field: .reportOutput,
            value: "report.json"
        )
        var canvas = renderer.render(
            state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let accept = try XCTUnwrap(
            style(containing: "[ Enter  Accept ]", in: canvas)
        )
        XCTAssertEqual(
            accept,
            theme.selectionStyle(.primary, capabilities: capabilities)
        )
        XCTAssertTrue(accept.bold)
        let acceptRow = try XCTUnwrap(
            canvas.rows.firstIndex { row in
                row.filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                    .contains("[ Enter  Accept ]")
            }
        )
        XCTAssertTrue(canvas.rows[acceptRow][50..<89].allSatisfy {
            $0.style == accept
        })

        state.overlay = .confirmation(
            title: "Apply repairs?",
            message: "Synthetic confirmation.",
            action: .applyRepairs
        )
        canvas = renderer.render(
            state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let apply = try XCTUnwrap(
            style(containing: "[ Enter  Apply repairs ]", in: canvas)
        )
        XCTAssertEqual(
            apply,
            theme.selectionStyle(
                .destructive,
                capabilities: capabilities
            )
        )
        XCTAssertTrue(apply.bold)

        state.overlay = .setupResolution(
            TUISetupResolution(
                field: .scheme,
                title: "Choose scheme",
                message: "The selected choice is unavailable.",
                choices: [
                    TUISetupChoice(
                        label: "Unavailable",
                        detail: "Synthetic disabled choice.",
                        value: .scheme("Unavailable"),
                        recommended: false,
                        enabled: false
                    ),
                ],
                technicalDetails: nil
            )
        )
        canvas = renderer.render(
            state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let disabled = try XCTUnwrap(
            style(containing: "[- Enter  Use choice -]", in: canvas)
        )
        XCTAssertTrue(disabled.dim)
        XCTAssertFalse(disabled.bold)

        state.overlay = .setupResolution(
            TUISetupResolution(
                field: .scheme,
                title: "Choose scheme",
                message: "Select a discovered shared scheme.",
                choices: [
                    TUISetupChoice(
                        label: "Synthetic scheme",
                        detail: "Recommended shared scheme.",
                        value: .scheme("Synthetic scheme"),
                        recommended: true
                    ),
                ],
                technicalDetails: nil
            )
        )
        canvas = renderer.render(
            state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let selected = try XCTUnwrap(
            style(
                of: "S",
                inLineContaining: "Synthetic scheme",
                in: canvas
            )
        )
        let choiceSelection = theme.selectionStyle(
            .normal,
            capabilities: capabilities
        )
        XCTAssertEqual(selected, choiceSelection)
        XCTAssertTrue(selected.bold)
        XCTAssertFalse(selected.underline)
        XCTAssertFalse(selected.reverse)
        let choiceRow = try XCTUnwrap(
            canvas.rows.firstIndex { row in
                row.filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                    .contains("Synthetic scheme")
            }
        )
        for rowIndex in choiceRow...(choiceRow + 1) {
            XCTAssertTrue(
                canvas.rows[rowIndex][11..<89].allSatisfy {
                    $0.style == choiceSelection
                }
            )
        }
        XCTAssertFalse(plainText(canvas).contains("> Synthetic scheme"))
    }

    func testBrandingAppearsOnHomeAndAboutButNotOperationalPages() {
        var settings = TUISettings()
        settings.workflow.projectRoot = "/Synthetic/FictionalWorkspace"
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: true
        )
        state.projectWasExplicitlySelected = true
        let capabilities = TerminalCapabilities(
            colorMode: .basic,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        for size in [
            TerminalSize(columns: 80, rows: 24),
            TerminalSize(columns: 100, rows: 28),
            TerminalSize(columns: 128, rows: 32),
            TerminalSize(columns: 160, rows: 50),
        ] {
            state.screen = .project
            let home = plainText(renderer.render(state, size: size))
            XCTAssertTrue(
                home.contains("█")
                    || home.contains("▀")
                    || home.contains("▄"),
                "\(size)"
            )
            XCTAssertFalse(home.contains("SWIFTDELTA"), "\(size)")

            state.screen = .settings
            state.settingsSection = .about
            let aboutCanvas = renderer.render(state, size: size)
            let about = plainText(aboutCanvas)
            XCTAssertTrue(
                about.contains("█")
                    || about.contains("▀")
                    || about.contains("▄"),
                "\(size)"
            )
            XCTAssertTrue(about.contains("Apache License 2.0"), "\(size)")
            assertBrandArtworkMatches(
                home: renderer.render(
                    withScreen(.project, from: state),
                    size: size
                ),
                about: aboutCanvas,
                size: size
            )

            state.screen = .findings
            state.report = syntheticReport()
            let analysis = plainText(renderer.render(state, size: size))
            XCTAssertFalse(analysis.contains("△"), "\(size)")
            XCTAssertFalse(analysis.contains("█"), "\(size)")
            XCTAssertFalse(analysis.contains("▀"), "\(size)")
            XCTAssertFalse(analysis.contains("▄"), "\(size)")
            XCTAssertFalse(analysis.contains("SWIFTDELTA"), "\(size)")
            XCTAssertTrue(analysis.contains("Analysis"), "\(size)")
        }
    }

    private func withScreen(
        _ screen: TUIScreen,
        from state: TUIState
    ) -> TUIState {
        var copy = state
        copy.screen = screen
        return copy
    }

    private func assertBrandArtworkMatches(
        home: TerminalCanvas,
        about: TerminalCanvas,
        size: TerminalSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let contentWidth = size.columns - 4
        let layout = TUILayoutMode(columns: contentWidth)
        let region: (rows: Range<Int>, columns: Range<Int>)
        switch layout {
        case .wide:
            let brandWidth = min(48, max(44, contentWidth / 3))
            region = (3..<size.rows - 2, 2..<2 + brandWidth)
        case .medium:
            region = (3..<size.rows - 2, 2..<28)
        case .narrow:
            region = (
                3..<min(
                    size.rows - 2,
                    3 + DeltaMark.compactTerminalSize.rows + 1
                ),
                2..<size.columns - 2
            )
        }
        for row in region.rows {
            XCTAssertEqual(
                Array(home.rows[row][region.columns]),
                Array(about.rows[row][region.columns]),
                "Brand artwork differs at row \(row) for \(size)",
                file: file,
                line: line
            )
        }
    }

    func testFindingAndRepairReportsExposeReadableSemanticHierarchy() {
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        )
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.screen = .findings
        state.report = syntheticReport(findings: [
            syntheticFinding(
                identifier: "readable",
                title: "Synthetic declaration changed",
                severity: .error
            ),
        ])
        state.contentIndex = TUIContentRows.resultControlCount(for: state)
        var output = plainText(
            renderer.render(
                state,
                size: TerminalSize(columns: 160, rows: 42)
            )
        )
        XCTAssertTrue(output.contains("✕ Synthetic declaration changed"))
        XCTAssertTrue(output.contains("Sources/App.swift:4"))
        XCTAssertTrue(output.contains("sdk"))
        XCTAssertTrue(output.contains("high confidence"))
        let selectedFindingStyle = style(
            of: "✕",
            inLineContaining: "Synthetic declaration changed",
            in: renderer.render(
                state,
                size: TerminalSize(columns: 160, rows: 42)
            )
        )
        XCTAssertEqual(
            selectedFindingStyle?.foreground,
            TerminalTheme().selectionForeground
        )
        XCTAssertEqual(
            selectedFindingStyle?.background,
            TerminalTheme().selectionBackground
        )
        XCTAssertEqual(selectedFindingStyle?.underline, false)
        XCTAssertEqual(selectedFindingStyle?.reverse, false)

        state.detailPresentation = .finding
        output = plainText(
            renderer.render(
                state,
                size: TerminalSize(columns: 100, rows: 32)
            )
        )
        XCTAssertTrue(output.contains("Summary"))
        XCTAssertTrue(output.contains("Source"))
        XCTAssertTrue(output.contains("SDK evidence"))
        XCTAssertTrue(output.contains("Baseline declaration"))
        XCTAssertTrue(output.contains("Candidate declaration"))

        let safe = syntheticRepair(identifier: "repair.safe")
        let review = ProposedRepair(
            repairIdentifier: "repair.review",
            relatedFindingIdentifier: "finding.review",
            evidenceSource: .mechanicalSignatureChange,
            language: safe.language,
            filePath: safe.filePath,
            sourceRange: safe.sourceRange,
            originalText: safe.originalText,
            replacementText: "reviewed",
            fileFingerprint: safe.fileFingerprint,
            confidence: .medium,
            safety: .reviewRequired,
            explanation: "Synthetic review-only proposal.",
            verificationRequirement: .candidateBuild
        )
        let conflicting = syntheticRepair(identifier: "repair.conflict")
        state.screen = .repair
        state.detailPresentation = .none
        state.repairPlan = RepairPlan(
            projectRoot: "/Synthetic/FictionalWorkspace",
            repairs: [safe, review, conflicting],
            conflicts: [
                RepairConflict(
                    kind: .contradictory,
                    repairIdentifiers: [conflicting.repairIdentifier],
                    explanation: "Synthetic conflict."
                ),
            ]
        )
        state.contentIndex = TUIContentRows.rows(for: state).count
        output = plainText(
            renderer.render(
                state,
                size: TerminalSize(columns: 160, rows: 42)
            )
        )
        XCTAssertTrue(output.contains("✓ Ready · Compiler Fix-it"))
        XCTAssertTrue(output.contains("◌ Needs Review · Mechanical"))
        XCTAssertTrue(output.contains("⊗ conflict"))

        let ascii = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: true,
            reducedMotion: true,
            mouseSupported: false
        )
        output = plainText(
            TUIScreenRenderer(
                theme: TerminalTheme(),
                capabilities: ascii
            ).render(
                state,
                size: TerminalSize(columns: 160, rows: 42)
            )
        )
        XCTAssertTrue(output.contains("+ Ready · Compiler Fix-it"))
        XCTAssertTrue(output.contains("? Needs Review · Mechanical"))
        XCTAssertTrue(output.contains("! conflict"))
        XCTAssertFalse(output.contains("✓"))
        XCTAssertFalse(output.contains("◌"))
        XCTAssertFalse(output.contains("⊗"))
    }

    func testRepairDiffUsesUnifiedAndSideBySideLayoutsForStructuralEdits()
        throws
    {
        let directory = try TUITestDirectory()
        let source = directory.url.appendingPathComponent(
            "Sources/Feature.swift"
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            (1...14).map { "context line \($0)" }
                .joined(separator: "\n").utf8
        ).write(to: source)
        let range = RepairSourceRange(
            start: RepairSourcePosition(line: 8, column: 5, utf8Offset: 40),
            end: RepairSourcePosition(line: 10, column: 6, utf8Offset: 90)
        )
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.diff",
            findingStableKey: "finding.diff|Sources/Feature.swift|8",
            findingIdentifier: "finding.diff",
            title: "Structured migration",
            location: SourceLocation(
                path: "Sources/Feature.swift",
                line: 8,
                column: 5
            ),
            status: .needsValidation,
            repairSource: "Apple Foundation Models",
            confidence: .medium,
            summary: "3 coordinated edits",
            explanation: "Synthetic structural migration.",
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: "Sources/Feature.swift",
                    originalText: "oldCall(\n    value: \"你好 👋\"\n)",
                    replacementText: "await newCall(\n    \"你好 👋\"\n)",
                    sourceRange: range
                ),
                RepairCandidateEditPresentation(
                    operation: "insertBefore",
                    filePath: "Sources/Feature.swift",
                    originalText: "",
                    replacementText: "import FictionalSDK\n",
                    sourceRange: RepairSourceRange(
                        start: RepairSourcePosition(
                            line: 1,
                            column: 1,
                            utf8Offset: 0
                        ),
                        end: RepairSourcePosition(
                            line: 1,
                            column: 1,
                            utf8Offset: 0
                        )
                    )
                ),
                RepairCandidateEditPresentation(
                    operation: "delete",
                    filePath: "Sources/Feature.swift",
                    originalText: "@available(*, deprecated)\n",
                    replacementText: "",
                    sourceRange: RepairSourceRange(
                        start: RepairSourcePosition(
                            line: 3,
                            column: 1,
                            utf8Offset: 12
                        ),
                        end: RepairSourcePosition(
                            line: 4,
                            column: 1,
                            utf8Offset: 39
                        )
                    )
                ),
            ]
        )

        let unified = TUIRepairDiff.lines(
            for: candidate,
            width: 72,
            ascii: false,
            projectRoot: directory.url.path
        )
        XCTAssertTrue(unified.contains { $0.hasPrefix("@@ -8,") })
        XCTAssertTrue(unified.contains { $0.contains("- oldCall(") })
        XCTAssertTrue(unified.contains { $0.contains("+ await newCall(") })
        XCTAssertTrue(unified.contains { $0.contains("你好 👋") })
        XCTAssertTrue(unified.contains { $0.contains("insertBefore") })
        XCTAssertTrue(unified.contains { $0.contains("delete") })
        XCTAssertTrue(unified.contains { $0.contains("context line 6") })
        XCTAssertTrue(unified.contains { $0.contains("context line 12") })

        let sideBySide = TUIRepairDiff.lines(
            for: candidate,
            width: 132,
            ascii: false,
            projectRoot: directory.url.path
        )
        XCTAssertTrue(sideBySide.contains {
            $0.contains("BASELINE") && $0.contains("CANDIDATE")
        })
        XCTAssertTrue(sideBySide.contains {
            $0.contains("oldCall") && $0.contains("newCall")
        })
    }

    func testRepairSelectionUsesCheckmarkAndDiffUsesSemanticHalves()
        throws
    {
        let directory = try TUITestDirectory()
        let source = directory.url.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: source)
        let repair = syntheticRepair()
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.colored-diff",
            findingStableKey: "finding.one|Sources/App.swift|1",
            findingIdentifier: "finding.one",
            title: "Exact compiler migration",
            location: SourceLocation(path: "Sources/App.swift", line: 1),
            status: .ready,
            repairSource: "Compiler Fix-it",
            confidence: .high,
            summary: "Replace token",
            explanation: "Synthetic exact edit.",
            repairIdentifiers: [repair.repairIdentifier],
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: repair.filePath,
                    originalText: "oldCall(value)",
                    replacementText: "newCall(value)",
                    sourceRange: repair.sourceRange
                ),
            ]
        )
        var settings = TUISettings()
        settings.workflow.projectRoot = directory.url.path
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: true
        )
        state.screen = .repair
        state.repairPlan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [repair]
        )
        state.repairCandidates = [candidate]
        state.selectedRepairIDs = [repair.repairIdentifier]
        state.contentIndex = TUIContentRows.rows(for: state).count
        let theme = TerminalTheme()
        let capabilities = TerminalCapabilities(
            colorMode: .trueColor,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: true
        )
        let canvas = TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        ).render(
            state,
            size: TerminalSize(columns: 240, rows: 44)
        )
        XCTAssertTrue(plainText(canvas).contains("[✓]"))
        let diffLines = TUIRepairDiff.lines(
            for: candidate,
            width: 132,
            ascii: false,
            projectRoot: directory.url.path
        )
        var diffCanvas = TerminalCanvas(
            size: TerminalSize(columns: 132, rows: diffLines.count)
        )
        TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        ).drawWrapped(
            diffLines,
            row: 0,
            column: 0,
            width: 132,
            height: diffLines.count,
            scroll: 0,
            on: &diffCanvas,
            diff: true
        )
        let removedRow = try XCTUnwrap(diffCanvas.rows.first { row in
            let text = row.filter { !$0.continuation }.map(\.text).joined()
            return text.contains("oldCall") && row.contains {
                $0.style.foreground
                    == theme.style(
                        .diffRemoved,
                        highContrast: false
                    ).foreground
            }
        })
        let addedRow = try XCTUnwrap(diffCanvas.rows.first { row in
            let text = row.filter { !$0.continuation }.map(\.text).joined()
            return text.contains("newCall") && row.contains {
                $0.style.foreground
                    == theme.style(
                        .diffAdded,
                        highContrast: false
                    ).foreground
            }
        })
        XCTAssertTrue(removedRow.contains {
            $0.style.foreground
                == theme.style(.diffRemoved, highContrast: false).foreground
        })
        XCTAssertTrue(addedRow.contains {
            $0.style.foreground
                == theme.style(.diffAdded, highContrast: false).foreground
        })

        let asciiCapabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: true,
            reducedMotion: true,
            mouseSupported: false
        )
        let ascii = plainText(
            TUIScreenRenderer(
                theme: theme,
                capabilities: asciiCapabilities
            ).render(
                state,
                size: TerminalSize(columns: 100, rows: 28)
            )
        )
        XCTAssertTrue(ascii.contains("[OK]"))
        XCTAssertFalse(ascii.contains("[✓]"))
    }

    func testRejectedDraftIsNotRenderedAsAConflictAndEditorIsReadable()
        throws
    {
        let directory = try TUITestDirectory()
        let draft = syntheticRepairDraft()
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.rejected-draft",
            draftIdentifier: draft.draftIdentifier,
            findingStableKey: draft.findingStableKey,
            findingIdentifier: draft.findingIdentifier,
            title: draft.findingTitle,
            location: draft.location,
            symbol: draft.symbol,
            status: .rejected,
            repairSource: "Apple Foundation Models",
            confidence: .medium,
            summary: "Retained draft",
            explanation: draft.explanation,
            evidence: draft.evidence,
            risks: ["sourceAnchor: correct the anchor"],
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: draft.sourceFile,
                    originalText: "ol",
                    replacementText: "new"
                ),
            ]
        )
        let service = FakeTUIOperationService(
            .failure("unused")
        )
        let controller = makeTUIController(
            screen: .repair,
            service: service,
            directory: directory
        )
        controller.accept(
            .repairPlan(
                RepairPlanningOutput(
                    plan: RepairPlan(
                        projectRoot: directory.url.path,
                        repairs: [],
                        conflicts: []
                    ),
                    referenceResolutionCoverage: [],
                    repairCandidates: [candidate],
                    repairDrafts: [draft]
                )
            )
        )
        controller.state.contentIndex =
            TUIContentRows.rows(for: controller.state).count
        let renderer = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .ascii,
                highContrast: true,
                reducedMotion: true,
                mouseSupported: false
            )
        )
        var output = plainText(
            renderer.render(
                controller.state,
                size: TerminalSize(columns: 160, rows: 42)
            )
        )
        XCTAssertTrue(output.contains("Failed"))
        XCTAssertTrue(output.contains("Failed · Apple Foundation Models"))
        XCTAssertFalse(output.contains("conflict · Apple Foundation Models"))

        controller.handle(.enter, terminalSize: .minimum)
        controller.handle(.character("e"), terminalSize: .minimum)
        output = plainText(
            renderer.render(
                controller.state,
                size: TerminalSize(columns: 100, rows: 28)
            )
        )
        XCTAssertTrue(output.contains("Edit Draft Repair"))
        XCTAssertTrue(output.contains("Original anchor"))
        XCTAssertTrue(output.contains("Proposed source"))
        XCTAssertTrue(output.contains("Ctrl-S Save"))
    }

    func testAnalysisInspectorShowsBoundedHighlightedSourceContext() throws {
        let directory = try TUITestDirectory()
        let project = directory.url.appendingPathComponent(
            "SyntheticProject",
            isDirectory: true
        )
        let source = project.appendingPathComponent(
            "Sources/Ünicode.swift"
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            struct Example {
                let first = 1
                let middle = 2
                let selected = "Δ"
                let last = 3
            }
            """.utf8
        ).write(to: source)
        let finding = syntheticFinding(
            identifier: "source-context",
            title: "Synthetic source context",
            severity: .warning,
            path: "Sources/Ünicode.swift"
        )
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.screen = .findings
        state.report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            projectRoot: project.path,
            findings: [finding]
        )
        state.contentIndex = TUIContentRows.resultControlCount(for: state)
        state.detailPresentation = .finding
        let output = plainText(
            TUIScreenRenderer(
                theme: TerminalTheme(),
                capabilities: TerminalCapabilities(
                    colorMode: .trueColor,
                    symbolMode: .unicode,
                    highContrast: false,
                    reducedMotion: true,
                    mouseSupported: false
                )
            ).render(
                state,
                size: TerminalSize(columns: 128, rows: 32)
            )
        )

        XCTAssertTrue(output.contains("Source context"))
        XCTAssertTrue(output.contains(#"let selected = "Δ""#))
        XCTAssertTrue(output.contains(">    4 │"))
    }

    private func plainText(_ canvas: TerminalCanvas) -> String {
        canvas.rows.map { row in
            row.filter { !$0.continuation }.map(\.text).joined()
        }.joined(separator: "\n")
    }

    private func style(
        containing text: String,
        in canvas: TerminalCanvas
    ) -> TerminalStyle? {
        for row in canvas.rows {
            let line = row.filter { !$0.continuation }.map(\.text).joined()
            guard line.contains(text) else { continue }
            return row.first { $0.text == "[" }?.style
        }
        return nil
    }

    private func style(
        of token: String,
        inLineContaining text: String,
        in canvas: TerminalCanvas
    ) -> TerminalStyle? {
        for row in canvas.rows {
            let line = row.filter { !$0.continuation }.map(\.text).joined()
            guard line.contains(text) else { continue }
            if let cell = row.first(where: { $0.text == token }) {
                return cell.style
            }
        }
        return nil
    }
}
