//===--- RealTUISetupDiscoveryTests.swift - SwiftDelta ------------------------------------------===//
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
import XCTest

final class RealTUISetupDiscoveryTests: XCTestCase {
    func testOptInProjectDiscoversIOSDeviceWithoutSelectingItImplicitly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let project = environment["SWIFTDELTA_REAL_SETUP_PROJECT"],
              let baseline = environment["SWIFTDELTA_REAL_BASELINE_XCODE"],
              let candidate = environment["SWIFTDELTA_REAL_CANDIDATE_XCODE"]
        else {
            throw XCTSkip("Real read-only setup discovery was not requested.")
        }
        var settings = TUISettings()
        settings.workflow.projectRoot = project
        settings.workflow.baselineXcodePath = baseline
        settings.workflow.candidateXcodePath = candidate
        settings.workflow.setupValueOrigins = [
            TUISetupField.baselineXcode.rawValue: .saved,
            TUISetupField.candidateXcode.rawValue: .saved,
        ]
        settings.workflow.doctorTimeout = 120

        for _ in 0..<8 {
            let result = try CoreTUIOperationService().perform(
                .automaticSetup,
                request: TUIOperationRequest(
                    settings: settings,
                    report: nil,
                    repairPlan: nil,
                    selectedRepairIdentifiers: []
                ),
                cancellation: { false },
                progress: { _ in }
            )
            guard case let .automaticSetup(setup) = result else {
                return XCTFail("Expected setup discovery result.")
            }
            settings.workflow = setup.workflow
            guard let resolution = setup.resolution else {
                return XCTFail("Platform selection must remain explicit.")
            }
            if resolution.field == .sdk {
                XCTAssertNotNil(setup.selectedContainer)
                XCTAssertNotNil(setup.workflow.scheme)
                XCTAssertTrue(setup.workflow.sdkIdentifiers.isEmpty)
                XCTAssertTrue(resolution.choices.contains {
                    guard case let .sdk(identifier, destination) = $0.value else {
                        return false
                    }
                    return identifier == "iphoneos"
                        && destination == "generic/platform=iOS"
                })
                return
            }
            guard let choice = resolution.choices.first(where: {
                $0.enabled && $0.recommended
            }) ?? resolution.choices.first(where: { $0.enabled }) else {
                return XCTFail("No selectable setup choice.")
            }
            apply(choice.value, to: &settings.workflow)
        }
        XCTFail("Setup discovery did not reach platform selection.")
    }

    func testOptInReadOnlyDoctorAnalysisAndRepairPreview() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFTDELTA_RUN_REAL_READONLY_SMOKE"] == "1",
              let project = environment["SWIFTDELTA_REAL_SETUP_PROJECT"],
              let baseline = environment["SWIFTDELTA_REAL_BASELINE_XCODE"],
              let candidate = environment["SWIFTDELTA_REAL_CANDIDATE_XCODE"]
        else {
            throw XCTSkip("Real read-only workflow smoke testing was not requested.")
        }
        var settings = TUISettings()
        settings.workflow.projectRoot = project
        settings.workflow.baselineXcodePath = baseline
        settings.workflow.candidateXcodePath = candidate
        settings.workflow.setupValueOrigins = [
            TUISetupField.baselineXcode.rawValue: .saved,
            TUISetupField.candidateXcode.rawValue: .saved,
        ]
        settings.workflow.timeout = 300
        settings.workflow.doctorTimeout = 120
        settings.workflow.sdkCachePolicy = .disabled
        let service = CoreTUIOperationService()

        for _ in 0..<12 {
            let result = try service.perform(
                .automaticSetup,
                request: TUIOperationRequest(
                    settings: settings,
                    report: nil,
                    repairPlan: nil,
                    selectedRepairIdentifiers: []
                ),
                cancellation: { false },
                progress: { _ in }
            )
            guard case let .automaticSetup(setup) = result else {
                return XCTFail("Expected setup discovery result.")
            }
            settings.workflow = setup.workflow
            guard let resolution = setup.resolution else { break }
            let choice: TUISetupChoice?
            if resolution.field == .sdk {
                choice = resolution.choices.first {
                    guard case let .sdk(identifier, destination) = $0.value else {
                        return false
                    }
                    return identifier == "iphoneos"
                        && destination == "generic/platform=iOS"
                        && $0.enabled
                }
            } else {
                choice = resolution.choices.first {
                    $0.enabled && $0.recommended
                } ?? resolution.choices.first(where: \.enabled)
            }
            guard let choice else {
                return XCTFail(
                    "No valid choice for \(resolution.field.rawValue)."
                )
            }
            apply(choice.value, to: &settings.workflow)
        }

        let doctorResult = try service.perform(
            .doctor,
            request: TUIOperationRequest(
                settings: settings,
                report: nil,
                repairPlan: nil,
                selectedRepairIdentifiers: []
            ),
            cancellation: { false },
            progress: { _ in }
        )
        guard case let .doctor(doctor) = doctorResult else {
            return XCTFail("Expected Doctor result.")
        }
        guard doctor.issues.isEmpty else {
            throw XCTSkip(
                "Read-only Analysis and Repair preview were blocked by Doctor: "
                    + doctor.issues.joined(separator: " | ")
            )
        }

        let analysisResult = try service.perform(
            .compare,
            request: TUIOperationRequest(
                settings: settings,
                report: nil,
                repairPlan: nil,
                selectedRepairIdentifiers: []
            ),
            cancellation: { false },
            progress: { _ in }
        )
        guard case let .report(report) = analysisResult else {
            return XCTFail("Expected Analysis report.")
        }
        let previewResult = try service.perform(
            .planRepair,
            request: TUIOperationRequest(
                settings: settings,
                report: report,
                repairPlan: nil,
                selectedRepairIdentifiers: []
            ),
            cancellation: { false },
            progress: { _ in }
        )
        switch previewResult {
        case .repairPlan, .preparedRepairPlan:
            break
        default:
            return XCTFail("Expected read-only Repair preview.")
        }
    }

    private func apply(
        _ choice: TUISetupChoiceValue,
        to workflow: inout TUIWorkflowSettings
    ) {
        var origins = workflow.setupValueOrigins ?? [:]
        switch choice {
        case let .project(path):
            workflow.projectPath = path
            workflow.workspacePath = nil
            origins[TUISetupField.container.rawValue] = .saved
        case let .workspace(path):
            workflow.workspacePath = path
            workflow.projectPath = nil
            origins[TUISetupField.container.rawValue] = .saved
        case let .packageRoot(path):
            workflow.projectRoot = path
            origins[TUISetupField.container.rawValue] = .saved
        case let .scheme(value):
            workflow.scheme = value
            origins[TUISetupField.scheme.rawValue] = .saved
        case let .buildConfiguration(value):
            workflow.buildConfiguration = value
            origins[TUISetupField.buildConfiguration.rawValue] = .saved
        case let .sdk(identifier, destination):
            workflow.sdkIdentifiers = [identifier]
            workflow.destination = destination
            origins[TUISetupField.sdk.rawValue] = .saved
            origins[TUISetupField.destination.rawValue] = .automatic
        case .baselineXcode, .candidateXcode, .manual:
            XCTFail("Unexpected setup choice before platform selection.")
        }
        workflow.setupValueOrigins = origins
    }
}
