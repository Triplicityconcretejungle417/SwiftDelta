//===--- TUIInteractionTests.swift - SwiftDelta ------------------------------------------===//
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

final class TUIInteractionTests: XCTestCase {
    func testPrivateProjectSelectionsAreNotPersistedWithoutHistoryConsent()
        throws
    {
        let directory = try TUITestDirectory()
        let store = TUISettingsStore(
            applicationSupportDirectory:
                directory.url.appendingPathComponent("Application Support")
        )
        var settings = TUISettings()
        settings.workflow.projectRoot = directory.url.path
        settings.workflow.workspacePath = "Private.xcworkspace"
        settings.workflow.scheme = "PrivateScheme"
        settings.interaction.historyEnabled = false
        settings.privacy.rememberRecentProjects = false
        var state = TUIState(
            settings: settings,
            history: TUIHistory(),
            safeMode: false
        )
        state.screen = .settings
        state.settingsSection = .appearance
        let controller = TUIController(
            state: state,
            settingsStore: store,
            coordinator: TUIOperationCoordinator(
                service: FakeTUIOperationService(
                    .result(.discovery(
                        DiscoveryResult(
                            root: directory.url.path,
                            containers: [],
                            swiftFiles: []
                        )
                    ))
                )
            )
        )
        controller.state.focus = .content
        let highContrastIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "High contrast"
            }
        )
        controller.state.contentIndex = highContrastIndex

        controller.handle(.character(" "), terminalSize: .minimum)

        let persisted = store.loadSettings(safeMode: false).settings
        XCTAssertNotEqual(persisted.workflow.projectRoot, directory.url.path)
        XCTAssertNil(persisted.workflow.workspacePath)
        XCTAssertNil(persisted.workflow.scheme)
        XCTAssertTrue(controller.state.settings.appearance.highContrast)
        XCTAssertEqual(controller.state.settings.workflow.projectRoot, directory.url.path)
    }

    func testOperationSummaryRequiresRecentProjectConsent() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            service: service,
            directory: directory
        )
        controller.state.safeMode = false
        controller.state.settings.interaction.historyEnabled = true
        controller.state.settings.privacy.retainOperationSummaries = true

        controller.recordHistory(
            operation: "SDK analysis",
            outcome: "succeeded"
        )

        XCTAssertTrue(controller.state.history.entries.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: controller.settingsStore.historyURL.path
            )
        )

        controller.state.settings.privacy.rememberRecentProjects = true
        controller.recordHistory(
            operation: "SDK analysis",
            outcome: "succeeded"
        )

        XCTAssertEqual(controller.state.history.entries.count, 1)
        XCTAssertEqual(
            controller.state.history.entries.first?.projectPath,
            directory.url.path
        )
    }

    func testKeyboardNavigationFocusAndDialogs() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.discovery(
                DiscoveryResult(
                    root: directory.url.path,
                    containers: [],
                    swiftFiles: []
                )
            ))
        )
        let controller = makeTUIController(
            service: service,
            directory: directory
        )

        controller.state.focus = .content
        controller.handle(
            .down,
            terminalSize: TerminalSize(columns: 100, rows: 28)
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
        ).render(
            controller.state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let keyboardSelectedRow = try XCTUnwrap(
            canvas.rows.first { row in
                row.filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                    .contains("Baseline Xcode")
            }
        )
        XCTAssertGreaterThanOrEqual(
            keyboardSelectedRow.count {
                $0.style.background == theme.selectionBackground
            },
            70
        )
        controller.handle(
            .up,
            terminalSize: TerminalSize(columns: 100, rows: 28)
        )
        controller.handle(.tab, terminalSize: .minimum)
        XCTAssertEqual(controller.state.focus, .content)
        controller.handle(.backTab, terminalSize: .minimum)
        XCTAssertEqual(controller.state.focus, .content)

        controller.handle(.character("?"), terminalSize: .minimum)
        XCTAssertEqual(controller.state.overlay, .shortcuts)
        controller.handle(.escape, terminalSize: .minimum)
        XCTAssertEqual(controller.state.overlay, .none)

        controller.handle(.character("q"), terminalSize: .minimum)
        guard case .confirmation(_, _, .quit) = controller.state.overlay else {
            return XCTFail("Expected quit confirmation")
        }
        controller.handle(.character("n"), terminalSize: .minimum)
        XCTAssertFalse(controller.state.shouldQuit)
    }

    func testMouseNavigationAndWheelScrollingMirrorKeyboardAccess() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            service: service,
            directory: directory
        )
        let size = TerminalSize(columns: 100, rows: 28)

        let rows = TUIContentRows.rows(for: controller.state)
        let candidateIndex = try XCTUnwrap(rows.firstIndex {
            $0.label == "Candidate Xcode"
        })
        let displayIndex = try XCTUnwrap(
            TUIContentRows.displayedRowIndices(for: rows).firstIndex {
                $0 == candidateIndex
            }
        )
        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .press,
                button: 0,
                column: 2,
                row: 3 + displayIndex
            )),
            terminalSize: size
        )
        XCTAssertEqual(controller.state.screen, .project)
        XCTAssertEqual(controller.state.contentIndex, candidateIndex)

        controller.state.focus = .content
        controller.state.contentIndex = 0
        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .scrollDown,
                button: 0,
                column: 40,
                row: 10
            )),
            terminalSize: size
        )
        XCTAssertEqual(controller.state.contentIndex, 3)
    }

    func testMouseSelectionUsesTheVisibleWindowOfAScrolledForm() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.report(syntheticReport()))
            ),
            directory: directory
        )
        controller.state.advancedOptionsExpanded = true
        let rows = TUIContentRows.rows(for: controller.state)
        let size = TerminalSize(columns: 80, rows: 24)
        let visibleCount = 16
        controller.state.contentIndex = rows.count - 1
        let display = TUIContentRows.displayedRowIndices(for: rows)
        let selectedDisplay = try XCTUnwrap(
            display.firstIndex { $0 == rows.count - 1 }
        )
        let firstVisible = min(
            max(0, selectedDisplay - visibleCount / 2),
            max(0, display.count - visibleCount)
        )
        let selectableDisplay = try XCTUnwrap(
            (firstVisible..<min(display.count, firstVisible + visibleCount))
                .first { display[$0] != nil }
        )
        let expectedFirstVisible = try XCTUnwrap(display[selectableDisplay])

        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .press,
                button: 0,
                column: 2,
                row: 3 + selectableDisplay - firstVisible
            )),
            terminalSize: size
        )

        XCTAssertEqual(controller.state.contentIndex, expectedFirstVisible)
    }

    func testMouseSelectionAccountsForFindingGroupHeadersAndScrolling()
        throws
    {
        let directory = try TUITestDirectory()
        let findings = (0..<20).map { index in
            syntheticFinding(
                identifier: "finding.\(index)",
                title: "Finding \(index)",
                severity: index.isMultiple(of: 2) ? .warning : .notice
            )
        }
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(findings: findings),
            service: FakeTUIOperationService(
                .result(.report(syntheticReport()))
            ),
            directory: directory
        )
        controller.state.contentIndex =
            TUIContentRows.resultControlCount(for: controller.state) + 15

        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .press,
                button: 0,
                column: 2,
                row: 6
            )),
            terminalSize: TerminalSize(columns: 80, rows: 24)
        )

        XCTAssertEqual(controller.state.contentIndex, 15)
    }

    func testRepairMouseSelectionAccountsForSummaryRows() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: RepairPlan(
                generatedAt: Date(timeIntervalSince1970: 100),
                projectRoot: directory.url.path,
                repairs: []
            ),
            service: FakeTUIOperationService(
                .result(.repairPlan(RepairPlanningOutput(
                    plan: RepairPlan(
                        generatedAt: Date(timeIntervalSince1970: 100),
                        projectRoot: directory.url.path,
                        repairs: []
                    ),
                    referenceResolutionCoverage: []
                )))
            ),
            directory: directory
        )
        let rows = TUIContentRows.rows(for: controller.state)
        let planningIssueIndex = rows.firstIndex {
            $0.label == "Apply Selected Repairs"
        }
        guard let planningIssueIndex else {
            return XCTFail("Expected repair action")
        }

        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .press,
                button: 0,
                column: 2,
                row: 5 + planningIssueIndex
            )),
            terminalSize: TerminalSize(columns: 120, rows: 38)
        )

        XCTAssertEqual(controller.state.contentIndex, planningIssueIndex)
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(controller.state.overlay, .none)
    }

    func testApplyRepairActionIsDisabledWithoutASelection() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: RepairPlan(
                generatedAt: Date(timeIntervalSince1970: 100),
                projectRoot: directory.url.path,
                repairs: []
            ),
            service: FakeTUIOperationService(
                .result(.repairsApplied(0))
            ),
            directory: directory
        )
        let rows = TUIContentRows.rows(for: controller.state)
        guard let applyIndex = rows.firstIndex(where: {
            $0.label == "Apply Selected Repairs"
        }) else {
            return XCTFail("Expected apply action")
        }

        XCTAssertFalse(rows[applyIndex].enabled)
        XCTAssertEqual(
            rows[applyIndex].detail,
            "Select at least one applicable, conflict-free repair first."
        )
        controller.state.contentIndex = applyIndex
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(controller.state.overlay, .none)
    }

    func testRepairShowsCoverageAndDispositionForEveryAnalysisFinding()
        throws
    {
        let directory = try TUITestDirectory()
        let findings = [
            syntheticFinding(
                identifier: "finding.safe",
                title: "Mechanically repairable",
                severity: .warning,
                path: "Sources/Safe.swift"
            ),
            syntheticFinding(
                identifier: "finding.review",
                title: "Manual review",
                severity: .warning,
                path: "Sources/Review.swift"
            ),
        ]
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [syntheticRepair(identifier: "repair.safe")]
        )
        let dispositions = [
            RepairFindingDisposition(
                findingStableKey: findings[0].stableKey,
                findingIdentifier: findings[0].findingID,
                title: findings[0].title,
                location: findings[0].location,
                kind: .automaticallySafe,
                reason: "Exact compiler fix-it.",
                repairIdentifiers: ["repair.safe"]
            ),
            RepairFindingDisposition(
                findingStableKey: findings[1].stableKey,
                findingIdentifier: findings[1].findingID,
                title: findings[1].title,
                location: findings[1].location,
                kind: .manualReviewRequired,
                reason: "No exact edit was supplied."
            ),
        ]
        let coverage = RepairCoverageSummary(
            findingsReceived: 2,
            mechanicallyRepairable: 1,
            modelProposed: 0,
            reviewOnly: 1,
            conflicting: 0,
            unsupported: 0,
            planningFailures: 0
        )
        let output = RepairPlanningOutput(
            plan: plan,
            referenceResolutionCoverage: [],
            findingDispositions: dispositions,
            repairCoverage: coverage
        )
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(findings: findings),
            service: FakeTUIOperationService(.result(.repairPlan(output))),
            directory: directory
        )

        controller.accept(.repairPlan(output))
        controller.state.repairFilter = .all

        XCTAssertEqual(controller.state.repairFindingDispositions.count, 2)
        XCTAssertEqual(controller.state.repairCoverage, coverage)
        let rows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(rows.contains { $0.label == "Repair funnel" })
        XCTAssertTrue(rows.contains {
            $0.label == "Safe repair" && $0.value == "Mechanically repairable"
        })
        XCTAssertTrue(rows.contains {
            $0.label == "Review required" && $0.value == "Manual review"
        })
    }

    func testFoundationModelsControlsAppearOnlyForAvailableOnDeviceModel() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(),
            service: FakeTUIOperationService(
                .result(.repairPlan(RepairPlanningOutput(
                    plan: RepairPlan(
                        projectRoot: directory.url.path,
                        repairs: []
                    ),
                    referenceResolutionCoverage: []
                )))
            ),
            directory: directory
        )
        controller.state.advancedOptionsExpanded = true

        var rows = TUIContentRows.rows(for: controller.state)
        XCTAssertFalse(rows.contains { $0.label == "Apple Foundation Models" })
        XCTAssertFalse(rows.contains { $0.label == "Reasoning level" })
        XCTAssertFalse(rows.contains { $0.label == "Model timeout" })

        controller.state.foundationModelStatus = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep"
        )
        rows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(rows.contains { $0.label == "Apple Foundation Models" })
        XCTAssertTrue(rows.contains { $0.label == "Reasoning level" })
        XCTAssertTrue(rows.contains { $0.label == "Model candidate limit" })
        XCTAssertFalse(rows.contains { $0.label == "Model provider" })
        XCTAssertFalse(rows.contains {
            $0.label.localizedCaseInsensitiveContains("fallback")
        })

        controller.state.foundationModelStatus = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 26.4",
            reasoningLevel: "unsupported"
        )
        rows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(rows.contains { $0.label == "Apple Foundation Models" })
        XCTAssertFalse(rows.contains { $0.label == "Reasoning level" })
    }

    func testFoundationModelsAreAutomaticWhenLocalModelIsAvailable() {
        var workflow = TUIWorkflowSettings()
        workflow.foundationModelsEnabled = false
        workflow.foundationModelCandidateLimit = 40
        let service = CoreTUIOperationService()

        XCTAssertNil(
            service.foundationModelOptions(
                workflow,
                status: .unavailable
            )
        )
        let available = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep"
        )
        XCTAssertEqual(
            service.foundationModelOptions(
                workflow,
                status: available
            )?.maximumCandidates,
            40
        )
    }

    func testRepairShowsBoundedModelPlanningAccounting() throws {
        let directory = try TUITestDirectory()
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            referenceResolutionCoverage: [],
            foundationModelSummary: FoundationModelPlanningSummary(
                findingsConsidered: 40,
                processed: 25,
                skipped: 4,
                deduplicated: 3,
                deferredByLimit: 8,
                rejected: 24,
                convertedIntoRepairs: 1,
                timedOut: 0,
                cancelled: 0
            )
        )
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(),
            service: FakeTUIOperationService(
                .result(.repairPlan(output))
            ),
            directory: directory
        )
        controller.state.foundationModelStatus = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep"
        )
        controller.accept(.repairPlan(output))

        let row = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).first {
                $0.label == "On-device model planning"
            }
        )
        XCTAssertTrue(row.value.contains("25 processed"))
        XCTAssertTrue(row.value.contains("1 repair"))
        XCTAssertTrue(row.detail.contains("4 insufficient evidence"))
        XCTAssertTrue(row.detail.contains("3 deduplicated"))
        XCTAssertTrue(row.detail.contains("8 deferred by limit"))
    }

    func testEnteringRepairRefreshesLocalModelCapability() throws {
        let directory = try TUITestDirectory()
        let available = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep"
        )
        let controller = makeTUIController(
            report: syntheticReport(),
            service: FakeTUIOperationService(
                .result(.repairPlan(RepairPlanningOutput(
                    plan: RepairPlan(
                        projectRoot: directory.url.path,
                        repairs: []
                    ),
                    referenceResolutionCoverage: []
                )))
            ),
            directory: directory,
            foundationModelStatusProvider: { available }
        )
        XCTAssertFalse(controller.state.foundationModelStatus.isAvailable)

        controller.selectScreen(.repair)

        XCTAssertTrue(controller.state.foundationModelStatus.isAvailable)
    }

    func testRepeatedRepairDispositionsAreGroupedAndRemainInspectable()
        throws
    {
        let directory = try TUITestDirectory()
        let findings = [
            syntheticFinding(
                identifier: "repeat.1",
                title: "Repeated signature change",
                severity: .warning,
                path: "Sources/A.swift"
            ),
            syntheticFinding(
                identifier: "repeat.2",
                title: "Repeated signature change",
                severity: .warning,
                path: "Sources/B.swift"
            ),
        ]
        let dispositions = findings.map {
            RepairFindingDisposition(
                findingStableKey: $0.stableKey,
                findingIdentifier: $0.findingID,
                title: $0.title,
                location: $0.location,
                kind: .manualReviewRequired,
                reason: "No exact compiler edit was supplied."
            )
        }
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            referenceResolutionCoverage: [],
            findingDispositions: dispositions
        )
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(findings: findings),
            service: FakeTUIOperationService(
                .result(.repairPlan(output))
            ),
            directory: directory
        )
        controller.accept(.repairPlan(output))
        controller.state.repairFilter = .all
        let rows = TUIContentRows.rows(for: controller.state)
        let index = try XCTUnwrap(
            rows.firstIndex {
                $0.label == "Review required ×2"
            }
        )

        controller.state.contentIndex = index
        controller.handle(.enter, terminalSize: .minimum)

        guard case let .message(_, message, details) =
            controller.state.overlay
        else {
            return XCTFail("Expected disposition details")
        }
        XCTAssertTrue(message.contains("No exact compiler edit"))
        XCTAssertTrue(details?.contains("Occurrences: 2") == true)
        XCTAssertTrue(details?.contains("Sources/A.swift") == true)
        XCTAssertTrue(details?.contains("Sources/B.swift") == true)
    }

    func testRepairPlanningFailuresUseHumanReadableStatuses() throws {
        let directory = try TUITestDirectory()
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [],
            planningFailures: [
                AnalysisFailure(
                    kind: .parse,
                    message:
                        "Apple Foundation Models returned invalid structured output.",
                    location: SourceLocation(
                        path: "Sources/App.swift",
                        line: 7
                    )
                ),
            ]
        )
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: plan,
            service: FakeTUIOperationService(
                .result(.repairPlan(RepairPlanningOutput(
                    plan: plan,
                    referenceResolutionCoverage: []
                )))
            ),
            directory: directory
        )

        controller.state.repairFilter = .failed
        let rows = TUIContentRows.rows(for: controller.state)

        XCTAssertTrue(rows.contains {
            $0.label == "Invalid model response"
                && $0.value.contains("Sources/App.swift:7")
        })
        XCTAssertFalse(rows.contains {
            $0.label == "Planning issue" || $0.value == "parse"
        })
    }

    func testMissingReportOutputOpensValidatedSheetAndResumesExport()
        throws
    {
        let directory = try TUITestDirectory()
        let output = directory.url.appendingPathComponent("report.json")
        let service = FakeTUIOperationService(
            .result(.reportExported(output.path))
        )
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(),
            service: service,
            directory: directory
        )
        controller.state.settings.workflow.reportFormat = .json
        controller.state.settings.workflow.reportOutputPath = nil

        controller.start(.exportReport)

        guard case var .requiredInput(input) = controller.state.overlay else {
            return XCTFail("Expected a required output-path sheet")
        }
        XCTAssertEqual(input.field, .reportOutput)
        XCTAssertEqual(input.pendingOperation, .exportReport)
        XCTAssertTrue(input.value.hasSuffix("SwiftDelta-report.json"))
        XCTAssertFalse(input.value.hasPrefix(directory.url.path + "/"))

        input.value = directory.url.appendingPathComponent(
            "missing/report.json"
        ).path
        controller.state.overlay = .requiredInput(input)
        controller.handle(.enter, terminalSize: .minimum)
        guard case let .requiredInput(rejected) = controller.state.overlay else {
            return XCTFail("Expected inline path validation")
        }
        XCTAssertNotNil(rejected.validationMessage)
        XCTAssertTrue(service.kinds().isEmpty)

        input.value = output.path
        input.validationMessage = nil
        controller.state.overlay = .requiredInput(input)
        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        XCTAssertEqual(service.kinds(), [.exportReport])
        XCTAssertEqual(
            controller.state.settings.workflow.reportOutputPath,
            output.path
        )
    }

    func testMissingRepairPlanOutputCanCancelOrResumeExport() throws {
        let directory = try TUITestDirectory()
        let output = directory.url.appendingPathComponent("plan.diff")
        let service = FakeTUIOperationService(
            .result(.repairPlanExported(output.path))
        )
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            service: service,
            directory: directory
        )

        controller.start(.exportRepairPlan)
        guard case .requiredInput = controller.state.overlay else {
            return XCTFail("Expected a required repair-plan path sheet")
        }
        controller.handle(.escape, terminalSize: .minimum)
        XCTAssertEqual(controller.state.overlay, .none)
        XCTAssertTrue(service.kinds().isEmpty)

        controller.start(.exportRepairPlan)
        guard case var .requiredInput(input) = controller.state.overlay else {
            return XCTFail("Expected a required repair-plan path sheet")
        }
        XCTAssertTrue(input.value.hasSuffix("SwiftDelta-repair-plan.diff"))
        XCTAssertFalse(input.value.hasPrefix(directory.url.path + "/"))
        input.value = output.path
        controller.state.overlay = .requiredInput(input)
        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        XCTAssertEqual(service.kinds(), [.exportRepairPlan])
        XCTAssertEqual(
            controller.state.settings.workflow.repairOutputPath,
            output.path
        )
    }

    func testProjectRequirementUsesHumanReadableInlineValidation() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            service: service,
            directory: directory
        )
        controller.state.projectWasExplicitlySelected = false

        controller.start(.doctor)
        guard case var .requiredInput(input) = controller.state.overlay else {
            return XCTFail("Expected a project selection sheet")
        }
        input.value = directory.url.appendingPathComponent("Missing").path
        controller.state.overlay = .requiredInput(input)
        controller.handle(.enter, terminalSize: .minimum)

        guard case let .requiredInput(rejected) = controller.state.overlay else {
            return XCTFail("Expected inline project-path validation")
        }
        XCTAssertTrue(
            rejected.validationMessage?.contains("accessible directory")
                == true
        )
        XCTAssertFalse(
            rejected.validationMessage?.contains("SwiftDeltaCore") == true
        )
        XCTAssertTrue(service.kinds().isEmpty)
    }

    func testScrollableMessageOverlayKeepsAllDoctorDetailsReachable() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.discovery(
                    DiscoveryResult(
                        root: directory.url.path,
                        containers: [],
                        swiftFiles: []
                    )
                ))
            ),
            directory: directory
        )
        controller.state.overlay = .message(
            title: "Setup details",
            message: "One build context needs attention.",
            details: (0..<40).map { "Detail \($0)" }.joined(separator: "\n")
        )

        controller.handle(
            .pageDown,
            terminalSize: TerminalSize(columns: 100, rows: 28)
        )

        XCTAssertEqual(controller.state.detailScroll, 10)
        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .unicode,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        let theme = TerminalTheme()
        let output = TUIScreenRenderer(
            theme: theme,
            capabilities: capabilities
        ).render(
            controller.state,
            size: TerminalSize(columns: 100, rows: 28)
        ).encodedLines(
            theme: theme,
            capabilities: capabilities
        ).joined(separator: "\n")
        XCTAssertTrue(output.contains("Page Up/Down scroll"))
        XCTAssertTrue(output.contains("Detail 8") || output.contains("Detail 9"))

        controller.handle(
            .escape,
            terminalSize: TerminalSize(columns: 100, rows: 28)
        )
        XCTAssertEqual(controller.state.overlay, .none)
        XCTAssertEqual(controller.state.detailScroll, 0)
    }

    func testAnalysisProgressCompletionAndFindingsNavigation() throws {
        let directory = try TUITestDirectory()
        let findings = [
            syntheticFinding(
                identifier: "warning",
                title: "Warning finding",
                severity: .warning
            ),
            syntheticFinding(
                identifier: "error",
                title: "Error finding",
                severity: .error
            ),
        ]
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport(findings: findings)))
        )
        let controller = makeTUIController(
            screen: .findings,
            service: service,
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Synthetic context ready"],
            issues: []
        )
        controller.state.focus = .content
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Run Analysis"
            }
        )

        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        XCTAssertEqual(service.kinds(), [.scan])
        XCTAssertEqual(controller.state.screen, .findings)
        XCTAssertEqual(controller.state.report?.findings.count, 2)
        XCTAssertFalse(controller.state.progressLines.isEmpty)
        guard case let .succeeded(.scan, message) =
            controller.state.operationStatus
        else {
            return XCTFail("Expected successful scan")
        }
        XCTAssertTrue(message.contains("FAIL"))
    }

    func testFindingsSearchFilterSortGroupingAndLargeCollection() throws {
        let directory = try TUITestDirectory()
        let findings = (0..<1_000).map { index in
            syntheticFinding(
                identifier: "finding.\(index)",
                title: index.isMultiple(of: 2)
                    ? "Alpha \(index)" : "Beta \(index)",
                severity: index.isMultiple(of: 5) ? .error : .warning,
                path: "Sources/File\(index % 30).swift",
                module: "Module\(index % 8)"
            )
        }
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(findings: findings),
            service: service,
            directory: directory
        )
        controller.state.focus = .content

        controller.handle(.character("/"), terminalSize: .minimum)
        for character in "Alpha" {
            controller.handle(.character(character), terminalSize: .minimum)
        }
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(controller.state.findings.count, 500)

        controller.handle(.character("f"), terminalSize: .minimum)
        XCTAssertEqual(controller.state.severityFilter, .error)
        XCTAssertTrue(
            controller.state.findings.allSatisfy { $0.severity == .error }
        )
        let originalGrouping = controller.state.grouping
        controller.handle(.character("g"), terminalSize: .minimum)
        XCTAssertNotEqual(controller.state.grouping, originalGrouping)
        let originalSort = controller.state.sorting
        controller.handle(.character("s"), terminalSize: .minimum)
        XCTAssertNotEqual(controller.state.sorting, originalSort)

        controller.handle(.pageDown, terminalSize: .minimum)
        XCTAssertGreaterThan(controller.state.contentIndex, 0)
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(controller.state.focus, .details)
        controller.handle(.pageDown, terminalSize: .minimum)
        XCTAssertEqual(controller.state.detailScroll, 10)
    }

    func testOperationCancellationReturnsStableState() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(.waitForCancellation)
        let controller = makeTUIController(
            screen: .findings,
            service: service,
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Synthetic context ready"],
            issues: []
        )
        controller.state.focus = .content
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Run Analysis"
            }
        )
        controller.handle(.enter, terminalSize: .minimum)
        Thread.sleep(forTimeInterval: 0.03)
        controller.consumeOperationEvents()
        XCTAssertEqual(
            controller.state.progressMeasurement,
            OperationProgressMeasurement(
                completed: 1,
                total: 3,
                label: "Synthetic stages"
            )
        )

        controller.handle(.escape, terminalSize: .minimum)
        guard case .confirmation(_, _, .cancelOperation) =
            controller.state.overlay
        else {
            return XCTFail("Expected cancellation confirmation")
        }
        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        guard case .cancelled(.scan) = controller.state.operationStatus else {
            return XCTFail("Expected cancelled scan")
        }
        XCTAssertNil(controller.state.report)
        XCTAssertNil(controller.state.progressMeasurement)
    }

    func testRepairPlanningCanPauseAtSafeBoundariesAndStillCancel()
        throws
    {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(.waitForCancellation)
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(),
            service: service,
            directory: directory
        )
        controller.start(.planRepair)
        Thread.sleep(forTimeInterval: 0.02)
        controller.consumeOperationEvents()

        controller.handle(.character("p"), terminalSize: .minimum)
        XCTAssertTrue(controller.state.operationPaused)
        XCTAssertTrue(controller.coordinator.isPaused())
        controller.handle(.character("p"), terminalSize: .minimum)
        XCTAssertFalse(controller.state.operationPaused)
        XCTAssertFalse(controller.coordinator.isPaused())

        controller.coordinator.cancel()
        waitForOperations(controller)
        guard case .cancelled(.planRepair) = controller.state.operationStatus
        else {
            return XCTFail("Expected cancelled Repair planning")
        }
        XCTAssertFalse(controller.state.operationPaused)
    }

    func testEnteringRepairWithAnalysisAutomaticallyStartsPlanning() throws {
        let directory = try TUITestDirectory()
        let output = RepairPlanningOutput(
            plan: RepairPlan(projectRoot: directory.url.path, repairs: []),
            referenceResolutionCoverage: [],
            findingDispositions: []
        )
        let service = FakeTUIOperationService(.result(.repairPlan(output)))
        let controller = makeTUIController(
            report: syntheticReport(),
            service: service,
            directory: directory
        )
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Repair"
            }
        )

        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        XCTAssertEqual(controller.state.screen, .repair)
        XCTAssertEqual(service.kinds(), [.planRepair])
    }

    func testErrorsAreConciseWithExpandableTechnicalDetails() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .failure("Synthetic destination is unavailable.")
        )
        let controller = makeTUIController(
            screen: .check,
            service: service,
            directory: directory
        )
        controller.state.focus = .content
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Run Doctor"
            }
        )

        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)

        guard case let .message(title, message, details) =
            controller.state.overlay
        else {
            return XCTFail("Expected error message")
        }
        XCTAssertTrue(title.contains("failed"))
        XCTAssertTrue(message.contains("destination"))
        XCTAssertTrue(details?.contains("Project setup") == true)
        XCTAssertFalse(controller.state.technicalLog.isEmpty)
    }

    func testRepairSelectionPreviewApplyAndFoundationModelsProvenance()
        throws
    {
        let directory = try TUITestDirectory()
        let sources = directory.url.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: false
        )
        try Data("old\n".utf8).write(
            to: sources.appendingPathComponent("App.swift")
        )
        let deterministic = syntheticRepair()
        let model = syntheticRepair(modelGenerated: true)
        let plan = RepairPlan(
            generatedAt: Date(timeIntervalSince1970: 100),
            projectRoot: directory.url.path,
            repairs: [deterministic, model]
        )
        let service = FakeTUIOperationService(.result(.repairsApplied(1)))
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: plan,
            service: service,
            directory: directory
        )
        controller.state.focus = .content
        let formCount = TUIContentRows.rows(for: controller.state).count
        controller.state.contentIndex = formCount
        controller.handle(.character(" "), terminalSize: .minimum)
        XCTAssertTrue(
            controller.state.selectedRepairIDs.contains(
                deterministic.repairIdentifier
            )
        )

        controller.state.contentIndex = formCount + 1
        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: true,
            reducedMotion: true,
            mouseSupported: false
        )
        let canvas = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).render(
            controller.state,
            size: TerminalSize(columns: 130, rows: 28)
        )
        let rendered = canvas.encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined(separator: "\n")
        XCTAssertTrue(rendered.contains("Apple Foundation Models"))
        XCTAssertTrue(rendered.lowercased().contains("review required"))
        XCTAssertTrue(rendered.contains("- old"))
        XCTAssertTrue(rendered.contains("+ new"))

        controller.state.selectedRepairIDs = [deterministic.repairIdentifier]
        controller.state.contentIndex =
            TUIContentRows.rows(for: controller.state).count - 1
        controller.handle(.enter, terminalSize: .minimum)
        guard case .confirmation(_, _, .applyRepairs) =
            controller.state.overlay
        else {
            return XCTFail("Expected explicit apply confirmation")
        }
        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)
        XCTAssertEqual(service.kinds(), [.applyRepair])
        XCTAssertNil(controller.state.repairPlan)
    }

    func testEveryFormerOperationalOptionHasADiscoverableTUIControl() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            report: syntheticReport(),
            service: service,
            directory: directory
        )
        controller.state.foundationModelStatus = OnDeviceFoundationModelStatus(
            availability: .available,
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep"
        )
        let screens: [TUIScreen] = [
            .project, .setup, .check, .findings, .repair, .settings,
        ]
        var labels = Set<String>()
        for screen in screens {
            controller.state.screen = screen
            controller.state.advancedOptionsExpanded = true
            for section in TUISettingsSection.allCases {
                controller.state.settingsSection = section
                labels.formUnion(
                    TUIContentRows.rows(for: controller.state).map(\.label)
                )
            }
            labels.formUnion(
                TUIContentRows.rows(for: controller.state).map(\.label)
            )
        }
        for required in [
            "Project", "Configuration file", "Project container",
            "Scheme", "Build configuration", "Platform",
            "Baseline Xcode", "Candidate Xcode",
            "Compilation conditions", "Excluded paths", "Minimum severity",
            "Minimum confidence", "Include uncertain findings",
            "Operation timeout", "Failure threshold",
            "Allow incomplete results", "Quiet progress", "SDK cache policy",
            "Report format", "Report output", "Selected source files",
            "Repair identifiers", "Finding identifiers", "Load repair plan",
            "Preview format", "Repair-plan output", "Apple Foundation Models",
            "Reasoning level", "Model timeout", "Model candidate limit",
            "Inspection timeout", "Maximum age",
            "Maximum size",
        ] {
            XCTAssertTrue(labels.contains(required), "Missing TUI control: \(required)")
        }
    }

    func testNarrowResultsUseVisibleNavigationAndDedicatedDetails() throws {
        let directory = try TUITestDirectory()
        let finding = syntheticFinding(
            identifier: "narrow",
            title: "Narrow result",
            severity: .warning
        )
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(findings: [finding]),
            service: FakeTUIOperationService(.result(.report(syntheticReport()))),
            directory: directory
        )
        controller.state.focus = .content
        controller.state.contentIndex =
            TUIContentRows.resultControlCount(for: controller.state)
        let narrow = TerminalSize(columns: 72, rows: 22)

        controller.handle(.enter, terminalSize: narrow)
        XCTAssertEqual(controller.state.detailPresentation, .finding)
        XCTAssertEqual(controller.state.focus, .details)
        controller.handle(.escape, terminalSize: narrow)
        XCTAssertEqual(controller.state.detailPresentation, .none)
        XCTAssertEqual(controller.state.focus, .content)
        controller.handle(.tab, terminalSize: narrow)
        XCTAssertNotEqual(controller.state.focus, .details)

        let capabilities = TerminalCapabilities(
            colorMode: .monochrome,
            symbolMode: .ascii,
            highContrast: false,
            reducedMotion: true,
            mouseSupported: false
        )
        let output = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).render(controller.state, size: narrow).encodedLines(
            theme: TerminalTheme(),
            capabilities: capabilities
        ).joined(separator: "\n")
        XCTAssertTrue(output.contains("Analysis"))
        XCTAssertTrue(output.contains("Home  >"))
        XCTAssertTrue(output.contains("warning -- 1"))
    }

    func testRepairPlanSelectsOnlyApplicableConflictFreeRepairs() throws {
        let directory = try TUITestDirectory()
        let safe = syntheticRepair()
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
            explanation: "Review is required.",
            verificationRequirement: .candidateBuild
        )
        let conflicting = ProposedRepair(
            repairIdentifier: "repair.conflict",
            relatedFindingIdentifier: "finding.conflict",
            evidenceSource: .swiftCompilerFixIt,
            language: safe.language,
            filePath: safe.filePath,
            sourceRange: safe.sourceRange,
            originalText: safe.originalText,
            replacementText: "other",
            fileFingerprint: safe.fileFingerprint,
            confidence: .high,
            safety: .safe,
            explanation: "Conflicts with the safe edit.",
            verificationRequirement: .candidateBuild
        )
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [safe, review, conflicting],
            conflicts: [
                RepairConflict(
                    kind: .contradictory,
                    repairIdentifiers: [
                        safe.repairIdentifier,
                        conflicting.repairIdentifier,
                    ],
                    explanation: "Synthetic conflict."
                ),
            ]
        )
        let controller = makeTUIController(
            service: FakeTUIOperationService(.result(.repairPlan(
                RepairPlanningOutput(
                    plan: plan,
                    referenceResolutionCoverage: []
                )
            ))),
            directory: directory
        )

        controller.accept(.repairPlan(RepairPlanningOutput(
            plan: plan,
            referenceResolutionCoverage: []
        )))

        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)
    }

    func testMouseSingleClickSelectsAndDoubleClickActivates() throws {
        let directory = try TUITestDirectory()
        let clock = TUITestClock(10)
        let report = syntheticReport(findings: [
            syntheticFinding(
                identifier: "double-click",
                title: "Open result",
                severity: .warning
            ),
        ])
        let controller = makeTUIController(
            report: report,
            service: FakeTUIOperationService(.result(.report(report))),
            directory: directory,
            clock: clock
        )
        let rows = TUIContentRows.rows(for: controller.state)
        let resultIndex = try XCTUnwrap(rows.firstIndex {
            $0.label == "Analysis"
        })
        let displayIndex = try XCTUnwrap(
            TUIContentRows.displayedRowIndices(for: rows).firstIndex {
                $0 == resultIndex
            }
        )
        let click = TUIKey.mouse(
            TUIMouseEvent(
                kind: .press,
                button: 0,
                column: 4,
                row: 3 + displayIndex
            )
        )

        controller.handle(click, terminalSize: TerminalSize(columns: 100, rows: 28))
        XCTAssertEqual(controller.state.screen, .project)
        XCTAssertEqual(controller.state.contentIndex, resultIndex)
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
        ).render(
            controller.state,
            size: TerminalSize(columns: 100, rows: 28)
        )
        let selectedRow = try XCTUnwrap(
            canvas.rows.first { row in
                row.filter { !$0.continuation }
                    .map(\.text)
                    .joined()
                    .contains("[ Analysis ]")
            }
        )
        XCTAssertGreaterThanOrEqual(
            selectedRow.count {
                $0.style.background == theme.selectionBackground
            },
            70
        )

        clock.advance(by: 0.2)
        controller.handle(click, terminalSize: TerminalSize(columns: 100, rows: 28))
        XCTAssertEqual(controller.state.screen, .findings)
    }

    func testResizeMovesFocusOutOfAHiddenDetailPane() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            screen: .findings,
            report: syntheticReport(findings: [
                syntheticFinding(
                    identifier: "resize",
                    title: "Resize result",
                    severity: .notice
                ),
            ]),
            service: FakeTUIOperationService(
                .result(.report(syntheticReport()))
            ),
            directory: directory
        )
        controller.state.contentIndex =
            TUIContentRows.resultControlCount(for: controller.state)
        controller.state.focus = .details

        controller.handleResize(TerminalSize(columns: 89, rows: 28))

        XCTAssertEqual(controller.state.focus, .content)
        XCTAssertEqual(controller.state.detailPresentation, .none)
    }

    func testMouseWheelScrollsLongOverlayContent() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.report(syntheticReport()))
            ),
            directory: directory
        )
        controller.state.overlay = .message(
            title: "Details",
            message: "Summary",
            details: (0..<100).map { "Line \($0)" }.joined(separator: "\n")
        )

        controller.handle(
            .mouse(TUIMouseEvent(
                kind: .scrollDown,
                button: 0,
                column: 20,
                row: 10
            )),
            terminalSize: TerminalSize(columns: 100, rows: 28)
        )

        XCTAssertEqual(controller.state.detailScroll, 3)
    }

    func testDoctorIssuesOpenForInspectionAndBlockCompatibilityRun() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.report(syntheticReport()))
            ),
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Destination: synthetic"],
            issues: ["Select one platform context."]
        )
        let homeRows = TUIContentRows.rows(for: controller.state)
        controller.state.contentIndex = try XCTUnwrap(homeRows.firstIndex {
            $0.label == "Doctor"
        })

        controller.handle(.enter, terminalSize: .minimum)

        XCTAssertEqual(controller.state.screen, .check)
        let checkRows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(checkRows.contains {
            $0.label == "Run Doctor Again" && $0.enabled
        })
        XCTAssertFalse(checkRows.contains { $0.label == "Run Analysis" })
        controller.state.contentIndex = try XCTUnwrap(checkRows.firstIndex {
            $0.label == "Validation"
        })
        controller.handle(.enter, terminalSize: .minimum)
        guard case let .message(_, message, _) = controller.state.overlay else {
            return XCTFail("Expected Doctor issue details")
        }
        XCTAssertTrue(message.contains("platform context"))
    }

    func testTerminationCancelsOperationAndExitsApplication() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(.waitForCancellation)
        let controller = makeTUIController(
            screen: .check,
            service: service,
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Synthetic context ready"],
            issues: []
        )
        controller.start(.scan)
        Thread.sleep(forTimeInterval: 0.02)

        controller.handle(
            .terminate,
            terminalSize: TerminalSize(columns: 90, rows: 24)
        )
        waitForOperations(controller)

        XCTAssertTrue(controller.state.shouldQuit)
        XCTAssertFalse(controller.coordinator.isRunning())
    }

    func testSetupReadinessGatesDoctorAndSetupChangesInvalidateEvidence()
        throws
    {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.report(syntheticReport()))
        )
        let controller = makeTUIController(
            report: syntheticReport(findings: [
                syntheticFinding(
                    identifier: "stale",
                    title: "Stale",
                    severity: .warning
                ),
            ]),
            repairPlan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            service: service,
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Ready"],
            issues: []
        )
        XCTAssertTrue(controller.state.setupIsReady)
        XCTAssertTrue(controller.state.doctorPassed)

        controller.commit(field: .buildConfiguration, value: "Release")

        XCTAssertNil(controller.state.doctorResult)
        XCTAssertNil(controller.state.report)
        XCTAssertNil(controller.state.repairPlan)
        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)

        controller.state.setupOrigins.removeValue(forKey: .candidateXcode)
        XCTAssertFalse(controller.state.setupIsReady)
        let doctor = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).first {
                $0.label == "Doctor"
            }
        )
        XCTAssertFalse(doctor.enabled)
        XCTAssertTrue(doctor.detail.contains("candidate Xcode"))
    }

    func testDoctorAnalysisAndRepairKeepOperationsInTheirOwnScreens() throws {
        let directory = try TUITestDirectory()
        let planningOutput = RepairPlanningOutput(
            plan: RepairPlan(projectRoot: directory.url.path, repairs: []),
            referenceResolutionCoverage: []
        )
        let service = FakeTUIOperationService(
            .result(.repairPlan(planningOutput))
        )
        let controller = makeTUIController(
            service: service,
            directory: directory
        )
        controller.state.doctorResult = TUIDoctorResult(
            lines: ["Ready"],
            issues: []
        )

        controller.selectScreen(.check)
        let doctorRows = TUIContentRows.rows(for: controller.state)
        XCTAssertFalse(doctorRows.contains { $0.label == "Analysis mode" })
        XCTAssertFalse(doctorRows.contains { $0.label == "Run Analysis" })
        controller.state.contentIndex = try XCTUnwrap(
            doctorRows.firstIndex { $0.label == "Continue to Analysis" }
        )
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(controller.state.screen, .findings)
        XCTAssertTrue(service.kinds().isEmpty)

        let analysisRows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(analysisRows.contains { $0.label == "Analysis mode" })
        XCTAssertTrue(analysisRows.contains { $0.label == "Run Analysis" })

        controller.state.report = syntheticReport()
        controller.state.contentIndex = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Continue to Repair"
            }
        )
        controller.handle(.enter, terminalSize: .minimum)
        waitForOperations(controller)
        XCTAssertEqual(controller.state.screen, .repair)
        XCTAssertNotNil(controller.state.repairPlan)
        XCTAssertEqual(service.kinds(), [.planRepair])
        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)
    }

    func testRepairListKeepsEveryCandidateDispositionInspectable() throws {
        let directory = try TUITestDirectory()
        let file = directory.url.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: file)
        let repair = syntheticRepair()
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [repair]
        )
        let statuses: [RepairCandidateStatus] = [
            .ready, .needsValidation, .reviewRequired,
            .verificationFailed, .rejected, .noProposal,
        ]
        let candidates = statuses.enumerated().map { index, status in
            RepairCandidatePresentation(
                candidateIdentifier: "candidate.\(index)",
                findingStableKey: "finding.\(index)|Sources/App.swift|\(index + 1)",
                findingIdentifier: "finding.\(index)",
                title: "Synthetic candidate \(index)",
                location: SourceLocation(
                    path: "Sources/App.swift",
                    line: index + 1
                ),
                symbol: "FictionalSDK.API\(index)",
                status: status,
                repairSource: index == 1
                    ? "Apple Foundation Models" : "Compiler Fix-it",
                confidence: .high,
                summary: index == 1
                    ? "2 coordinated edits" : "Replace source expression",
                explanation: "Synthetic candidate explanation.",
                evidence: ["Synthetic compiler or SDK evidence"],
                risks: status == .ready ? [] : ["Synthetic review reason"],
                repairIdentifiers: status == .ready ? [repair.repairIdentifier] : [],
                edits: [
                    RepairCandidateEditPresentation(
                        operation: "replace",
                        filePath: "Sources/App.swift",
                        originalText: "old",
                        replacementText: "new",
                        sourceRange: repair.sourceRange
                    ),
                ]
            )
        }
        let output = RepairPlanningOutput(
            plan: plan,
            referenceResolutionCoverage: [],
            repairCandidates: candidates
        )
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: plan,
            service: FakeTUIOperationService(.result(.repairPlan(output))),
            directory: directory
        )
        controller.accept(.repairPlan(output))
        controller.state.repairFilter = .all

        let rendered = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: TerminalCapabilities(
                colorMode: .trueColor,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: true
            )
        ).render(
            controller.state,
            size: TerminalSize(columns: 160, rows: 50)
        )
        let text = rendered.rows.map {
            $0.filter { !$0.continuation }.map(\.text).joined()
        }.joined(separator: "\n")
        for label in ["Ready", "Needs Review", "Failed", "No Safe Fix"] {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(label), label)
        }

        controller.state.contentIndex =
            TUIContentRows.rows(for: controller.state).count + 1
        controller.handle(
            .enter,
            terminalSize: TerminalSize(columns: 160, rows: 50)
        )
        XCTAssertEqual(controller.state.detailPresentation, .repair)
        XCTAssertEqual(
            controller.state.selectedRepairCandidate?.candidateIdentifier,
            "candidate.1"
        )
    }

    func testReviewAndValidatePromotesCandidateBeforeSelection() throws {
        let directory = try TUITestDirectory()
        let file = directory.url.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: file)
        let repair = syntheticRepair(modelGenerated: true)
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: [repair]
        )
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.model",
            findingStableKey: "finding.one|Sources/App.swift|1",
            findingIdentifier: "finding.one",
            title: "Synthetic model proposal",
            location: SourceLocation(path: "Sources/App.swift", line: 1),
            symbol: "FictionalSDK.API",
            status: .needsValidation,
            repairSource: "Apple Foundation Models",
            confidence: .medium,
            summary: "Replace source expression",
            explanation: "Use the candidate declaration.",
            evidence: ["candidate symbol usr.synthetic"],
            risks: ["Review required"],
            repairIdentifiers: [repair.repairIdentifier],
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: repair.filePath,
                    originalText: repair.originalText,
                    replacementText: repair.replacementText,
                    sourceRange: repair.sourceRange
                ),
            ]
        )
        let output = RepairPlanningOutput(
            plan: plan,
            referenceResolutionCoverage: [],
            repairCandidates: [candidate]
        )
        let service = FakeTUIOperationService(
            .result(
                .repairValidated(
                    candidateIdentifier: candidate.candidateIdentifier,
                    repairs: [repair],
                    message: "Synthetic isolated verification passed."
                )
            )
        )
        let controller = makeTUIController(
            screen: .repair,
            repairPlan: plan,
            service: service,
            directory: directory
        )
        controller.accept(.repairPlan(output))
        controller.state.contentIndex =
            TUIContentRows.rows(for: controller.state).count

        controller.handle(.character(" "), terminalSize: .minimum)
        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)
        controller.handle(.escape, terminalSize: .minimum)
        controller.handle(.enter, terminalSize: .minimum)
        controller.handle(.character("v"), terminalSize: .minimum)
        waitForOperations(controller)

        XCTAssertEqual(service.kinds(), [.validateRepair])
        XCTAssertEqual(
            controller.state.effectiveStatus(for: candidate),
            .ready
        )
        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)
        controller.handle(.character(" "), terminalSize: .minimum)
        XCTAssertEqual(
            controller.state.selectedRepairIDs,
            Set([repair.repairIdentifier])
        )
    }

    func testDraftCanBeEditedValidatedPromotedAndSelected() throws {
        let directory = try TUITestDirectory()
        let file = directory.url.appendingPathComponent(
            "Sources/App.swift"
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: file)
        let draft = syntheticRepairDraft()
        let promoted = syntheticRepair(modelGenerated: true)
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.draft",
            draftIdentifier: draft.draftIdentifier,
            findingStableKey: draft.findingStableKey,
            findingIdentifier: draft.findingIdentifier,
            title: draft.findingTitle,
            location: draft.location,
            symbol: draft.symbol,
            status: .needsValidation,
            repairSource: "Apple Foundation Models",
            confidence: .medium,
            summary: "Replace draft",
            explanation: draft.explanation,
            evidence: draft.evidence,
            risks: draft.initialIssues.map(\.message),
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: draft.sourceFile,
                    originalText: "ol",
                    replacementText: "new"
                ),
            ]
        )
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            referenceResolutionCoverage: [],
            repairCandidates: [candidate],
            repairDrafts: [draft]
        )
        let service = FakeTUIOperationService(
            .result(
                .repairValidated(
                    candidateIdentifier: candidate.candidateIdentifier,
                    repairs: [promoted],
                    message: "Synthetic isolated verification passed."
                )
            )
        )
        let controller = makeTUIController(
            screen: .repair,
            service: service,
            directory: directory
        )
        controller.accept(.repairPlan(output))
        controller.state.contentIndex =
            TUIContentRows.rows(for: controller.state).count
        controller.handle(.enter, terminalSize: .minimum)
        controller.handle(.character("e"), terminalSize: .minimum)
        guard case .draftEditor = controller.state.overlay else {
            return XCTFail("Expected a multiline draft editor")
        }
        controller.handle(.character("d"), terminalSize: .minimum)
        controller.handle(
            .character("\u{13}"),
            terminalSize: .minimum
        )

        XCTAssertEqual(
            controller.state.repairDrafts.first?
                .edits.first?.originalAnchor,
            "old"
        )
        controller.handle(.character("v"), terminalSize: .minimum)
        waitForOperations(controller)

        let request = try XCTUnwrap(service.requests().last)
        XCTAssertEqual(
            request.repairDraft?.edits.first?.originalAnchor,
            "old"
        )
        XCTAssertEqual(
            controller.state.effectiveStatus(for: candidate),
            .ready
        )
        controller.handle(.character(" "), terminalSize: .minimum)
        XCTAssertEqual(
            controller.state.selectedRepairIDs,
            Set([promoted.repairIdentifier])
        )
    }

    func testRepairPreviewAutomaticallyValidatesAndPromotesWithoutSelecting()
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
            candidateIdentifier: "candidate.automatic",
            findingStableKey: "finding.one|Sources/App.swift|1",
            findingIdentifier: "finding.one",
            title: "Synthetic compiler repair",
            location: SourceLocation(path: "Sources/App.swift", line: 1),
            symbol: "FictionalKit.API",
            status: .ready,
            repairSource: "Compiler Fix-it",
            confidence: .high,
            summary: "Replace exact token",
            explanation: "The compiler supplied this exact edit.",
            evidence: ["Structured compiler Fix-it"],
            repairIdentifiers: [repair.repairIdentifier],
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: repair.filePath,
                    originalText: repair.originalText,
                    replacementText: repair.replacementText,
                    sourceRange: repair.sourceRange
                ),
            ]
        )
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: [repair]
            ),
            referenceResolutionCoverage: [],
            repairCandidates: [candidate]
        )
        var workflow = TUIWorkflowSettings()
        workflow.projectRoot = directory.url.path
        let prepared = CoreTUIOperationService()
            .automaticallyValidateRepairCandidates(
                output,
                root: directory.url,
                workflow: workflow,
                runner: ProcessRunner(),
                progress: .silent,
                cancellation: { false },
                validation: { received, _ in
                    XCTAssertEqual(
                        received.candidateIdentifier,
                        candidate.candidateIdentifier
                    )
                    return [repair]
                }
            )

        XCTAssertEqual(
            prepared.validatedCandidateIdentifiers,
            [candidate.candidateIdentifier]
        )
        XCTAssertTrue(prepared.failureMessages.isEmpty)
        XCTAssertTrue(
            prepared.successMessages[candidate.candidateIdentifier]?
                .contains("Build Verified") == true
        )

        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(),
            service: FakeTUIOperationService(
                .result(.preparedRepairPlan(prepared))
            ),
            directory: directory
        )
        controller.accept(.preparedRepairPlan(prepared))
        XCTAssertTrue(controller.state.selectedRepairIDs.isEmpty)
        XCTAssertEqual(
            controller.state.repairLifecycle(for: candidate),
            .ready
        )
        XCTAssertEqual(controller.state.repairFunnel.ready, 1)
        XCTAssertEqual(controller.state.repairFunnel.selected, 0)
        let rows = TUIContentRows.rows(for: controller.state)
        XCTAssertTrue(rows.contains {
            $0.label == "Validate Again" && $0.enabled
        })
        let selectIndex = try XCTUnwrap(rows.firstIndex {
            $0.label == "Select Repair" && $0.enabled
        })
        controller.state.contentIndex = selectIndex
        controller.handle(.enter, terminalSize: .minimum)
        XCTAssertEqual(
            controller.state.selectedRepairIDs,
            [repair.repairIdentifier]
        )
    }

    func testAutomaticValidationFailureRemainsInspectableAndUnselectable()
        throws
    {
        let directory = try TUITestDirectory()
        let repair = syntheticRepair()
        let candidate = RepairCandidatePresentation(
            candidateIdentifier: "candidate.failed",
            findingStableKey: "finding.one|Sources/App.swift|1",
            findingIdentifier: "finding.one",
            title: "Synthetic proposal",
            location: SourceLocation(path: "Sources/App.swift", line: 1),
            status: .needsValidation,
            repairSource: "Apple Foundation Models",
            summary: "Replace exact token",
            explanation: "Synthetic proposal.",
            repairIdentifiers: [repair.repairIdentifier],
            edits: [
                RepairCandidateEditPresentation(
                    operation: "replace",
                    filePath: repair.filePath,
                    originalText: "old",
                    replacementText: "new",
                    sourceRange: repair.sourceRange
                ),
            ]
        )
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: [repair]
            ),
            referenceResolutionCoverage: [],
            repairCandidates: [candidate]
        )
        var workflow = TUIWorkflowSettings()
        workflow.projectRoot = directory.url.path
        let prepared = CoreTUIOperationService()
            .automaticallyValidateRepairCandidates(
                output,
                root: directory.url,
                workflow: workflow,
                runner: ProcessRunner(),
                progress: .silent,
                cancellation: { false },
                validation: { _, _ in
                    throw LaunchError(
                        "the targeted SDK evidence remained after the edit"
                    )
                }
            )

        XCTAssertTrue(prepared.validatedCandidateIdentifiers.isEmpty)
        XCTAssertTrue(
            prepared.failureMessages[candidate.candidateIdentifier]?
                .contains("targeted SDK evidence remained") == true
        )
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.repairCandidates = [candidate]
        state.repairValidationMessages = prepared.failureMessages
        XCTAssertEqual(state.repairLifecycle(for: candidate), .failed)
        XCTAssertFalse(state.candidateIsSelectable(candidate))
    }

    func testAutomaticValidationDoesNotPromoteContradictoryRepairs()
        throws
    {
        let directory = try TUITestDirectory()
        let source = directory.url.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: source)
        let first = syntheticRepair(
            identifier: "repair.first",
            replacementText: "first"
        )
        let second = syntheticRepair(
            identifier: "repair.second",
            replacementText: "second"
        )
        func candidate(
            _ identifier: String,
            repair: ProposedRepair
        ) -> RepairCandidatePresentation {
            RepairCandidatePresentation(
                candidateIdentifier: identifier,
                findingStableKey: "\(identifier)|Sources/App.swift|1",
                findingIdentifier: identifier,
                title: "Contradictory proposal",
                location: SourceLocation(
                    path: "Sources/App.swift",
                    line: 1
                ),
                status: .needsValidation,
                repairSource: "Apple Foundation Models",
                summary: "Replace exact token",
                explanation: "Synthetic proposal.",
                repairIdentifiers: [repair.repairIdentifier],
                edits: [
                    RepairCandidateEditPresentation(
                        operation: "replace",
                        filePath: repair.filePath,
                        originalText: repair.originalText,
                        replacementText: repair.replacementText,
                        sourceRange: repair.sourceRange
                    ),
                ]
            )
        }
        let firstCandidate = candidate("candidate.first", repair: first)
        let secondCandidate = candidate("candidate.second", repair: second)
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            referenceResolutionCoverage: [],
            repairCandidates: [firstCandidate, secondCandidate]
        )
        var workflow = TUIWorkflowSettings()
        workflow.projectRoot = directory.url.path
        let prepared = CoreTUIOperationService()
            .automaticallyValidateRepairCandidates(
                output,
                root: directory.url,
                workflow: workflow,
                runner: ProcessRunner(),
                progress: .silent,
                cancellation: { false },
                validation: { received, _ in
                    received.candidateIdentifier
                        == firstCandidate.candidateIdentifier
                        ? [first] : [second]
                }
            )

        XCTAssertTrue(prepared.validatedCandidateIdentifiers.isEmpty)
        XCTAssertEqual(prepared.output.plan.conflicts.count, 1)
        XCTAssertEqual(prepared.failureMessages.count, 2)
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.repairPlan = prepared.output.plan
        state.repairCandidates = [firstCandidate, secondCandidate]
        state.repairValidationMessages = prepared.failureMessages
        XCTAssertFalse(state.candidateIsSelectable(firstCandidate))
        XCTAssertFalse(state.candidateIsSelectable(secondCandidate))
    }

    func testModelPlanningUsesAutomaticBoundedBudgetWithoutContinueAction()
        throws
    {
        let directory = try TUITestDirectory()
        let output = RepairPlanningOutput(
            plan: RepairPlan(
                projectRoot: directory.url.path,
                repairs: []
            ),
            referenceResolutionCoverage: [],
            foundationModelSummary: FoundationModelPlanningSummary(
                findingsConsidered: 70,
                processed: 25,
                skipped: 0,
                deduplicated: 0,
                deferredByLimit: 45,
                rejected: 20,
                convertedIntoRepairs: 5
            )
        )
        let service = FakeTUIOperationService(.result(.repairPlan(output)))
        let controller = makeTUIController(
            screen: .repair,
            report: syntheticReport(),
            service: service,
            directory: directory,
            foundationModelStatusProvider: {
                OnDeviceFoundationModelStatus(
                    availability: .available,
                    hostModelGeneration: "macOS 27",
                    reasoningLevel: "deep"
                )
            }
        )
        controller.accept(.repairPlan(output))
        let rows = TUIContentRows.rows(for: controller.state)
        XCTAssertFalse(rows.contains { $0.label == "Continue Planning" })
        XCTAssertEqual(
            CoreTUIOperationService().foundationModelOptions(
                controller.state.settings.workflow,
                status: OnDeviceFoundationModelStatus(
                    availability: .available,
                    hostModelGeneration: "macOS 27",
                    reasoningLevel: "deep"
                )
            )?.maximumCandidates,
            FoundationModelRepairOptions.hardMaximumCandidates
        )
    }
}
