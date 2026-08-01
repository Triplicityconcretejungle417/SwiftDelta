//===--- CompilerFixItRepairBuilder.swift - SwiftDelta ------------------------------------------===//
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

public enum CompilerFixItRepairBuilder {
    public static func build(
        fixIts: [StructuredDiagnosticFixIt],
        projectRoot: URL,
        candidateIdentity: SDKInstallationIdentity? = nil,
        analysisFindings: [Finding] = []
    ) -> ([ProposedRepair], [AnalysisFailure]) {
        var repairs: [ProposedRepair] = []
        var failures: [AnalysisFailure] = []

        for fixIt in fixIts {
            do {
                let document = try RepairSourceDocument(
                    root: projectRoot,
                    file: URL(fileURLWithPath: fixIt.filePath)
                )
                let original = try document.text(in: fixIt.sourceRange)
                let mechanicalSafety = RepairSafetyClassifier.classify(
                    original: original,
                    replacement: fixIt.replacementText
                )
                let safety = fixIt.compilerContext?.isTargetAware == true
                    ? mechanicalSafety
                    : .reviewRequired
                let evidence: RepairEvidenceSource = document.language == .swift
                    ? .swiftCompilerFixIt
                    : .clangCompilerFixIt
                let findingIdentifier = associatedFinding(
                    with: fixIt,
                    document: document,
                    findings: analysisFindings,
                    projectRoot: projectRoot
                )?.findingID ?? RepairFingerprint.identifier([
                    "compiler-fixit",
                    document.relativePath,
                    String(fixIt.sourceRange.start.utf8Offset),
                    String(fixIt.sourceRange.end.utf8Offset),
                    fixIt.diagnosticText,
                ])
                let repairIdentifier = RepairFingerprint.identifier([
                    evidence.rawValue,
                    document.relativePath,
                    String(fixIt.sourceRange.start.utf8Offset),
                    String(fixIt.sourceRange.end.utf8Offset),
                    original,
                    fixIt.replacementText,
                    document.fingerprint.digest,
                ])
                repairs.append(
                    ProposedRepair(
                        repairIdentifier: repairIdentifier,
                        relatedFindingIdentifier: findingIdentifier,
                        evidenceSource: evidence,
                        language: document.language,
                        filePath: document.relativePath,
                        sourceRange: fixIt.sourceRange,
                        originalText: original,
                        replacementText: fixIt.replacementText,
                        fileFingerprint: document.fingerprint,
                        confidence: .high,
                        safety: safety,
                        explanation:
                            "The candidate compiler supplied this exact source edit"
                            + (fixIt.diagnosticText.isEmpty
                                ? "."
                                : " for: \(fixIt.diagnosticText)"),
                        verificationRequirement: .candidateBuild,
                        toolchains: candidateIdentity.map {
                            RepairToolchainEvidence(candidate: $0)
                        },
                        compilerContext: fixIt.compilerContext
                    )
                )
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message: error.localizedDescription,
                        location: SourceLocation(path: fixIt.filePath)
                    )
                )
            }
        }
        return (repairs, failures)
    }

    private static func associatedFinding(
        with fixIt: StructuredDiagnosticFixIt,
        document: RepairSourceDocument,
        findings: [Finding],
        projectRoot: URL
    ) -> Finding? {
        let pathMatches = findings.filter { finding in
            guard finding.origin == .compiler,
                  let location = finding.location,
                  canonical(location.path, root: projectRoot)
                    == canonical(fixIt.filePath, root: projectRoot),
                  location.line.map({
                      fixIt.sourceRange.start.line <= $0
                          && $0 <= fixIt.sourceRange.end.line
                  }) ?? true,
                  finding.target == nil
                    || fixIt.compilerContext?.target == nil
                    || finding.target == fixIt.compilerContext?.target
            else {
                return false
            }
            return true
        }
        let exactMessage = pathMatches.filter {
            normalizedDiagnosticText($0.explanation)
                == normalizedDiagnosticText(fixIt.diagnosticText)
        }
        if exactMessage.count == 1 {
            return exactMessage[0]
        }
        _ = document
        return nil
    }

    private static func canonical(_ path: String, root: URL) -> String {
        let url = NSString(string: path).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedDiagnosticText(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum RepairSafetyClassifier {
    private static let forbiddenIdentifiers: Set<String> = [
        "async", "await", "borrowing", "catch", "consume", "consuming",
        "defer", "do", "else", "inout", "isolated", "nonisolated",
        "sending", "throws", "try", "weak", "unowned",
    ]

    static func classify(
        original: String,
        replacement: String
    ) -> RepairSafetyClassification {
        guard !original.contains(where: \.isNewline),
              !replacement.contains(where: \.isNewline),
              !original.contains("\""),
              !replacement.contains("\""),
              !original.contains("#"),
              !replacement.contains("#")
        else {
            return .reviewRequired
        }
        if isIdentifier(original) && isIdentifier(replacement) {
            guard !forbiddenIdentifiers.contains(original),
                  !forbiddenIdentifiers.contains(replacement)
            else {
                return .reviewRequired
            }
            return .safe
        }
        let allowedPunctuation = CharacterSet(
            charactersIn: " \t;,:.()[]?"
        )
        guard original.unicodeScalars.allSatisfy(allowedPunctuation.contains),
              replacement.unicodeScalars.allSatisfy(allowedPunctuation.contains)
        else {
            return .reviewRequired
        }
        return .safe
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil
    }
}
