//===--- TUIScreenRenderer+Findings.swift - SwiftDelta ------------------------------------------===//
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

private enum ResultDisplayItem {
    case control(selectableIndex: Int, row: TUIRow)
    case group(name: String, count: Int)
    case finding(selectableIndex: Int, value: Finding)
}

extension TUIScreenRenderer {
    func renderRepairs(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        let controls = TUIContentRows.rows(for: state)
        let candidates = state.displayedRepairCandidates
        let count = controls.count + candidates.count
        let selected = min(max(0, state.contentIndex), max(0, count - 1))
        let symbols = TerminalSymbols(capabilities: capabilities)
        let hasPlanningProblems = !(state.repairPlan?.conflicts.isEmpty ?? true)
            || !(state.repairPlan?.planningFailures.isEmpty ?? true)
        canvas.write(
            state.repairPlan.map { plan in
                if state.repairCoverage != nil {
                    let funnel = state.repairFunnel
                    return "\(hasPlanningProblems ? symbols.warning : symbols.safeRepair) "
                        + "\(funnel.findings) Findings → "
                        + "\(funnel.actionable) Actionable → "
                        + "\(funnel.proposed) Proposed → "
                        + "\(funnel.validated) Validated → "
                        + "\(funnel.ready) Ready → "
                        + "\(funnel.selected) Selected"
                }
                return "\(hasPlanningProblems ? symbols.warning : symbols.safeRepair) "
                    + "\(plan.repairs.count) proposal(s) · "
                    + "\(plan.conflicts.count) conflict(s) · "
                    + "\(plan.planningFailures.count) planning issue(s)"
            } ?? "Generate a preview to inspect eligible repairs.",
            row: row,
            column: column + 1,
            style: theme.style(
                state.repairPlan == nil
                    ? .secondary : (hasPlanningProblems ? .warning : .success),
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 2
        )
        let showDetailPane = width >= 112
        let listWidth = showDetailPane
            ? max(42, width * 2 / 5) : width
        let listHeight = max(1, height - 2)
        let start = min(
            max(0, selected - listHeight / 2),
            max(0, count - listHeight)
        )
        for visible in 0..<listHeight {
            let index = start + visible
            guard index < count else { break }
            let selectedRow = index == selected
            if controls.indices.contains(index) {
                renderControlRow(
                    controls[index],
                    selected: selectedRow,
                    row: row + 2 + visible,
                    column: column,
                    width: listWidth,
                    on: &canvas
                )
                continue
            }
            let candidate = candidates[index - controls.count]
            let lifecycle = state.repairLifecycle(for: candidate)
            let style = selectedRow
                ? theme.selectionStyle(
                    candidateSelectionRole(lifecycle),
                    capabilities: capabilities
                )
                : candidateStyle(lifecycle)
            if selectedRow {
                canvas.fill(
                    row: row + 2 + visible,
                    from: column,
                    width: listWidth,
                    style: style
                )
            }
            let selectedForApply =
                !state.effectiveRepairIdentifiers(for: candidate).isEmpty
                && Set(state.effectiveRepairIdentifiers(for: candidate)).isSubset(
                    of: state.selectedRepairIDs
                )
            let selectedMark = selectedForApply
                ? "[\(symbols.success)]" : "[ ]"
            let location = candidate.location.map {
                let line = $0.line.map { ":\($0)" } ?? ""
                return "\(URL(fileURLWithPath: $0.path).lastPathComponent)\(line)"
            } ?? "No source"
            let confidence = candidate.confidence.map {
                " · \($0.rawValue) confidence"
            } ?? ""
            let conflictIdentifiers = Set(
                state.repairPlan?.conflicts.flatMap(
                    \.repairIdentifiers
                ) ?? []
            )
            let isActualConflict = !conflictIdentifiers.isDisjoint(
                with: candidate.repairIdentifiers
            )
            let sourceAndStatus: String
            switch lifecycle {
            case .planning:
                sourceAndStatus =
                    "\(symbols.incomplete) Planning · \(candidate.repairSource)"
            case .validating:
                sourceAndStatus =
                    "\(symbols.incomplete) Validating · \(candidate.repairSource)"
            case .ready:
                sourceAndStatus =
                    "\(symbols.safeRepair) Ready · \(candidate.repairSource)"
            case .needsReview:
                sourceAndStatus =
                    "\(symbols.reviewRepair) Needs Review · \(candidate.repairSource)"
            case .noSafeFix:
                sourceAndStatus =
                    "\(symbols.incomplete) No Safe Fix · \(candidate.repairSource)"
            case .failed:
                sourceAndStatus =
                    isActualConflict
                    ? "\(symbols.conflict) conflict · "
                        + "\(candidate.repairSource) · Failed"
                    : "\(symbols.error) Failed · \(candidate.repairSource)"
            case .stale:
                sourceAndStatus =
                    "\(symbols.warning) Stale · \(candidate.repairSource)"
            }
            canvas.write(
                "\(selectedMark) \(sourceAndStatus) · "
                    + "\(location) · "
                    + "\(candidate.symbol ?? candidate.title) · "
                    + "\(candidate.summary)"
                    + confidence,
                row: row + 2 + visible,
                column: column + 1,
                style: style,
                maximumWidth: listWidth - 2
            )
        }
        if showDetailPane,
           selected >= controls.count,
           state.selectedRepairCandidate != nil
        {
            renderPaneDivider(
                focused: state.focus == .details,
                row: row + 2,
                column: column + listWidth,
                height: height - 2,
                on: &canvas
            )
            renderRepairDetail(
                state,
                row: row + 2,
                column: column + listWidth + 2,
                width: width - listWidth - 3,
                height: height - 2,
                on: &canvas
            )
        }
    }

    private func candidateStyle(
        _ status: TUIRepairLifecycle
    ) -> TerminalStyle {
        let role: TerminalStyleRole = switch status {
        case .ready: .success
        case .planning, .validating, .needsReview, .stale: .warning
        case .failed: .error
        case .noSafeFix: .secondary
        }
        return theme.style(
            role,
            highContrast: capabilities.highContrast
        )
    }

    private func candidateSelectionRole(
        _ status: TUIRepairLifecycle
    ) -> TerminalSelectionRole {
        if status == .failed {
            return .destructive
        }
        return status == .ready ? .normal : .warning
    }

    private func candidateStatusLabel(
        _ status: TUIRepairLifecycle
    ) -> String {
        status.rawValue
    }

    private func repairSourceLabel(_ repair: ProposedRepair) -> String {
        switch repair.evidenceSource {
        case .swiftCompilerFixIt, .clangCompilerFixIt:
            return "Compiler Fix-it"
        case .sdkRename:
            return "SDK rename"
        case .mechanicalSignatureChange:
            return "Mechanical"
        case .foundationModels:
            return "Apple Foundation Models"
        }
    }

    func renderFindings(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        let controls = TUIContentRows.resultControls(for: state)
        let findings = state.findings
        let stateLabel: String
        switch state.report?.analysisState {
        case .completeAndClean: stateLabel = "PASS"
        case .completeWithFindings:
            let failed = state.report?.findings.contains {
                $0.severity.isAtLeast(state.settings.workflow.failureLevel)
            } ?? false
            stateLabel = failed ? "FAIL" : "PASS"
        case .incomplete: stateLabel = "INCOMPLETE"
        case .blocked: stateLabel = "BLOCKED"
        case nil: stateLabel = "NOT RUN"
        }
        let summary = "\(stateLabel) · \(findings.count) shown"
            + (state.search.isEmpty ? "" : " · search “\(state.search)”")
        let allFindings = state.report?.findings ?? []
        let errors = allFindings.count { $0.severity == .error }
        let warnings = allFindings.count { $0.severity == .warning }
        let notices = allFindings.count { $0.severity == .notice }
        let symbols = TerminalSymbols(capabilities: capabilities)
        let outcomeSymbol: String
        let outcomeRole: TerminalStyleRole
        switch state.report?.analysisState {
        case .completeAndClean:
            outcomeSymbol = symbols.success
            outcomeRole = .success
        case .completeWithFindings:
            if stateLabel == "FAIL" {
                outcomeSymbol = symbols.error
                outcomeRole = .error
            } else {
                outcomeSymbol = symbols.success
                outcomeRole = .success
            }
        case .incomplete:
            outcomeSymbol = symbols.incomplete
            outcomeRole = .warning
        case .blocked:
            outcomeSymbol = symbols.error
            outcomeRole = .error
        case nil:
            outcomeSymbol = symbols.incomplete
            outcomeRole = .secondary
        }
        canvas.write(
            "\(outcomeSymbol) \(summary) · \(errors) error · "
                + "\(warnings) warning · \(notices) notice",
            row: row,
            column: column + 1,
            style: theme.style(
                outcomeRole,
                highContrast: capabilities.highContrast
            ),
            maximumWidth: width - 2
        )
        if let report = state.report {
            let requested = report.referenceResolutionCoverage.reduce(0) {
                $0 + $1.filesRequested
            }
            let analyzed = report.referenceResolutionCoverage.reduce(0) {
                $0 + $1.filesAnalyzed
            }
            let failed = report.referenceResolutionCoverage.reduce(0) {
                $0 + $1.filesFailed
            }
            let records = report.referenceResolutionCoverage.flatMap(\.sourceFiles)
            let excluded = records.count {
                $0.disposition == .excludedFromTarget
            }
            let generated = records.count {
                $0.disposition == .generated
            }
            let missing = records.count {
                $0.disposition == .missingCompilerOutput
            }
            let zeroReferences = report.referenceResolutionCoverage.reduce(0) {
                $0 + $1.filesWithoutSDKReferences
            }
            canvas.write(
                "\(symbols.file) Coverage \(analyzed)/\(requested) analyzed · "
                    + "\(failed) failed · "
                    + "\(zeroReferences) no SDK refs · \(excluded) excluded · "
                    + "\(generated) generated · \(missing) missing · "
                    + "\(report.failures.count) issue(s)",
                row: row + 1,
                column: column + 1,
                style: theme.style(
                    report.analysisState == .incomplete
                        || report.analysisState == .blocked
                        ? .warning : .secondary,
                    highContrast: capabilities.highContrast
                ),
                maximumWidth: width - 2
            )
        }
        let showDetailPane = width >= 112
        let listWidth = showDetailPane
            ? max(40, width * 2 / 5) : width
        let listHeight = height - 3
        let combinedCount = controls.count
            + (state.resultsView == .findings ? findings.count : 0)
        let selected = min(max(0, state.contentIndex), max(0, combinedCount - 1))
        var displayItems = controls.enumerated().map {
            ResultDisplayItem.control(selectableIndex: $0.offset, row: $0.element)
        }
        if state.resultsView == .findings {
            var previousGroup: String?
            for (index, finding) in findings.enumerated() {
                let group = state.groupKey(for: finding)
                    .replacingOccurrences(
                        of: #"^\d-"#,
                        with: "",
                        options: .regularExpression
                    )
                if group != previousGroup {
                    displayItems.append(
                        .group(
                            name: group,
                            count: groupCount(group, state: state)
                        )
                    )
                    previousGroup = group
                }
                displayItems.append(
                    .finding(
                        selectableIndex: controls.count + index,
                        value: finding
                    )
                )
            }
        }
        let selectedDisplay = displayItems.firstIndex {
            switch $0 {
            case let .control(index, _), let .finding(index, _):
                index == selected
            case .group:
                false
            }
        } ?? 0
        let start = min(
            max(0, selectedDisplay - listHeight / 2),
            max(0, displayItems.count - listHeight)
        )
        for visible in 0..<listHeight {
            let displayIndex = start + visible
            guard displayItems.indices.contains(displayIndex) else { break }
            let item = displayItems[displayIndex]
            let selectableIndex: Int? = switch item {
            case let .control(index, _), let .finding(index, _): index
            case .group: nil
            }
            switch item {
            case let .control(_, control):
                renderControlRow(
                    control,
                    selected: selectableIndex == selected,
                    row: row + 3 + visible,
                    column: column,
                    width: listWidth,
                    on: &canvas
                )
                continue
            case let .group(name, count):
                canvas.write(
                    "\(name) \(capabilities.symbolMode == .ascii ? "--" : "—") \(count)",
                    row: row + 3 + visible,
                    column: column + 1,
                    style: theme.style(
                        .accent,
                        highContrast: capabilities.highContrast
                    ),
                    maximumWidth: listWidth - 2
                )
            case let .finding(_, finding):
                let selectedRow = selectableIndex == selected
                let style = selectedRow
                    ? theme.selectionStyle(
                        selectionRole(for: finding.severity),
                        capabilities: capabilities
                    )
                    : severityStyle(finding.severity)
                if selectedRow {
                    canvas.fill(
                        row: row + 3 + visible,
                        from: column,
                        width: listWidth,
                        style: style
                    )
                }
                canvas.write(
                    findingListSummary(finding),
                    row: row + 3 + visible,
                    column: column + 1,
                    style: style,
                    maximumWidth: listWidth - 2
                )
            }
        }
        if state.resultsView == .coverage {
            renderCoverage(
                state,
                row: row + 3,
                column: column,
                width: width,
                height: listHeight,
                on: &canvas
            )
        } else if state.resultsView == .failures {
            renderFailures(
                state,
                row: row + 3,
                column: column,
                width: width,
                height: listHeight,
                on: &canvas
            )
        } else if showDetailPane,
                  selected >= controls.count,
                  let finding = state.selectedFinding
        {
            renderPaneDivider(
                focused: state.focus == .details,
                row: row + 3,
                column: column + listWidth,
                height: height - 3,
                on: &canvas
            )
            renderFindingDetail(
                finding,
                row: row + 3,
                column: column + listWidth + 2,
                width: width - listWidth - 3,
                    height: height - 3,
                    scroll: state.detailScroll,
                    coverage: state.report?.referenceResolutionCoverage ?? [],
                    repairCandidates: state.displayedRepairCandidates,
                    projectRoot: state.report?.projectRoot,
                    on: &canvas
            )
        }
    }

    private func findingListSummary(_ finding: Finding) -> String {
        let symbols = TerminalSymbols(capabilities: capabilities)
        let severity = switch finding.severity {
        case .error: symbols.error
        case .warning: symbols.warning
        case .notice: symbols.notice
        }
        let location = finding.location.map {
            let line = $0.line.map { ":\($0)" } ?? ""
            return "\($0.path)\(line)"
        } ?? "No source location"
        let repair = finding.automaticRemediationSupported
            ? " · \(symbols.safeRepair) repair" : ""
        return "\(severity) \(finding.title) · \(location) · "
            + "\(finding.category.rawValue) · "
            + "\(finding.confidence.rawValue) confidence\(repair)"
    }

    private func selectionRole(
        for severity: Severity
    ) -> TerminalSelectionRole {
        switch severity {
        case .error: .destructive
        case .warning: .warning
        case .notice: .normal
        }
    }

    private func renderPaneDivider(
        focused: Bool,
        row: Int,
        column: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        let glyph = capabilities.symbolMode == .unicode ? "│" : "|"
        let style = theme.style(
            focused ? .accent : .secondary,
            highContrast: capabilities.highContrast
        )
        for offset in 0..<max(0, height) {
            canvas.write(
                glyph,
                row: row + offset,
                column: column,
                style: style
            )
        }
    }

    private func groupCount(_ name: String, state: TUIState) -> Int {
        state.findingGroups().first { $0.name == name }?.count ?? 0
    }

    private func renderCoverage(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        guard let report = state.report else { return }
        let symbols = TerminalSymbols(capabilities: capabilities)
        var lines: [String] = []
        var headings = Set<String>()
        var roles: [String: TerminalStyleRole] = [:]
        for coverage in report.referenceResolutionCoverage {
            let heading = "\(symbols.file) \(coverage.toolchainRole ?? "toolchain") · "
                + "\(coverage.target ?? "target") · \(coverage.sdkIdentifier)"
            lines.append(heading)
            headings.insert(heading)
            lines.append(
                "  \(coverage.filesAnalyzed)/\(coverage.filesRequested) analyzed · "
                    + "\(coverage.filesWithoutSDKReferences) without SDK references · "
                    + "\(coverage.filesFailed) failed"
            )
            let completeness = "  "
                + "\(coverage.isComplete ? symbols.success : symbols.incomplete) "
                + "\(coverage.stableIdentityReferences) stable · "
                + "\(coverage.unresolvedReferences) unresolved · "
                + "\(coverage.isComplete ? "complete" : "incomplete")"
            lines.append(completeness)
            roles[completeness] = coverage.isComplete ? .success : .warning
            lines.append(
                "  \(coverage.platform ?? "platform") · "
                    + "\(coverage.destination ?? "destination") · deployment "
                    + "\(coverage.deploymentTarget ?? "unknown") · "
                    + "\(coverage.configuration ?? "configuration")"
            )
            for record in coverage.sourceFiles where !record.disposition.isSuccessful {
                let failure = "  \(symbols.warning) \(record.disposition.rawValue): "
                    + "\(record.path)"
                    + (record.reason.map { " — \($0)" } ?? "")
                lines.append(failure)
                roles[failure] = .warning
            }
            lines.append("")
        }
        drawWrapped(
            lines.isEmpty ? ["No reference coverage was recorded."] : lines,
            row: row,
            column: column,
            width: width,
            height: height,
            scroll: state.detailScroll,
            on: &canvas,
            headingLines: headings,
            semanticRoles: roles
        )
    }

    private func renderFailures(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        let symbols = TerminalSymbols(capabilities: capabilities)
        let lines: [String] = state.report?.failures.map { failure in
            let path = failure.location.map { " · \($0.path)" } ?? ""
            return "\(symbols.warning) \(failure.kind.rawValue)\(path): "
                + failure.message
        } ?? []
        var roles: [String: TerminalStyleRole] = [:]
        for line in lines {
            roles[line] = .warning
        }
        drawWrapped(
            lines.isEmpty ? ["No analysis issues were recorded."] : lines,
            row: row,
            column: column,
            width: width,
            height: height,
            scroll: state.detailScroll,
            on: &canvas,
            semanticRoles: roles
        )
    }

    func renderFindingDetail(
        _ finding: Finding,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        scroll: Int,
        coverage: [ReferenceResolutionCoverage] = [],
        repairCandidates: [RepairCandidatePresentation] = [],
        projectRoot: String? = nil,
        on canvas: inout TerminalCanvas
    ) {
        let symbols = TerminalSymbols(capabilities: capabilities)
        let status = "\(severitySymbol(finding.severity, symbols: symbols)) "
            + "\(finding.severity.rawValue) · \(finding.category.rawValue) · "
            + "\(finding.confidence.rawValue) confidence · \(finding.origin.rawValue)"
        let repairability = finding.automaticRemediationSupported
            ? "\(symbols.safeRepair) Repair evidence available"
            : "\(symbols.reviewRepair) No automatic repair"
        var lines = [
            finding.title,
            status,
            "",
            "Summary",
            "  \(finding.explanation)",
            "Finding ID: \(finding.findingID)",
            repairability,
        ]
        var headings: Set<String> = [finding.title, "Summary"]
        var roles: [String: TerminalStyleRole] = [
            status: finding.severity == .error
                ? .error : (finding.severity == .warning ? .warning : .secondary),
            repairability: finding.automaticRemediationSupported
                ? .success : .secondary,
        ]
        var sourceLines: [String] = []
        if let target = finding.target {
            sourceLines.append("Target: \(target)")
        }
        if let configuration = finding.configuration {
            sourceLines.append("Configuration: \(configuration)")
        }
        if let location = finding.location {
            var source = "\(symbols.file) \(location.path)"
            if let line = location.line {
                source += ":\(line)"
            }
            if let column = location.column {
                source += ":\(column)"
            }
            sourceLines.append(source)
        }
        if !sourceLines.isEmpty {
            lines.append("")
            lines.append("Source")
            headings.insert("Source")
            lines.append(contentsOf: sourceLines.map { "  \($0)" })
        }
        if let context = sourceContext(
            for: finding,
            projectRoot: projectRoot
        ) {
            lines.append("")
            lines.append("Source context")
            headings.insert("Source context")
            for line in context.lines {
                lines.append(line)
            }
            roles[context.highlightedLine] = .accent
        }
        if let evidence = finding.sdkEvidence {
            lines.append("")
            let sdkHeading = "\(symbols.sdk) SDK evidence"
            lines.append(sdkHeading)
            headings.insert(sdkHeading)
            lines.append("  Module: \(evidence.moduleName)")
            lines.append("  Platform: \(evidence.platform)")
            lines.append(
                "  Baseline: Xcode \(evidence.baseline.xcodeVersion) "
                    + "(\(evidence.baseline.xcodeBuild)), "
                    + "\(evidence.baseline.sdkIdentifier) "
                    + "\(evidence.baseline.sdkVersion)"
            )
            lines.append(
                "  Candidate: Xcode \(evidence.candidate.xcodeVersion) "
                    + "(\(evidence.candidate.xcodeBuild)), "
                    + "\(evidence.candidate.sdkIdentifier) "
                    + "\(evidence.candidate.sdkVersion)"
            )
            lines.append(
                "  Symbol: \(evidence.preciseIdentifier ?? "identity unavailable")"
            )
            lines.append(
                "  Name: \(evidence.fullyQualifiedName)"
            )
            lines.append(
                "  Resolution: \(evidence.resolutionMethod.rawValue)"
            )
            lines.append(
                "  Change: \(evidence.observedChange)"
            )
            if let old = evidence.oldDeclaration {
                lines.append("  Baseline declaration: \(old)")
            }
            if let new = evidence.newDeclaration {
                lines.append("  Candidate declaration: \(new)")
            }
            if !evidence.oldAvailability.isEmpty
                || !evidence.newAvailability.isEmpty
            {
                lines.append(
                    "  Baseline availability: "
                        + availabilitySummary(evidence.oldAvailability)
                )
                lines.append(
                    "  Candidate availability: "
                        + availabilitySummary(evidence.newAvailability)
                )
            }
        }
        let matchingCoverage = coverage.filter {
            finding.target == nil || $0.target == finding.target
        }
        for value in matchingCoverage {
            lines.append("")
            let coverageHeading = "\(symbols.file) "
                + "\(value.toolchainRole ?? "Toolchain") coverage"
            lines.append(coverageHeading)
            headings.insert(coverageHeading)
            let coverageStatus = "  "
                + "\(value.isComplete ? symbols.success : symbols.incomplete) "
                + "\(value.filesAnalyzed)/\(value.filesRequested) files"
                + (value.isComplete ? " complete" : " incomplete")
            lines.append(coverageStatus)
            roles[coverageStatus] = value.isComplete ? .success : .warning
            lines.append(
                "  \(value.configuration ?? "configuration") · "
                    + "\(value.destination ?? "destination") · deployment "
                    + "\(value.deploymentTarget ?? "unknown")"
            )
        }
        if let migration = finding.migrationMessage {
            lines.append("")
            let compilerHeading = "\(symbols.compiler) Compiler or SDK message"
            lines.append(compilerHeading)
            headings.insert(compilerHeading)
            lines.append("  \(migration)")
        }
        let matchingRepairs = repairCandidates.filter {
            $0.findingStableKey == finding.stableKey
                || $0.findingIdentifier == finding.findingID
        }
        lines.append("")
        lines.append("Repair")
        headings.insert("Repair")
        if matchingRepairs.isEmpty {
            lines.append("  No repair preview has been generated for this finding.")
            lines.append("  Next: open Repair to evaluate exact source evidence.")
        } else {
            let ready = matchingRepairs.count { $0.status == .ready }
            let review = matchingRepairs.count {
                $0.status == .needsValidation
                    || $0.status == .reviewRequired
            }
            lines.append(
                "  \(ready) ready · \(review) requiring review or validation · "
                    + "\(matchingRepairs.count) total"
            )
            lines.append("  Next: open Repair to inspect the diff and evidence.")
        }
        drawWrapped(
            lines,
            row: row,
            column: column,
            width: width,
            height: height,
            scroll: scroll,
            on: &canvas,
            headingLines: headings,
            semanticRoles: roles
        )
    }

    private func sourceContext(
        for finding: Finding,
        projectRoot: String?
    ) -> (lines: [String], highlightedLine: String)? {
        guard let projectRoot,
              let location = finding.location,
              let selectedLine = location.line,
              selectedLine > 0
        else {
            return nil
        }
        let root = URL(fileURLWithPath: projectRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let source = location.path.hasPrefix("/")
            ? URL(fileURLWithPath: location.path)
            : root.appendingPathComponent(location.path)
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path
                || resolved.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: resolved),
              data.count <= 2_000_000,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let sourceLines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard sourceLines.indices.contains(selectedLine - 1) else {
            return nil
        }
        let start = max(1, selectedLine - 2)
        let end = min(sourceLines.count, selectedLine + 2)
        var highlighted = ""
        let lines = (start...end).map { lineNumber in
            let marker = lineNumber == selectedLine ? ">" : " "
            let number = String(lineNumber)
            let padding = String(
                repeating: " ",
                count: max(0, 4 - number.count)
            )
            let value = "\(marker) \(padding)\(number) │ "
                + sourceLines[lineNumber - 1]
            if lineNumber == selectedLine {
                highlighted = value
            }
            return value
        }
        return (lines, highlighted)
    }

    private func availabilitySummary(
        _ values: [SDKAvailability]
    ) -> String {
        guard !values.isEmpty else { return "none recorded" }
        return values.map { value in
            var parts = [value.domain]
            if let introduced = value.introduced {
                parts.append("introduced \(introduced)")
            }
            if let deprecated = value.deprecated {
                parts.append("deprecated \(deprecated)")
            }
            if let obsoleted = value.obsoleted {
                parts.append("obsoleted \(obsoleted)")
            }
            if value.isUnconditionallyUnavailable {
                parts.append("unavailable")
            }
            return parts.joined(separator: " · ")
        }.joined(separator: "; ")
    }

    func renderRepairDetail(
        _ state: TUIState,
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        on canvas: inout TerminalCanvas
    ) {
        guard let candidate = state.selectedRepairCandidate else { return }
        let effectiveIdentifiers = state.effectiveRepairIdentifiers(
            for: candidate
        )
        let repairs = state.repairPlan?.repairs.filter {
            effectiveIdentifiers.contains($0.repairIdentifier)
        } ?? []
        let selected =
            !effectiveIdentifiers.isEmpty
            && Set(effectiveIdentifiers).isSubset(
                of: state.selectedRepairIDs
            )
        let draft = state.draft(for: candidate)
        let symbols = TerminalSymbols(capabilities: capabilities)
        let status = state.repairLifecycle(for: candidate)
        let applicability = candidateStatusLabel(status)
            + (status == .ready
                && state.candidateNeedsSemanticReview(candidate)
                ? " · Needs Semantic Review" : "")
        let location = candidate.location.map {
            let line = $0.line.map { ":\($0)" } ?? ""
            let column = $0.column.map { ":\($0)" } ?? ""
            return "\($0.path)\(line)\(column)"
        } ?? "No exact source location"
        let action: String
        switch status {
        case .planning:
            action = "Planning is collecting structured repair evidence."
        case .validating:
            action = "Validation is running in an isolated project copy."
        case .ready:
            action = selected
                ? "[ Select ] Space deselects · [ Validate Again ] V reruns validation."
                : "[ Select ] Space selects · [ Validate Again ] V reruns validation."
        case .needsReview, .failed:
            action = draft == nil
                ? "[ Validate Again ] V reruns isolated validation."
                : "[ Edit ] E changes the retained draft · "
                    + "[ Validate Again ] V reruns isolated validation."
        case .noSafeFix:
            action =
                "No source edit is available. Review the finding and evidence."
        case .stale:
            action = "Generate a new preview; the source fingerprint changed."
        }
        var lines = [
            candidate.title,
            "\(selected ? "[\(symbols.success)]" : "[ ]") \(applicability)"
                + (candidate.confidence.map {
                    " · \($0.rawValue) confidence"
                } ?? ""),
            "",
            "Change",
            "  \(symbols.file) \(location)",
            "  Symbol: \(candidate.symbol ?? "unresolved")",
            "  Finding: \(candidate.findingIdentifier)",
            "  Source: \(candidate.repairSource)",
            "  Summary: \(candidate.summary)",
            "",
            "Diff",
        ]
        if candidate.repairSource == "Apple Foundation Models" {
            lines.insert(
                "  Apple Foundation Models · On-device · review required",
                at: 8
            )
        }
        lines.append(
            contentsOf: TUIRepairDiff.lines(
                for: candidate,
                width: width,
                ascii: capabilities.symbolMode == .ascii,
                projectRoot: state.settings.workflow.projectRoot
            )
        )
        lines.append(contentsOf: [
            "",
            "Explanation",
            "  \(candidate.explanation)",
        ])
        var headings: Set<String> = [
            candidate.title,
            "Change",
            "Diff",
            "Explanation",
        ]
        let statusLine = lines[1]
        let statusRole: TerminalStyleRole = switch status {
        case .ready: .success
        case .planning, .validating, .needsReview, .stale: .warning
        case .failed: .error
        case .noSafeFix: .secondary
        }
        let roles: [String: TerminalStyleRole] = [
            statusLine: statusRole,
        ]
        if !candidate.evidence.isEmpty {
            lines.append("")
            lines.append("\(symbols.sdk) Evidence")
            headings.insert("\(symbols.sdk) Evidence")
            lines.append(contentsOf: candidate.evidence.map { "  \($0)" })
        }
        if candidate.repairSource == "Apple Foundation Models" {
            lines.append("")
            lines.append("Apple Foundation Models")
            headings.insert("Apple Foundation Models")
            if let repair = repairs.first {
                lines.append("  Execution: \(repair.execution ?? "On-device")")
                lines.append(
                    "  Host model generation: "
                        + "\(repair.hostModelGeneration ?? "unknown")"
                )
                lines.append(
                    "  Reasoning level: "
                        + "\(repair.reasoningLevel ?? "unsupported")"
                )
            } else {
                lines.append("  Execution: On-device")
            }
            lines.append("  Review required: yes")
            lines.append(
                "  Generated by Apple Foundation Models. "
                    + "Review and build verification are required."
            )
        }
        if let draft {
            lines.append("")
            lines.append("Draft identity")
            headings.insert("Draft identity")
            lines.append("  \(draft.draftIdentifier)")
            lines.append(
                "  Host model: \(draft.hostModelGeneration) · "
                    + "\(draft.reasoningLevel) reasoning"
            )
            if !draft.initialIssues.isEmpty {
                lines.append("")
                lines.append("\(symbols.warning) Staged validation issues")
                headings.insert(
                    "\(symbols.warning) Staged validation issues"
                )
                lines.append(contentsOf: draft.initialIssues.map {
                    "  \($0.stage.rawValue): \($0.message)"
                })
            }
        }
        if !candidate.risks.isEmpty {
            lines.append("")
            lines.append("\(symbols.warning) Risks and limitations")
            headings.insert("\(symbols.warning) Risks and limitations")
            lines.append(contentsOf: candidate.risks.map { "  \($0)" })
        }
        if let repair = repairs.first {
            lines.append("")
            lines.append("\(symbols.compiler) Verification context")
            headings.insert("\(symbols.compiler) Verification context")
            if let context = repair.compilerContext {
                lines.append("  Target: \(context.target ?? "unknown")")
                lines.append("  Module: \(context.moduleName ?? "unknown")")
                lines.append("  SDK: \(context.sdkIdentifier)")
                lines.append(
                    "  Diagnostic: \(context.diagnosticIdentity)"
                )
            }
            if let baseline = repair.toolchains?.baseline {
                lines.append(
                    "  Baseline: Xcode \(baseline.xcodeVersion) "
                        + "(\(baseline.xcodeBuild)) · \(baseline.sdkIdentifier) "
                        + "\(baseline.sdkVersion)"
                )
            }
            if let candidateIdentity = repair.toolchains?.candidate {
                lines.append(
                    "  Candidate: Xcode \(candidateIdentity.xcodeVersion) "
                        + "(\(candidateIdentity.xcodeBuild)) · "
                        + "\(candidateIdentity.sdkIdentifier) "
                        + "\(candidateIdentity.sdkVersion)"
                )
            }
        }
        if let failure = state.repairValidationMessages[
            candidate.candidateIdentifier
        ] {
            lines.append("")
            lines.append("\(symbols.error) Validation failed")
            headings.insert("\(symbols.error) Validation failed")
            lines.append("  \(failure)")
        } else if let skipped = state.repairValidationSkippedMessages[
            candidate.candidateIdentifier
        ] {
            lines.append("")
            lines.append("\(symbols.notice) Automatic validation")
            headings.insert("\(symbols.notice) Automatic validation")
            lines.append("  \(skipped)")
        } else if let success = state.repairValidationSuccessMessages[
            candidate.candidateIdentifier
        ] {
            lines.append("")
            lines.append("\(symbols.success) Validation passed")
            headings.insert("\(symbols.success) Validation passed")
            lines.append("  \(success)")
        }
        lines.append("")
        lines.append("Next action")
        headings.insert("Next action")
        lines.append("  \(action)")
        drawWrapped(
            lines,
            row: row,
            column: column,
            width: width,
            height: height,
            scroll: state.detailScroll,
            on: &canvas,
            diff: true,
            horizontalScroll: state.horizontalScroll,
            headingLines: headings,
            semanticRoles: roles
        )
    }

    private func severitySymbol(
        _ severity: Severity,
        symbols: TerminalSymbols
    ) -> String {
        switch severity {
        case .error: symbols.error
        case .warning: symbols.warning
        case .notice: symbols.notice
        }
    }

}
