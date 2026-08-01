//===--- SymbolGraphNormalizerTests.swift - SwiftDelta ------------------------------------------===//
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

final class SymbolGraphNormalizerTests: XCTestCase {
    func testSymbolGraphNormalizationCapturesStructuredMetadata() throws {
        let data = Data(
            """
            {
              "module": {"name": "FictionalSDK"},
              "symbols": [
                {
                  "kind": {"identifier": "swift.method", "displayName": "Instance Method"},
                  "identifier": {"precise": "usr.fictional.migrate", "interfaceLanguage": "swift"},
                  "pathComponents": ["Gizmo", "migrate(old:)"],
                  "names": {
                    "title": "migrate(old:)",
                    "subHeading": [
                      {"kind": "attribute", "spelling": "@SyntheticActor "},
                      {"kind": "keyword", "spelling": "func"},
                      {"kind": "text", "spelling": " migrate(old: Int) async -> String"}
                    ]
                  },
                  "declarationFragments": [
                    {"kind": "attribute", "spelling": "@SyntheticActor "},
                    {"kind": "keyword", "spelling": "func"},
                    {"kind": "text", "spelling": " migrate("},
                    {"kind": "externalParam", "spelling": "old"},
                    {"kind": "text", "spelling": " value: "},
                    {"kind": "typeIdentifier", "spelling": "Int"},
                    {"kind": "text", "spelling": ") async -> "},
                    {"kind": "typeIdentifier", "spelling": "String"}
                  ],
                  "functionSignature": {
                    "parameters": [
                      {
                        "name": "old",
                        "internalName": "value",
                        "declarationFragments": [
                          {"kind": "identifier", "spelling": "value"},
                          {"kind": "text", "spelling": ": "},
                          {"kind": "typeIdentifier", "spelling": "Int"},
                          {"kind": "text", "spelling": " = 1"}
                        ]
                      }
                    ],
                    "returns": [{"kind": "typeIdentifier", "spelling": "String"}]
                  },
                  "availability": [
                    {
                      "domain": "SyntheticOS",
                      "introduced": {"major": 2, "minor": 1},
                      "deprecated": {"major": 3},
                      "renamed": "Gizmo.migrate(new:)",
                      "message": "Use the new label."
                    }
                  ]
                }
              ],
              "relationships": [
                {
                  "kind": "requirementOf",
                  "source": "usr.fictional.migrate",
                  "target": "usr.fictional.protocol"
                }
              ]
            }
            """.utf8
        )

        let symbol = try XCTUnwrap(
            SymbolGraphNormalizer.normalize([data], requestedModule: "FictionalSDK").first
        )

        XCTAssertEqual(symbol.preciseIdentifier, "usr.fictional.migrate")
        XCTAssertEqual(symbol.fullyQualifiedName, "FictionalSDK.Gizmo.migrate(old:)")
        XCTAssertEqual(symbol.parameters.first?.externalName, "old")
        XCTAssertEqual(symbol.parameters.first?.type, "Int")
        XCTAssertEqual(symbol.parameters.first?.hasDefaultValue, true)
        XCTAssertEqual(symbol.returnType, "String")
        XCTAssertEqual(symbol.availability.first?.introduced, "2.1")
        XCTAssertEqual(symbol.availability.first?.deprecated, "3")
        XCTAssertEqual(symbol.renamedDestination, "Gizmo.migrate(new:)")
        XCTAssertEqual(symbol.migrationMessage, "Use the new label.")
        XCTAssertEqual(symbol.concurrency.actorIsolation, "SyntheticActor")
        XCTAssertTrue(symbol.concurrency.isAsync)
        XCTAssertTrue(symbol.isProtocolRequirement)
    }

    func testConcurrencyKeywordsRequireWholeTokens() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "module": ["name": "FictionalSDK"],
            "symbols": [
                [
                    "kind": ["identifier": "swift.method"],
                    "identifier": ["precise": "usr.fictional.tokens"],
                    "pathComponents": ["Gizmo", "asyncMethod()"],
                    "declarationFragments": [
                        [
                            "spelling":
                                "@NotActorish func asyncMethod("
                                + "_ value: NotSendableThing"
                                + ") -> nonisolatedValue",
                        ],
                    ],
                ],
            ],
        ])

        let symbol = try XCTUnwrap(
            SymbolGraphNormalizer.normalize([data]).first
        )
        XCTAssertNil(symbol.concurrency.actorIsolation)
        XCTAssertFalse(symbol.concurrency.isAsync)
        XCTAssertFalse(symbol.concurrency.isSendable)
        XCTAssertFalse(symbol.concurrency.isNonisolated)
    }

    func testLargeSymbolGraphNormalizationRemainsBounded() throws {
        let count = 5_000
        let symbols = (0..<count).map { index in
            [
                "kind": ["identifier": "swift.method"],
                "identifier": ["precise": "usr.fictional.\(index)"],
                "pathComponents": ["Gizmo", "operation\(index)(value:)"],
                "declarationFragments": [
                    [
                        "spelling":
                            "@SyntheticActor public func operation\(index)"
                            + "(value: Int) async -> String",
                    ],
                ],
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "module": ["name": "FictionalSDK"],
            "symbols": symbols,
        ])

        let start = ProcessInfo.processInfo.systemUptime
        let normalized = try SymbolGraphNormalizer.normalize([data])
        let duration = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(normalized.count, count)
        XCTAssertTrue(normalized.allSatisfy(\.concurrency.isAsync))
        XCTAssertTrue(
            normalized.allSatisfy {
                $0.concurrency.actorIsolation == "SyntheticActor"
            }
        )
        XCTAssertLessThan(
            duration,
            15,
            "Normalizing 5,000 compact symbols must remain bounded."
        )
        print(
            "SYMBOL_GRAPH_NORMALIZATION_BENCHMARK "
                + "symbols=\(count) seconds=\(duration)"
        )
    }

    func testExactDuplicateSymbolsAvailabilityAndRelationshipsAreRemoved()
        throws
    {
        let symbol: [String: Any] = [
            "kind": ["identifier": "swift.method"],
            "identifier": ["precise": "usr.fictional.duplicate"],
            "pathComponents": ["Gizmo", "operation()"],
            "declarationFragments": [
                ["spelling": "public func operation()"],
            ],
            "availability": [
                ["domain": "SyntheticOS", "introduced": ["major": 1]],
                ["domain": "SyntheticOS", "introduced": ["major": 1]],
            ],
        ]
        let graph = try JSONSerialization.data(withJSONObject: [
            "module": ["name": "FictionalSDK"],
            "symbols": [symbol, symbol],
            "relationships": [
                [
                    "kind": "memberOf",
                    "source": "usr.fictional.duplicate",
                    "target": "usr.fictional.parent",
                ],
                [
                    "kind": "memberOf",
                    "source": "usr.fictional.duplicate",
                    "target": "usr.fictional.parent",
                ],
            ],
        ])

        let normalized = try SymbolGraphNormalizer.normalize([graph])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].availability.count, 1)
        XCTAssertEqual(normalized[0].relationships.count, 1)
    }
}
