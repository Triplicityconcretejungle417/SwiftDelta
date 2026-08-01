//===--- SDKSnapshotDifferTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKSnapshotDifferTests: XCTestCase {
    func testPropertyProtocolInheritanceAndConformanceChangesAreStructured() {
        let identity = makeSDKIdentity(
            xcode: "1.0",
            build: "1A1",
            sdk: "1.0",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.relations",
            "Container.value",
            kind: "swift.property",
            declaration: "var value: Int { get set }",
            relationships: [
                SDKSymbolRelationship(kind: "requirementOf", target: "usr.protocol.one"),
                SDKSymbolRelationship(kind: "inheritsFrom", target: "usr.base.one"),
                SDKSymbolRelationship(kind: "conformsTo", target: "usr.conformance.one"),
            ],
            propertyReadable: true,
            propertyWritable: true,
            isProtocolRequirement: true
        )
        let new = makeSDKSymbol(
            "usr.relations",
            "Container.value",
            kind: "swift.property",
            declaration: "var value: Int { get }",
            relationships: [
                SDKSymbolRelationship(kind: "requirementOf", target: "usr.protocol.two"),
                SDKSymbolRelationship(kind: "inheritsFrom", target: "usr.base.two"),
                SDKSymbolRelationship(kind: "conformsTo", target: "usr.conformance.two"),
            ],
            propertyReadable: true,
            propertyWritable: false,
            isProtocolRequirement: true
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(identity: identity, modules: ["FictionalSDK"], symbols: [old]),
            candidate: SDKSnapshot(identity: identity, modules: ["FictionalSDK"], symbols: [new])
        )

        XCTAssertTrue(changes.contains { $0.kind == .propertyAccessChanged })
        XCTAssertTrue(changes.contains { $0.kind == .protocolRequirementChanged })
        XCTAssertTrue(changes.contains { $0.kind == .inheritanceChanged })
        XCTAssertTrue(changes.contains { $0.kind == .conformanceChanged })
    }

    func testDuplicateCandidateIdentitiesRemainConservativeInsteadOfTrapping() {
        let identity = makeSDKIdentity(
            xcode: "1.0",
            build: "1A1",
            sdk: "1.0",
            path: "/Synthetic/Xcode.app"
        )
        let baseline = makeSDKSymbol(
            "usr.duplicate",
            "Container.value()",
            declaration: "func value() -> Int",
            returnType: "Int"
        )
        let firstCandidate = makeSDKSymbol(
            "usr.duplicate",
            "Container.value()",
            declaration: "func value() -> String",
            returnType: "String"
        )
        let secondCandidate = makeSDKSymbol(
            "usr.duplicate",
            "Container.value()",
            declaration: "func value() -> Bool",
            returnType: "Bool"
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [baseline]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [firstCandidate, secondCandidate]
            )
        )

        XCTAssertFalse(changes.isEmpty)
        XCTAssertTrue(
            changes.allSatisfy { $0.matchConfidence == .low },
            "\(changes.map { ($0.kind.rawValue, $0.matchConfidence.rawValue) })"
        )
    }

    func testSourceCompatibleOverloadWithDefaultedParametersIsNotRemoved() {
        let identity = makeSDKIdentity(
            xcode: "1.0",
            build: "1A1",
            sdk: "1.0",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.old.operation",
            "Container.perform(operation:)",
            declaration: "func perform(operation: () -> Void)",
            parameters: [
                SDKFunctionParameter(
                    name: "operation",
                    externalName: "operation",
                    type: "() -> Void"
                ),
            ]
        )
        let replacement = makeSDKSymbol(
            "usr.new.operation",
            "Container.perform(operation:name:)",
            declaration: "func perform(operation: () -> Void, name: String? = nil)",
            parameters: [
                SDKFunctionParameter(
                    name: "operation",
                    externalName: "operation",
                    type: "() -> Void"
                ),
                SDKFunctionParameter(
                    name: "name",
                    externalName: "name",
                    type: "String?",
                    hasDefaultValue: true
                ),
            ]
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [replacement]
            )
        )

        XCTAssertFalse(changes.contains { $0.kind == .removed })
        XCTAssertTrue(changes.isEmpty)
    }

    func testIncompatibleReplacementDoesNotHideGenuineRemoval() {
        let identity = makeSDKIdentity(
            xcode: "1.0",
            build: "1A1",
            sdk: "1.0",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.old.operation",
            "Container.perform(value:)",
            declaration: "func perform(value: Int)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "value",
                    type: "Int"
                ),
            ]
        )
        let incompatible = makeSDKSymbol(
            "usr.new.operation",
            "Container.perform(value:required:)",
            declaration: "func perform(value: String, required: Bool)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "value",
                    type: "String"
                ),
                SDKFunctionParameter(
                    name: "required",
                    externalName: "required",
                    type: "Bool",
                    hasDefaultValue: false
                ),
            ]
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [incompatible]
            )
        )

        XCTAssertEqual(changes.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(
            changes.first { $0.kind == .removed }?.matchConfidence,
            .high
        )
    }

    func testMissingDefaultMetadataCannotProduceConfirmedRemoval() {
        let identity = makeSDKIdentity(
            xcode: "1.0",
            build: "1A1",
            sdk: "1.0",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.old.operation",
            "Container.perform(value:)",
            declaration: "func perform(value: Int)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "value",
                    type: "Int"
                ),
            ]
        )
        let uncertain = makeSDKSymbol(
            "usr.new.operation",
            "Container.perform(value:context:)",
            declaration: "func perform(value: Int, context: String?)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "value",
                    type: "Int"
                ),
                SDKFunctionParameter(
                    name: "context",
                    externalName: "context",
                    type: "String?"
                ),
            ]
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [uncertain]
            )
        )

        let removal = changes.first { $0.kind == .removed }
        XCTAssertEqual(removal?.matchConfidence, .low)
        XCTAssertTrue(
            removal?.observedChange.contains(
                "source compatibility could not be confirmed"
            ) == true
        )
    }

    func testAvailabilityComparisonUsesOnlySelectedPlatform() {
        let identity = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode.app",
            developerDirectory: "/Synthetic/Xcode.app/Contents/Developer",
            xcodeVersion: "1",
            xcodeBuild: "1A1",
            platform: "iOS",
            sdkIdentifier: "iphoneos",
            sdkVersion: "1",
            sdkPath: "/Synthetic/iPhoneOS.sdk"
        )
        let old = makeSDKSymbol(
            "usr.platform",
            "Container.platformValue()",
            declaration: "func platformValue()",
            availability: [
                SDKAvailability(domain: "iOS", introduced: "17.0"),
                SDKAvailability(domain: "watchOS", introduced: "10.0"),
            ]
        )
        let new = makeSDKSymbol(
            "usr.platform",
            "Container.platformValue()",
            declaration: "func platformValue()",
            availability: [
                SDKAvailability(domain: "iOS", introduced: "17.0"),
                SDKAvailability(domain: "watchOS", introduced: "12.0"),
            ]
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [new]
            )
        )

        XCTAssertFalse(changes.contains { $0.kind == .availabilityChanged })
    }

    func testEquivalentPlatformAndVersionSpellingsDoNotCreateChange() {
        let identity = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode.app",
            developerDirectory: "/Synthetic/Xcode.app/Contents/Developer",
            xcodeVersion: "1",
            xcodeBuild: "1A1",
            platform: "iOS",
            sdkIdentifier: "iphoneos",
            sdkVersion: "1",
            sdkPath: "/Synthetic/iPhoneOS.sdk"
        )
        let old = makeSDKSymbol(
            "usr.equivalent",
            "Container.value()",
            declaration: "func value()",
            availability: [
                SDKAvailability(domain: "iOS", introduced: "17.0"),
                SDKAvailability(domain: "iOS", introduced: "17.0"),
            ]
        )
        let new = makeSDKSymbol(
            "usr.equivalent",
            "Container.value()",
            declaration: "func value()",
            availability: [
                SDKAvailability(domain: "ios", introduced: "17.0.0"),
            ]
        )

        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [new]
            )
        )

        XCTAssertTrue(changes.isEmpty)
    }
}
