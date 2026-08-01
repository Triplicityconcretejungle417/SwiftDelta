//===--- JSONSchemaContractTests.swift - SwiftDelta ------------------------------------------===//
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
import CoreFoundation
import SwiftDeltaCore
import XCTest

final class JSONSchemaContractTests: XCTestCase {
    func testNativeReportAndRepairPlanConformToCheckedInSchemas() throws {
        let report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/Synthetic",
            referenceResolutionCoverage: [
                ReferenceResolutionCoverage(
                    sdkIdentifier: "syntheticos",
                    toolchainRole: "candidate",
                    filesRequested: 1,
                    filesAnalyzed: 1,
                    filesWithoutSDKReferences: 1,
                    filesFailed: 0,
                    compilerExitStatus: 0,
                    sourceFiles: [
                        SourceAnalysisRecord(
                            path: "/Synthetic/File.swift",
                            disposition: .analyzedWithoutSDKReferences
                        ),
                    ]
                ),
            ],
            findings: []
        )
        try assertConforms(
            instanceData: JSONReportRenderer.render(report),
            schemaName: "SwiftDeltaReport.schema.json"
        )

        let modelRepair = ProposedRepair(
            repairIdentifier: "repair.synthetic.foundation-models",
            relatedFindingIdentifier: "finding.synthetic",
            evidenceSource: .foundationModels,
            language: .swift,
            filePath: "Sources/App.swift",
            sourceRange: RepairSourceRange(
                start: RepairSourcePosition(
                    line: 1,
                    column: 1,
                    utf8Offset: 0
                ),
                end: RepairSourcePosition(
                    line: 1,
                    column: 8,
                    utf8Offset: 7
                )
            ),
            originalText: "oldCall",
            replacementText: "newCall",
            fileFingerprint: RepairFileFingerprint(
                digest: String(repeating: "0", count: 64),
                byteCount: 8
            ),
            confidence: .low,
            safety: .reviewRequired,
            explanation: "Candidate compiler and SDK evidence support this proposal.",
            verificationRequirement: .candidateBuild,
            generatedBy: "Apple Foundation Models",
            provider: "on-device",
            execution: "On-device",
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep",
            modelGenerated: true,
            requiresReview: true
        )
        let plan = RepairPlan(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/Synthetic",
            repairs: [modelRepair]
        )
        try assertConforms(
            instanceData: RepairPlanJSON.encode(plan),
            schemaName: "RepairPlan.schema.json"
        )
    }

    private func assertConforms(
        instanceData: Data,
        schemaName: String
    ) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repository
            .appendingPathComponent("Documentation/Schemas")
            .appendingPathComponent(schemaName)
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: schemaURL)
            ) as? [String: Any]
        )
        let instance = try JSONSerialization.jsonObject(with: instanceData)
        let errors = JSONSchemaSubsetValidator(root: schema).validate(instance)
        XCTAssertEqual(errors, [], errors.joined(separator: "\n"))
    }
}

/// Validates the JSON Schema keywords used by SwiftDelta's checked-in
/// contracts without adding a network-fetched test dependency.
private struct JSONSchemaSubsetValidator {
    let root: [String: Any]

    func validate(_ value: Any) -> [String] {
        validate(value, schema: root, path: "$")
    }

    private func validate(
        _ value: Any,
        schema: [String: Any],
        path: String
    ) -> [String] {
        if let reference = schema["$ref"] as? String,
           let resolved = resolve(reference)
        {
            return validate(value, schema: resolved, path: path)
        }
        var errors: [String] = []
        if let constant = schema["const"], !equal(value, constant) {
            errors.append("\(path) does not equal the schema constant")
        }
        if let allowed = schema["enum"] as? [Any],
           !allowed.contains(where: { equal(value, $0) })
        {
            errors.append("\(path) is not an allowed enum value")
        }
        if let acceptedTypes = typeNames(schema["type"]),
           !acceptedTypes.contains(where: { matchesType(value, $0) })
        {
            errors.append(
                "\(path) has type \(typeName(value)); expected "
                    + acceptedTypes.joined(separator: " or ")
            )
            return errors
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? []
                where object[key] == nil
            {
                errors.append("\(path) is missing required property \(key)")
            }
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] {
                    errors.append(
                        contentsOf: validate(
                            child,
                            schema: childSchema,
                            path: "\(path).\(key)"
                        )
                    )
                } else if let additional =
                    schema["additionalProperties"] as? [String: Any]
                {
                    errors.append(
                        contentsOf: validate(
                            child,
                            schema: additional,
                            path: "\(path).\(key)"
                        )
                    )
                } else if schema["additionalProperties"] as? Bool == false {
                    errors.append("\(path) contains unknown property \(key)")
                }
            }
        }
        if let array = value as? [Any],
           let itemSchema = schema["items"] as? [String: Any]
        {
            for (index, item) in array.enumerated() {
                errors.append(
                    contentsOf: validate(
                        item,
                        schema: itemSchema,
                        path: "\(path)[\(index)]"
                    )
                )
            }
        }
        if let minimum = schema["minimum"] as? NSNumber,
           let number = value as? NSNumber,
           number.doubleValue < minimum.doubleValue
        {
            errors.append("\(path) is below the schema minimum")
        }
        return errors
    }

    private func resolve(_ reference: String) -> [String: Any]? {
        guard reference.hasPrefix("#/") else {
            return nil
        }
        var current: Any = root
        for component in reference.dropFirst(2).split(separator: "/") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(component)]
            else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }

    private func typeNames(_ value: Any?) -> [String]? {
        if let value = value as? String {
            return [value]
        }
        return value as? [String]
    }

    private func matchesType(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBoolean(value)
        case "integer":
            guard !isBoolean(value), let number = value as? NSNumber else {
                return false
            }
            return number.doubleValue.rounded() == number.doubleValue
        case "number": return value is NSNumber && !isBoolean(value)
        default: return true
        }
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func typeName(_ value: Any) -> String {
        for type in [
            "null", "object", "array", "string", "boolean", "integer", "number",
        ] where matchesType(value, type) {
            return type
        }
        return String(describing: Swift.type(of: value))
    }

    private func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) == true
    }
}
