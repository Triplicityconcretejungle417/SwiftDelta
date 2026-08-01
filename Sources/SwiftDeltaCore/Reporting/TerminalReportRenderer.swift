//===--- TerminalReportRenderer.swift - SwiftDelta ------------------------------------------===//
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

public enum TerminalReportRenderer {
    public static func render(
        _ report: AnalysisReport,
        failureLevel: Severity = .error
    ) -> String {
        var lines: [String] = [
            statusLabel(report, failureLevel: failureLevel),
        ]
        if report.findings.isEmpty,
           report.analysisState == .completeAndClean
        {
            lines.append("No findings matched the configured severity and confidence thresholds.")
        } else if report.findings.isEmpty {
            lines.append(
                "No qualifying findings were reported, but required analysis did not complete."
            )
        }

        for (index, finding) in report.findings.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines.append(finding.severity.rawValue.uppercased())
            if let location = finding.location {
                var value = displayPath(
                    location.path,
                    projectRoot: report.projectRoot
                )
                if let line = location.line {
                    value += ":\(line)"
                    if let column = location.column {
                        value += ":\(column)"
                    }
                }
                lines.append(value)
            } else if finding.target != nil || finding.configuration != nil {
                let target = finding.target ?? "<unknown target>"
                let configuration = finding.configuration.map { " (\($0))" } ?? ""
                lines.append("\(target)\(configuration)")
            }
            lines.append("")
            lines.append(finding.title)
            lines.append(finding.explanation)
            if let migrationMessage = finding.migrationMessage {
                lines.append("")
                lines.append("SDK/compiler migration message:")
                lines.append(migrationMessage)
            }
            lines.append("")
            lines.append("Confidence: \(finding.confidence.rawValue.capitalized)")
            lines.append("Finding: \(finding.findingID)")
            if let evidence = finding.sdkEvidence {
                lines.append("Module: \(evidence.moduleName)")
                lines.append("Platform: \(evidence.platform)")
                if let identifier = evidence.preciseIdentifier {
                    lines.append("Symbol: \(identifier)")
                }
                lines.append(
                    "Baseline: Xcode \(evidence.baseline.xcodeVersion) (\(evidence.baseline.xcodeBuild)), SDK \(evidence.baseline.sdkVersion)"
                )
                lines.append(
                    "Candidate: Xcode \(evidence.candidate.xcodeVersion) (\(evidence.candidate.xcodeBuild)), SDK \(evidence.candidate.sdkVersion)"
                )
                if let oldDeclaration = evidence.oldDeclaration {
                    lines.append("Old declaration: \(oldDeclaration)")
                }
                if let newDeclaration = evidence.newDeclaration {
                    lines.append("New declaration: \(newDeclaration)")
                }
            }
            if let referenceURL = finding.referenceURL {
                lines.append("Reference: \(referenceURL.absoluteString)")
            }
        }

        if !report.failures.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("Analysis issues:")
            for failure in report.failures {
                let path = failure.location.map {
                    "\(displayPath($0.path, projectRoot: report.projectRoot)): "
                } ?? ""
                lines.append("- \(path)\(failure.message)")
            }
        }

        if !report.referenceResolutionCoverage.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("Compiler reference coverage:")
            for coverage in report.referenceResolutionCoverage {
                let role = coverage.toolchainRole.map { "\($0) " } ?? ""
                let target = coverage.target.map { ", target \($0)" } ?? ""
                let completeness = coverage.isComplete ? "complete" : "incomplete"
                lines.append(
                    "- \(role)\(coverage.sdkIdentifier)\(target): "
                    + "\(coverage.stableIdentityReferences) stable identity reference(s), "
                    + "\(coverage.unresolvedReferences) unresolved; "
                    + "\(coverage.filesAnalyzed)/\(coverage.filesRequested) file(s) analyzed "
                    + "(\(completeness))"
                )
                for source in coverage.sourceFiles
                    where !source.disposition.isSuccessful
                {
                    let reason = source.reason.map { ": \($0)" } ?? ""
                    lines.append(
                        "  - \(displayPath(source.path, projectRoot: report.projectRoot)): "
                        + "\(source.disposition.rawValue)\(reason)"
                    )
                }
            }
        }

        if !report.sdkModuleSelections.isEmpty {
            lines.append("")
            lines.append("SDK modules selected:")
            for selection in report.sdkModuleSelections {
                let target = selection.target.map { ", target \($0)" } ?? ""
                lines.append(
                    "- \(selection.toolchainRole) \(selection.sdkIdentifier), "
                        + "\(selection.moduleName)\(target): \(selection.reason)"
                )
            }
        }

        let errorCount = report.findings.count { $0.severity == .error }
        let warningCount = report.findings.count { $0.severity == .warning }
        let noticeCount = report.findings.count { $0.severity == .notice }
        if !lines.isEmpty {
            lines.append("")
        }
        lines.append(
            "Summary: \(errorCount) error(s), \(warningCount) warning(s), \(noticeCount) notice(s), \(report.failures.count) analysis issue(s)."
        )
        return lines.joined(separator: "\n") + "\n"
    }

    private static func statusLabel(
        _ report: AnalysisReport,
        failureLevel: Severity
    ) -> String {
        switch report.analysisState {
        case .completeAndClean: "PASS"
        case .completeWithFindings:
            report.findings.contains {
                $0.severity.isAtLeast(failureLevel)
            } ? "FAIL" : "PASS"
        case .incomplete: "INCOMPLETE"
        case .blocked: "BLOCKED"
        }
    }

    private static func displayPath(
        _ path: String,
        projectRoot: String
    ) -> String {
        guard NSString(string: path).isAbsolutePath else {
            return path
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
            return path
        }
        return file.dropFirst(root.count).joined(separator: "/")
    }
}
