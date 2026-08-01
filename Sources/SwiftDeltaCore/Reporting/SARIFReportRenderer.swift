//===--- SARIFReportRenderer.swift - SwiftDelta ------------------------------------------===//
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

public enum SARIFReportRenderer {
    public static func render(
        _ report: AnalysisReport
    ) throws -> Data {
        let findingsByID = Dictionary(grouping: report.findings, by: \.findingID)
        let ruleDescriptors: [[String: Any]] = findingsByID.keys.sorted().compactMap { id in
            guard let finding = findingsByID[id]?.first else {
                return nil
            }
            var descriptor: [String: Any] = [
                "id": id,
                "name": finding.title,
                "shortDescription": ["text": finding.title],
                "fullDescription": ["text": finding.explanation],
                "properties": [
                    "category": finding.category.rawValue,
                    "confidence": finding.confidence.rawValue,
                ],
            ]
            if let migrationMessage = finding.migrationMessage {
                descriptor["help"] = ["text": migrationMessage]
            }
            if let url = finding.referenceURL {
                descriptor["helpUri"] = url.absoluteString
            }
            return descriptor
        }

        let results: [[String: Any]] = report.findings.map { finding in
            var result: [String: Any] = [
                "ruleId": finding.findingID,
                "level": sarifLevel(finding.severity),
                "message": ["text": finding.explanation],
                "properties": [
                    "automaticRemediationSupported": finding.automaticRemediationSupported,
                    "category": finding.category.rawValue,
                    "confidence": finding.confidence.rawValue,
                    "origin": finding.origin.rawValue,
                ],
            ]
            if let migrationMessage = finding.migrationMessage,
               var properties = result["properties"] as? [String: Any]
            {
                properties["migrationMessage"] = migrationMessage
                result["properties"] = properties
            }
            if let evidence = finding.sdkEvidence,
               var properties = result["properties"] as? [String: Any]
            {
                properties["baselineXcodeVersion"] = evidence.baseline.xcodeVersion
                properties["baselineXcodeBuild"] = evidence.baseline.xcodeBuild
                properties["baselineSDKVersion"] = evidence.baseline.sdkVersion
                properties["candidateXcodeVersion"] = evidence.candidate.xcodeVersion
                properties["candidateXcodeBuild"] = evidence.candidate.xcodeBuild
                properties["candidateSDKVersion"] = evidence.candidate.sdkVersion
                properties["platform"] = evidence.platform
                properties["module"] = evidence.moduleName
                properties["fullyQualifiedName"] = evidence.fullyQualifiedName
                properties["changeKind"] = evidence.changeKind.rawValue
                properties["observedChange"] = evidence.observedChange
                properties["resolutionMethod"] = evidence.resolutionMethod.rawValue
                if let identifier = evidence.preciseIdentifier {
                    properties["symbolIdentifier"] = identifier
                }
                if let declaration = evidence.oldDeclaration {
                    properties["oldDeclaration"] = declaration
                }
                if let declaration = evidence.newDeclaration {
                    properties["newDeclaration"] = declaration
                }
                properties["oldAvailability"] = evidence.oldAvailability.map(\.description)
                properties["newAvailability"] = evidence.newAvailability.map(\.description)
                result["properties"] = properties
            }
            if let location = finding.location {
                var physicalLocation: [String: Any] = [
                    "artifactLocation": [
                        "uri": relativePath(
                            location.path,
                            projectRoot: report.projectRoot
                        ),
                        "uriBaseId": "PROJECT_ROOT",
                    ],
                ]
                if let line = location.line {
                    var region: [String: Any] = ["startLine": max(1, line)]
                    if let column = location.column {
                        region["startColumn"] = max(1, column)
                    }
                    physicalLocation["region"] = region
                }
                result["locations"] = [
                    ["physicalLocation": physicalLocation],
                ]
            }
            return result
        }

        let coverageProperties: [[String: Any]] = report.referenceResolutionCoverage.map {
            [
                "sdkIdentifier": $0.sdkIdentifier,
                "toolchainRole": jsonValue($0.toolchainRole),
                "xcodeIdentity": jsonValue($0.xcodeIdentity),
                "swiftIdentity": jsonValue($0.swiftIdentity),
                "platform": jsonValue($0.platform),
                "scheme": jsonValue($0.scheme),
                "target": jsonValue($0.target),
                "configuration": jsonValue($0.configuration),
                "destination": jsonValue($0.destination),
                "architecture": jsonValue($0.architecture),
                "deploymentTarget": jsonValue($0.deploymentTarget),
                "filesRequested": $0.filesRequested,
                "filesAnalyzed": $0.filesAnalyzed,
                "filesWithoutSDKReferences": $0.filesWithoutSDKReferences,
                "filesFailed": $0.filesFailed,
                "declarationReferences": $0.declarationReferences,
                "stableIdentityReferences": $0.stableIdentityReferences,
                "unresolvedReferences": $0.unresolvedReferences,
                "unresolvedReasons": $0.unresolvedReasons,
                "compilerExitStatus": $0.compilerExitStatus.map {
                    Int($0) as Any
                } ?? NSNull(),
                "isComplete": $0.isComplete,
                "sourceFiles": $0.sourceFiles.map {
                    [
                        "path": relativePath(
                            $0.path,
                            projectRoot: report.projectRoot
                        ),
                        "disposition": $0.disposition.rawValue,
                        "reason": jsonValue($0.reason),
                    ]
                },
            ]
        }
        let notifications: [[String: Any]] = report.failures.map {
            var notification: [String: Any] = [
                "level": "warning",
                "message": ["text": $0.message],
                "descriptor": ["id": "analysis.\($0.kind.rawValue)"],
            ]
            if let location = $0.location {
                notification["locations"] = [
                    [
                        "physicalLocation": [
                            "artifactLocation": [
                                "uri": relativePath(
                                    location.path,
                                    projectRoot: report.projectRoot
                                ),
                                "uriBaseId": "PROJECT_ROOT",
                            ],
                        ],
                    ],
                ]
            }
            return notification
        }
        let baseURI = URL(
            fileURLWithPath: report.projectRoot,
            isDirectory: true
        ).absoluteString
        let sarif: [String: Any] = [
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [
                [
                    "tool": [
                        "driver": [
                            "name": "SwiftDelta",
                            "rules": ruleDescriptors,
                            "version": SwiftDeltaVersion.current,
                        ],
                    ],
                    "properties": [
                        "analysisState": report.analysisState.rawValue,
                        "referenceResolutionCoverage": coverageProperties,
                        "sdkModuleSelections": report.sdkModuleSelections.map {
                            [
                                "toolchainRole": $0.toolchainRole,
                                "sdkIdentifier": $0.sdkIdentifier,
                                "moduleName": $0.moduleName,
                                "target": jsonValue($0.target),
                                "reason": $0.reason,
                                "sourcePaths": $0.sourcePaths.map {
                                    relativePath(
                                        $0,
                                        projectRoot: report.projectRoot
                                    )
                                },
                            ]
                        },
                    ],
                    "originalUriBaseIds": [
                        "PROJECT_ROOT": ["uri": baseURI],
                    ],
                    "invocations": [
                        [
                            "executionSuccessful":
                                report.analysisState != .blocked
                                    && report.analysisState != .incomplete,
                            "toolExecutionNotifications": notifications,
                        ],
                    ],
                    "results": results,
                ],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: sarif,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func sarifLevel(_ severity: Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .notice: "note"
        }
    }

    private static func artifactURI(_ path: String) -> String {
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path).absoluteString
        }
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private static func relativePath(
        _ path: String,
        projectRoot: String
    ) -> String {
        guard NSString(string: path).isAbsolutePath else {
            return artifactURI(path)
        }
        let root = URL(fileURLWithPath: projectRoot)
            .standardizedFileURL
            .pathComponents
        let file = URL(fileURLWithPath: path)
            .standardizedFileURL
            .pathComponents
        guard file.count >= root.count,
              Array(file.prefix(root.count)) == root
        else {
            return artifactURI(path)
        }
        let value = file.dropFirst(root.count).joined(separator: "/")
        return value.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? value
    }

    private static func jsonValue(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }
}
