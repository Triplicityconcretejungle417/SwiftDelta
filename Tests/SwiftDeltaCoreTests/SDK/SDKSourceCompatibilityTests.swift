//===--- SDKSourceCompatibilityTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKSourceCompatibilityTests: XCTestCase {
    func testDefaultedParametersBindAtBeginningMiddleAndEnd() {
        let baseline = callable(
            "usr.old",
            declaration: "func render(value: Int, body: () -> Void)",
            parameters: [
                parameter("value", "Int"),
                parameter("body", "() -> Void"),
            ]
        )
        for (suffix, parameters) in [
            (
                "beginning",
                [
                    parameter("context", "String", defaulted: true),
                    parameter("value", "Int"),
                    parameter("body", "() -> Void"),
                ]
            ),
            (
                "middle",
                [
                    parameter("value", "Int"),
                    parameter("context", "String", defaulted: true),
                    parameter("body", "() -> Void"),
                ]
            ),
            (
                "end",
                [
                    parameter("value", "Int"),
                    parameter("body", "() -> Void"),
                    parameter("context", "String", defaulted: true),
                ]
            ),
        ] {
            let candidate = callable(
                "usr.new.\(suffix)",
                declaration: "func render(...)",
                parameters: parameters
            )
            XCTAssertCompatible(baseline, candidate)
        }
    }

    func testLabelsOrderingTrailingClosuresAndVariadicsAreBoundConservatively() {
        let baseline = callable(
            "usr.old",
            declaration:
                "func render(value: Int, content: () -> Void, completion: () -> Void)",
            parameters: [
                parameter("value", "Int"),
                parameter("content", "() -> Void"),
                parameter("completion", "() -> Void"),
            ]
        )
        let compatible = callable(
            "usr.new",
            declaration:
                "func render(value: Int, metadata: String = \"\", content: () -> Void, completion: () -> Void, tags: String...)",
            parameters: [
                parameter("value", "Int"),
                parameter("metadata", "String", defaulted: true),
                parameter("content", "() -> Void"),
                parameter("completion", "() -> Void"),
                parameter("tags", "String..."),
            ]
        )
        XCTAssertCompatible(baseline, compatible)

        let relabeled = callable(
            "usr.relabeled",
            declaration: "func render(input: Int, content: () -> Void, completion: () -> Void)",
            parameters: [
                parameter("input", "Int"),
                parameter("content", "() -> Void"),
                parameter("completion", "() -> Void"),
            ]
        )
        XCTAssertIncompatible(baseline, relabeled)

        let reordered = callable(
            "usr.reordered",
            declaration: "func render(content: () -> Void, value: Int, completion: () -> Void)",
            parameters: [
                parameter("content", "() -> Void"),
                parameter("value", "Int"),
                parameter("completion", "() -> Void"),
            ]
        )
        XCTAssertIncompatible(baseline, reordered)
    }

    func testGenericResultBuilderOptionalityAndOwnershipChangesStayConservative() {
        let baseline = callable(
            "usr.old",
            declaration: "func build<T>(value: T, content: @FictionalBuilder () -> T) -> T",
            parameters: [
                parameter("value", "T"),
                parameter("content", "@FictionalBuilder () -> T"),
            ],
            returnType: "T"
        )
        let strongerGeneric = callable(
            "usr.generic",
            declaration:
                "func build<T>(value: T, content: @FictionalBuilder () -> T) -> T where T: Equatable",
            parameters: baseline.parameters,
            returnType: "T"
        )
        XCTAssertUncertain(baseline, strongerGeneric)

        let changedBuilder = callable(
            "usr.builder",
            declaration: "func build<T>(value: T, content: @OtherBuilder () -> T) -> T",
            parameters: [
                parameter("value", "T"),
                parameter("content", "@OtherBuilder () -> T"),
            ],
            returnType: "T"
        )
        XCTAssertIncompatible(baseline, changedBuilder)

        let widenedInput = callable(
            "usr.optional",
            declaration: "func build<T>(value: T?, content: @FictionalBuilder () -> T) -> T",
            parameters: [
                parameter("value", "T?"),
                parameter("content", "@FictionalBuilder () -> T"),
            ],
            returnType: "T"
        )
        XCTAssertCompatible(baseline, widenedInput)

        let ownership = callable(
            "usr.ownership",
            declaration:
                "func build<T>(value: consuming T, content: @FictionalBuilder () -> T) -> T",
            parameters: [
                parameter("value", "consuming T"),
                parameter("content", "@FictionalBuilder () -> T"),
            ],
            returnType: "T"
        )
        XCTAssertIncompatible(baseline, ownership)
    }

    func testAsyncThrowsIsolationAndSendabilityAreDirectional() {
        let baseline = callable(
            "usr.old",
            declaration: "func perform(operation: () -> Void)",
            parameters: [parameter("operation", "() -> Void")]
        )
        let asyncCandidate = callable(
            "usr.async",
            declaration: "func perform(operation: () -> Void) async",
            parameters: baseline.parameters,
            concurrency: SDKConcurrencyMetadata(isAsync: true)
        )
        XCTAssertIncompatible(baseline, asyncCandidate)

        let throwingCandidate = callable(
            "usr.throws",
            declaration: "func perform(operation: () -> Void) throws",
            parameters: baseline.parameters
        )
        XCTAssertIncompatible(baseline, throwingCandidate)

        let isolatedCandidate = callable(
            "usr.actor",
            declaration: "@FictionalActor func perform(operation: () -> Void)",
            parameters: baseline.parameters,
            concurrency: SDKConcurrencyMetadata(actorIsolation: "FictionalActor")
        )
        XCTAssertUncertain(baseline, isolatedCandidate)

        let sendableCandidate = callable(
            "usr.sendable",
            declaration: "func perform(operation: @Sendable () -> Void)",
            parameters: [parameter("operation", "@Sendable () -> Void")],
            concurrency: SDKConcurrencyMetadata(isSendable: true)
        )
        XCTAssertUncertain(baseline, sendableCandidate)

        let restrictedBaseline = callable(
            "usr.restricted",
            declaration: "@FictionalActor func perform(operation: @Sendable () -> Void) async",
            parameters: [parameter("operation", "@Sendable () -> Void")],
            concurrency: SDKConcurrencyMetadata(
                actorIsolation: "FictionalActor",
                isAsync: true,
                isSendable: true
            )
        )
        XCTAssertCompatible(restrictedBaseline, baseline)
    }

    private func callable(
        _ identifier: String,
        declaration: String,
        parameters: [SDKFunctionParameter],
        returnType: String? = nil,
        concurrency: SDKConcurrencyMetadata = SDKConcurrencyMetadata()
    ) -> SDKSymbol {
        makeSDKSymbol(
            identifier,
            "Container.render(_:)",
            declaration: declaration,
            parameters: parameters,
            returnType: returnType,
            concurrency: concurrency
        )
    }

    private func parameter(
        _ label: String,
        _ type: String,
        defaulted: Bool? = false
    ) -> SDKFunctionParameter {
        SDKFunctionParameter(
            name: label,
            externalName: label,
            type: type,
            hasDefaultValue: defaulted
        )
    }

    private func XCTAssertCompatible(
        _ baseline: SDKSymbol,
        _ candidate: SDKSymbol,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .compatible = SDKSourceCompatibilityEvaluator.evaluate(
            baseline: baseline,
            candidate: candidate,
            platform: "SyntheticOS"
        ) else {
            return XCTFail("Expected compatible declarations", file: file, line: line)
        }
    }

    private func XCTAssertIncompatible(
        _ baseline: SDKSymbol,
        _ candidate: SDKSymbol,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .incompatible = SDKSourceCompatibilityEvaluator.evaluate(
            baseline: baseline,
            candidate: candidate,
            platform: "SyntheticOS"
        ) else {
            return XCTFail("Expected incompatible declarations", file: file, line: line)
        }
    }

    private func XCTAssertUncertain(
        _ baseline: SDKSymbol,
        _ candidate: SDKSymbol,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .uncertain = SDKSourceCompatibilityEvaluator.evaluate(
            baseline: baseline,
            candidate: candidate,
            platform: "SyntheticOS"
        ) else {
            return XCTFail("Expected uncertain declarations", file: file, line: line)
        }
    }
}
