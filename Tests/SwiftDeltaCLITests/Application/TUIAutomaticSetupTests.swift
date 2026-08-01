//===--- TUIAutomaticSetupTests.swift - SwiftDelta ------------------------------------------===//
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

final class TUIAutomaticSetupTests: XCTestCase {
    func testSelectsSingleProjectAndSinglePackageAutomatically() throws {
        let directory = try TUITestDirectory()
        let project = directory.url.appendingPathComponent("Sample.xcodeproj")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false
        )
        let selector = TUIAutomaticSetupSelector()
        let projectResult = selector.container(
            from: DiscoveryResult(
                root: directory.url.path,
                containers: [
                    ProjectContainer(kind: .project, path: project.path),
                ],
                swiftFiles: []
            ),
            root: directory.url
        )
        XCTAssertEqual(projectResult.selected?.path, project.path)

        let manifest = directory.url.appendingPathComponent("Package.swift")
        let packageResult = selector.container(
            from: DiscoveryResult(
                root: directory.url.path,
                containers: [
                    ProjectContainer(kind: .package, path: manifest.path),
                ],
                swiftFiles: []
            ),
            root: directory.url
        )
        XCTAssertEqual(packageResult.selected?.kind, .package)
    }

    func testAssociatedWorkspaceIsPreferredOverItsProject() throws {
        let directory = try TUITestDirectory()
        let project = directory.url.appendingPathComponent("Sample.xcodeproj")
        let workspace = directory.url.appendingPathComponent(
            "Sample.xcworkspace"
        )
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false
        )
        try Data(
            """
            <Workspace version="1.0">
              <FileRef location="group:Sample.xcodeproj"/>
            </Workspace>
            """.utf8
        ).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))

        let result = TUIAutomaticSetupSelector().container(
            from: DiscoveryResult(
                root: directory.url.path,
                containers: [
                    ProjectContainer(kind: .project, path: project.path),
                    ProjectContainer(kind: .workspace, path: workspace.path),
                ],
                swiftFiles: []
            ),
            root: directory.url
        )

        XCTAssertEqual(result.selected?.kind, .workspace)
        XCTAssertEqual(result.selected?.path, workspace.path)
    }

    func testUnrelatedContainersRemainAFocusedAmbiguity() throws {
        let directory = try TUITestDirectory()
        let result = TUIAutomaticSetupSelector().container(
            from: DiscoveryResult(
                root: directory.url.path,
                containers: [
                    ProjectContainer(
                        kind: .project,
                        path: directory.url.appendingPathComponent(
                            "First.xcodeproj"
                        ).path
                    ),
                    ProjectContainer(
                        kind: .project,
                        path: directory.url.appendingPathComponent(
                            "Second.xcodeproj"
                        ).path
                    ),
                ],
                swiftFiles: []
            ),
            root: directory.url
        )

        XCTAssertNil(result.selected)
        XCTAssertEqual(result.choices.count, 2)
    }

    func testSchemeMatchingContainerIsSelectedBeforeAsking() {
        let container = ProjectContainer(
            kind: .project,
            path: "/Synthetic/Sample.xcodeproj"
        )
        let result = TUIAutomaticSetupSelector().scheme(
            available: ["SampleTests", "Sample", "Shared"],
            container: container,
            targets: ["Sample", "SampleTests"]
        )

        XCTAssertEqual(result.selected, "Sample")
        XCTAssertEqual(result.ordered.first, "Sample")
    }

    func testIOSDeviceSimulatorAndCatalystAreSeparateSelectableContexts() {
        let snapshots = [
            BuildSettingsSnapshot(
                target: "Sample",
                configuration: "Debug",
                settings: [
                    "PRODUCT_TYPE": "com.apple.product-type.application",
                    "SDKROOT": "iphoneos",
                    "SUPPORTED_PLATFORMS":
                        "iphoneos iphonesimulator macosx",
                    "SUPPORTS_MACCATALYST": "YES",
                ]
            ),
        ]

        let result = TUIAutomaticSetupSelector().sdkContexts(from: snapshots)

        XCTAssertTrue(result.contains {
            $0.label == "iOS Device"
                && $0.destination == "generic/platform=iOS"
        })
        XCTAssertTrue(result.contains {
            $0.label == "iOS Simulator"
                && $0.destination == "generic/platform=iOS Simulator"
        })
        XCTAssertTrue(result.contains {
            $0.label == "Mac Catalyst"
                && $0.destination == "platform=macOS,variant=Mac Catalyst"
        })
    }

    func testCrossPlatformTargetWithoutEffectivePreferenceRemainsAmbiguous() {
        let snapshots = [
            BuildSettingsSnapshot(settings: [
                "SUPPORTED_PLATFORMS": "iphoneos macosx",
            ]),
        ]

        XCTAssertNil(
            TUIAutomaticSetupSelector()
                .preferredSDKContext(from: snapshots)
        )
    }

    func testExactlyTwoXcodesStillRequireExplicitRolesAndExplicitPairIsPreserved() throws {
        let directory = try TUITestDirectory()
        let applications = try ["Xcode-1.app", "Xcode-2.app", "Xcode-3.app"]
            .map { name -> String in
                let application = directory.url.appendingPathComponent(name)
                let executable = application.appendingPathComponent(
                    "Contents/Developer/usr/bin/xcodebuild"
                )
                try FileManager.default.createDirectory(
                    at: executable.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                XCTAssertTrue(
                    FileManager.default.createFile(
                        atPath: executable.path,
                        contents: Data()
                    )
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path
                )
                try writeXcodeBundleIdentity(
                    at: application,
                    version: name,
                    build: name
                )
                return application.path
            }
        let service = CoreTUIOperationService()
        var automatic = TUIWorkflowSettings()
        var origins: [TUISetupField: TUISetupValueOrigin] = [:]

        let baselineResolution = service.selectXcodes(
            Array(applications.prefix(2)),
            workflow: &automatic,
            origins: &origins
        )
        XCTAssertEqual(baselineResolution?.field, .baselineXcode)
        XCTAssertNil(automatic.baselineXcodePath)
        XCTAssertNil(automatic.candidateXcodePath)
        XCTAssertNil(origins[.baselineXcode])

        automatic.baselineXcodePath = applications[0]
        origins[.baselineXcode] = .saved
        let candidateResolution = service.selectXcodes(
            Array(applications.prefix(2)),
            workflow: &automatic,
            origins: &origins
        )
        XCTAssertEqual(candidateResolution?.field, .candidateXcode)
        XCTAssertTrue(
            candidateResolution?.choices.contains {
                guard case let .candidateXcode(path) = $0.value else {
                    return false
                }
                return path == applications[0] && !$0.enabled
            } == true
        )

        var explicit = TUIWorkflowSettings()
        explicit.baselineXcodePath = applications[1]
        explicit.candidateXcodePath = applications[2]
        origins = [
            .baselineXcode: .saved,
            .candidateXcode: .saved,
        ]
        XCTAssertNil(
            service.selectXcodes(
                applications,
                workflow: &explicit,
                origins: &origins
            )
        )
        XCTAssertEqual(explicit.baselineXcodePath, applications[1])
        XCTAssertEqual(explicit.candidateXcodePath, applications[2])
        XCTAssertEqual(origins[.candidateXcode], .saved)
    }

    func testUnavailableExplicitXcodeRequestsOnlyThatField() throws {
        let directory = try TUITestDirectory()
        let application = directory.url.appendingPathComponent("Xcode.app")
        let executable = application.appendingPathComponent(
            "Contents/Developer/usr/bin/xcodebuild"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data()
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try writeXcodeBundleIdentity(
            at: application,
            version: "1.0",
            build: "Synthetic1"
        )
        var workflow = TUIWorkflowSettings()
        workflow.baselineXcodePath = "/Missing/Xcode.app"
        var origins: [TUISetupField: TUISetupValueOrigin] = [
            .baselineXcode: .saved,
        ]

        let resolution = CoreTUIOperationService().selectXcodes(
            [application.path],
            workflow: &workflow,
            origins: &origins
        )

        XCTAssertEqual(resolution?.field, .baselineXcode)
        XCTAssertEqual(workflow.baselineXcodePath, "/Missing/Xcode.app")
        XCTAssertTrue(
            resolution?.message.contains("no longer available") == true
        )
    }

    func testXcodeChoicesShowIdentitySDKsRolesAndDisableEquivalentBuilds()
        throws
    {
        let directory = try TUITestDirectory()
        let first = try makeXcode(
            named: "First.app",
            version: "10.1",
            build: "10A1",
            sdk: "iPhoneOS10.0.sdk",
            in: directory.url
        )
        let equivalent = try makeXcode(
            named: "Equivalent.app",
            version: "10.1",
            build: "10A1",
            sdk: "iPhoneOS10.0.sdk",
            in: directory.url
        )
        var workflow = TUIWorkflowSettings()
        workflow.baselineXcodePath = first
        var origins: [TUISetupField: TUISetupValueOrigin] = [
            .baselineXcode: .saved,
        ]

        let resolution = CoreTUIOperationService().selectXcodes(
            [first, equivalent],
            workflow: &workflow,
            origins: &origins
        )

        XCTAssertEqual(resolution?.field, .candidateXcode)
        let firstChoice = try XCTUnwrap(resolution?.choices.first {
            $0.detail.contains(first)
        })
        XCTAssertTrue(firstChoice.label.contains("Xcode 10.1 (10A1)"))
        XCTAssertTrue(firstChoice.detail.contains("iPhoneOS10.0"))
        XCTAssertTrue(firstChoice.detail.contains("selected as baseline"))
        XCTAssertFalse(firstChoice.enabled)
        let equivalentChoice = try XCTUnwrap(resolution?.choices.first {
            $0.detail.contains(equivalent)
        })
        XCTAssertFalse(equivalentChoice.enabled)
    }

    func testAutomaticSetupResultUpdatesStateWithoutBlockingRendering()
        throws
    {
        let directory = try TUITestDirectory()
        var workflow = TUIWorkflowSettings()
        workflow.projectRoot = directory.url.path
        workflow.scheme = "Sample"
        workflow.sdkIdentifiers = ["iphoneos"]
        workflow.destination = "generic/platform=iOS"
        let result = TUIAutomaticSetupResult(
            workflow: workflow,
            discovery: DiscoveryResult(
                root: directory.url.path,
                containers: [],
                swiftFiles: []
            ),
            origins: [
                .scheme: .automatic,
                .sdk: .automatic,
                .destination: .automatic,
            ],
            selectedContainer: nil,
            resolution: nil,
            notes: ["Synthetic setup completed."]
        )
        let service = FakeTUIOperationService(.result(.automaticSetup(result)))
        let controller = makeTUIController(
            service: service,
            directory: directory
        )

        controller.start(.automaticSetup)
        let canvas = TUIScreenRenderer(
            theme: TerminalTheme(),
            capabilities: TerminalCapabilities(
                colorMode: .monochrome,
                symbolMode: .unicode,
                highContrast: false,
                reducedMotion: true,
                mouseSupported: false
            )
        ).render(
            controller.state,
            size: TerminalSize(columns: 80, rows: 24)
        )
        XCTAssertEqual(canvas.rows.count, 24)

        waitForOperations(controller)
        XCTAssertEqual(controller.state.settings.workflow.scheme, "Sample")
        XCTAssertEqual(controller.state.setupOrigins[.scheme], .automatic)
    }

    func testCompletedAutomaticSetupQueuesDoctorWithoutStartingAnalysis()
        throws
    {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.doctor(TUIDoctorResult(lines: ["Ready"], issues: [])))
            ),
            directory: directory
        )
        var workflow = controller.state.settings.workflow
        workflow.projectRoot = directory.url.path
        workflow.scheme = "Synthetic"
        workflow.buildConfiguration = "Debug"
        workflow.sdkIdentifiers = ["macosx"]
        workflow.destination = "platform=macOS"
        let result = TUIAutomaticSetupResult(
            workflow: workflow,
            discovery: DiscoveryResult(
                root: directory.url.path,
                containers: [controller.state.selectedContainer!],
                swiftFiles: []
            ),
            origins: controller.state.setupOrigins,
            selectedContainer: controller.state.selectedContainer,
            resolution: nil,
            notes: []
        )
        controller.state.doctorResult = nil

        controller.accept(.automaticSetup(result))

        XCTAssertEqual(controller.state.pendingOperation, .doctor)
        XCTAssertNil(controller.state.report)
        XCTAssertNil(controller.state.repairPlan)
    }

    func testCustomizeSetupIsNavigationAndShowsSelectionOrigins() throws {
        let directory = try TUITestDirectory()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.discovery(DiscoveryResult(
                    root: directory.url.path,
                    containers: [],
                    swiftFiles: []
                )))
            ),
            directory: directory
        )
        controller.state.setupOrigins[.baselineXcode] = .automatic
        let homeRows = TUIContentRows.rows(for: controller.state)
        let index = try XCTUnwrap(homeRows.firstIndex {
            $0.label == "Customize Setup"
        })
        guard case .navigate(.setup) = homeRows[index].action else {
            XCTFail("Customize Setup must be a navigation item")
            return
        }

        controller.state.contentIndex = index
        controller.handle(.enter, terminalSize: .minimum)

        XCTAssertEqual(controller.state.screen, .setup)
        XCTAssertTrue(
            TUIContentRows.rows(for: controller.state).contains {
                $0.label == "Baseline Xcode"
                    && $0.value.contains("Automatic")
            }
        )
    }

    func testChoosingSetupFieldPreservesValueUntilReplacementIsConfirmed() throws {
        let directory = try TUITestDirectory()
        let service = FakeTUIOperationService(
            .result(.discovery(DiscoveryResult(
                root: directory.url.path,
                containers: [],
                swiftFiles: []
            )))
        )
        let controller = makeTUIController(
            screen: .setup,
            service: service,
            directory: directory
        )
        controller.state.setupOrigins[.baselineXcode] = .saved
        let index = try XCTUnwrap(
            TUIContentRows.rows(for: controller.state).firstIndex {
                $0.label == "Baseline Xcode"
            }
        )
        controller.state.contentIndex = index

        controller.handle(.enter, terminalSize: .minimum)

        XCTAssertEqual(
            controller.state.settings.workflow.baselineXcodePath,
            "/Synthetic/Baseline.app"
        )
        XCTAssertEqual(controller.state.setupOrigins[.baselineXcode], .saved)
        waitForOperations(controller)
        XCTAssertEqual(service.kinds(), [.automaticSetup])
    }

    func testResolutionSheetSupportsKeyboardAndMouseDoubleClick()
        throws
    {
        let directory = try TUITestDirectory()
        let clock = TUITestClock()
        let controller = makeTUIController(
            service: FakeTUIOperationService(
                .result(.discovery(DiscoveryResult(
                    root: directory.url.path,
                    containers: [],
                    swiftFiles: []
                )))
            ),
            directory: directory,
            clock: clock
        )
        let resolution = TUISetupResolution(
            field: .scheme,
            title: "Choose scheme",
            message: "Choose one value.",
            choices: [
                TUISetupChoice(
                    label: "First",
                    detail: "Shared scheme",
                    value: .scheme("First"),
                    recommended: true
                ),
                TUISetupChoice(
                    label: "Second",
                    detail: "Shared scheme",
                    value: .scheme("Second"),
                    recommended: false
                ),
            ],
            technicalDetails: "Synthetic details"
        )
        controller.state.overlay = .setupResolution(resolution)
        controller.handle(.down, terminalSize: TerminalSize(columns: 100, rows: 28))
        guard case let .setupResolution(updated) = controller.state.overlay else {
            return XCTFail("Expected setup sheet")
        }
        XCTAssertEqual(updated.selectedIndex, 1)

        controller.handle(.escape, terminalSize: .minimum)
        controller.state.overlay = .setupResolution(resolution)
        let choiceRow = (28 - 21) / 2 + 6
        let click = TUIKey.mouse(TUIMouseEvent(
            kind: .press,
            button: 0,
            column: 20,
            row: choiceRow
        ))
        controller.handle(click, terminalSize: TerminalSize(columns: 100, rows: 28))
        clock.advance(by: 0.1)
        controller.handle(click, terminalSize: TerminalSize(columns: 100, rows: 28))

        XCTAssertEqual(controller.state.settings.workflow.scheme, "First")
        XCTAssertEqual(controller.state.screen, .project)
    }

    func testResolutionSheetUsesNativeBackgroundAcrossCapabilityModes() {
        var state = TUIState(
            settings: TUISettings(),
            history: TUIHistory(),
            safeMode: true
        )
        state.overlay = .setupResolution(TUISetupResolution(
            field: .sdk,
            title: "Choose platform",
            message: "Select one context.",
            choices: [
                TUISetupChoice(
                    label: "iOS device",
                    detail: "iphoneos",
                    value: .sdk(
                        identifier: "iphoneos",
                        destination: "generic/platform=iOS"
                    ),
                    recommended: true
                ),
            ],
            technicalDetails: "Synthetic"
        ))
        for color in [
            TerminalColorMode.trueColor,
            .indexed256,
            .basic,
            .monochrome,
        ] {
            for symbols in [TerminalSymbolMode.unicode, .ascii] {
                let capabilities = TerminalCapabilities(
                    colorMode: color,
                    symbolMode: symbols,
                    highContrast: color == .monochrome,
                    reducedMotion: true,
                    mouseSupported: false
                )
                let canvas = TUIScreenRenderer(
                    theme: TerminalTheme(),
                    capabilities: capabilities
                ).render(
                    state,
                    size: TerminalSize(columns: 80, rows: 24)
                )
                let reversed = canvas.rows.flatMap { $0 }.count {
                    $0.style.reverse
                }
                XCTAssertEqual(reversed, 0)
                XCTAssertEqual(canvas.rows.count, 24)
            }
        }
    }

    private func makeXcode(
        named name: String,
        version: String,
        build: String,
        sdk: String,
        in root: URL
    ) throws -> String {
        let application = root.appendingPathComponent(name)
        let executable = application.appendingPathComponent(
            "Contents/Developer/usr/bin/xcodebuild"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data()
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.dt.Xcode",
            "CFBundleShortVersionString": version,
            "DTXcodeBuild": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(
            to: application.appendingPathComponent("Contents/Info.plist")
        )
        try FileManager.default.createDirectory(
            at: application.appendingPathComponent(
                "Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/\(sdk)"
            ),
            withIntermediateDirectories: true
        )
        return application.path
    }

    private func writeXcodeBundleIdentity(
        at application: URL,
        version: String,
        build: String
    ) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.dt.Xcode",
            "CFBundleShortVersionString": version,
            "DTXcodeBuild": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        let url = application.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
