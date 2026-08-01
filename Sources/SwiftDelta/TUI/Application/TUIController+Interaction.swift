//===--- TUIController+Interaction.swift - SwiftDelta ------------------------------------------===//
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

extension TUIController {
    func handleNavigation(_ key: TUIKey) {
        switch key {
        case .enter, .right:
            selectScreen(.project)
            state.focus = .content
        case .down, .tab:
            state.focus = .content
        default:
            break
        }
    }

    func handleContent(_ key: TUIKey) {
        defer { synchronizeActiveRepairCandidate() }
        let count = contentCount
        switch key {
        case .up:
            state.contentIndex = max(0, state.contentIndex - 1)
        case .down:
            state.contentIndex = min(max(0, count - 1), state.contentIndex + 1)
        case .home:
            state.contentIndex = 0
        case .end:
            state.contentIndex = max(0, count - 1)
        case .pageUp:
            state.contentIndex = max(0, state.contentIndex - 10)
        case .pageDown:
            state.contentIndex = min(
                max(0, count - 1),
                state.contentIndex + 10
            )
        case .left:
            activateCurrent(cycleForward: false)
        case .right:
            activateCurrent(cycleForward: true)
        case .enter:
            activateCurrent(cycleForward: true)
        case .character(" "):
            toggleCurrent()
        default:
            break
        }
    }

    func handleDetails(_ key: TUIKey) {
        switch key {
        case .up:
            state.detailScroll = max(0, state.detailScroll - 1)
        case .down:
            state.detailScroll += 1
        case .pageUp:
            state.detailScroll = max(0, state.detailScroll - 10)
        case .pageDown:
            state.detailScroll += 10
        case .left:
            state.horizontalScroll = max(0, state.horizontalScroll - 4)
        case .right:
            state.horizontalScroll += 4
        case .character("v"), .character("V"):
            if state.screen == .repair,
               let candidate = state.selectedRepairCandidate,
               (!state.effectiveRepairIdentifiers(for: candidate).isEmpty
                    || state.draft(for: candidate) != nil)
            {
                start(.validateRepair)
            }
        case .character("e"), .character("E"):
            if state.screen == .repair,
               let candidate = state.selectedRepairCandidate,
               let draft = state.draft(for: candidate)
            {
                openDraftEditor(draft)
            }
        case .character(" "):
            if state.screen == .repair {
                toggleCurrentRepairCandidate()
            }
        default:
            break
        }
    }

    func handleMouse(
        _ event: TUIMouseEvent,
        terminalSize: TerminalSize
    ) {
        switch event.kind {
        case .scrollUp:
            clearMouseSelection()
            state.contentIndex = max(0, state.contentIndex - 3)
        case .scrollDown:
            clearMouseSelection()
            state.contentIndex = min(
                max(0, contentCount - 1),
                state.contentIndex + 3
            )
        case .press:
            if event.row == 1 {
                state.focus = .navigation
                clearMouseSelection()
            } else {
                state.focus = .content
                let selected = selectContent(
                    at: event.row,
                    terminalSize: terminalSize
                )
                if selected, registerMouseSelection() {
                    activateCurrent(cycleForward: true)
                } else if !selected {
                    clearMouseSelection()
                }
            }
        case .release:
            break
        }
    }

    private func selectContent(
        at terminalRow: Int,
        terminalSize: TerminalSize
    ) -> Bool {
        let contentRow = 3
        let contentHeight = max(1, terminalSize.rows - contentRow - 2)
        switch state.screen {
        case .findings:
            return selectFindingContent(
                at: terminalRow,
                contentRow: contentRow,
                contentHeight: contentHeight
            )
        case .repair:
            return selectRepairContent(
                at: terminalRow,
                contentRow: contentRow,
                contentHeight: contentHeight
            )
        default:
            let welcomeOffset = state.screen == .project
                && TUILayoutMode(columns: terminalSize.columns - 4) == .narrow
                && contentHeight >= 20 ? 2 : 0
            let listRow = contentRow + welcomeOffset
            let listHeight = max(1, contentHeight - welcomeOffset)
            let rows = TUIContentRows.rows(for: state)
            let displayIndices = TUIContentRows.displayedRowIndices(for: rows)
            let visibleCount = max(1, listHeight - (listHeight >= 8 ? 3 : 0))
            guard !rows.isEmpty,
                  terminalRow >= listRow,
                  terminalRow < listRow + visibleCount
            else {
                return false
            }
            let selected = min(
                max(0, state.contentIndex),
                rows.count - 1
            )
            let selectedDisplay = displayIndices.firstIndex {
                $0 == selected
            } ?? 0
            let start = min(
                max(0, selectedDisplay - visibleCount / 2),
                max(0, displayIndices.count - visibleCount)
            )
            let displayIndex = start + terminalRow - listRow
            guard displayIndices.indices.contains(displayIndex),
                  let rowIndex = displayIndices[displayIndex]
            else {
                return false
            }
            state.contentIndex = rowIndex
            return true
        }
    }

    private func selectRepairContent(
        at terminalRow: Int,
        contentRow: Int,
        contentHeight: Int
    ) -> Bool {
        let controls = TUIContentRows.rows(for: state)
        let count = controls.count + state.displayedRepairCandidates.count
        let listRow = contentRow + 2
        let listHeight = max(1, contentHeight - 2)
        guard count > 0,
              terminalRow >= listRow,
              terminalRow < listRow + listHeight
        else {
            return false
        }
        let selected = min(max(0, state.contentIndex), count - 1)
        let start = min(
            max(0, selected - listHeight / 2),
            max(0, count - listHeight)
        )
        state.contentIndex = min(
            count - 1,
            start + terminalRow - listRow
        )
        synchronizeActiveRepairCandidate()
        return true
    }

    private func synchronizeActiveRepairCandidate() {
        guard state.screen == .repair else { return }
        let controls = TUIContentRows.rows(for: state)
        let index = state.contentIndex - controls.count
        let candidates = state.displayedRepairCandidates
        if candidates.indices.contains(index) {
            state.activeRepairCandidateIdentifier =
                candidates[index].candidateIdentifier
        } else if state.activeRepairCandidate == nil {
            state.activeRepairCandidateIdentifier =
                candidates.first?.candidateIdentifier
        }
    }

    private func selectFindingContent(
        at terminalRow: Int,
        contentRow: Int,
        contentHeight: Int
    ) -> Bool {
        let controls = TUIContentRows.resultControls(for: state)
        var displayIndices = controls.indices.map(Optional.some)
        if state.resultsView == .findings {
            var previousGroup: String?
            for (index, finding) in state.findings.enumerated() {
                let group = state.groupKey(for: finding)
                    .replacingOccurrences(
                        of: #"^\d-"#,
                        with: "",
                        options: .regularExpression
                    )
                if group != previousGroup {
                    displayIndices.append(nil)
                    previousGroup = group
                }
                displayIndices.append(controls.count + index)
            }
        }
        let listRow = contentRow + 3
        let listHeight = max(1, contentHeight - 3)
        guard !displayIndices.isEmpty,
              terminalRow >= listRow,
              terminalRow < listRow + listHeight
        else {
            return false
        }
        let selectableCount = controls.count
            + (state.resultsView == .findings ? state.findings.count : 0)
        let selected = min(
            max(0, state.contentIndex),
            max(0, selectableCount - 1)
        )
        let selectedDisplay = displayIndices.firstIndex {
            $0 == selected
        } ?? 0
        let start = min(
            max(0, selectedDisplay - listHeight / 2),
            max(0, displayIndices.count - listHeight)
        )
        let displayIndex = start + terminalRow - listRow
        guard displayIndices.indices.contains(displayIndex),
              let selectableIndex = displayIndices[displayIndex]
        else {
            return false
        }
        state.contentIndex = selectableIndex
        return true
    }

    func activateCurrent(cycleForward: Bool) {
        let rows = TUIContentRows.rows(for: state)
        if state.screen == .findings,
           state.contentIndex >= rows.count
        {
            state.detailPresentation = .finding
            state.focus = .details
            return
        }
        if state.screen == .repair, state.contentIndex >= rows.count {
            state.detailPresentation = .repair
            state.focus = .details
            return
        }
        guard rows.indices.contains(state.contentIndex) else { return }
        let row = rows[state.contentIndex]
        guard row.enabled else { return }
        switch row.action {
        case .none:
            break
        case let .navigate(screen):
            selectScreen(screen)
            if screen == .repair,
               state.report != nil,
               state.repairPlan == nil
            {
                start(.planRepair)
            }
        case .showHelp:
            state.detailScroll = 0
            state.overlay = .shortcuts
        case .showAbout:
            state.settingsSection = .about
            selectScreen(.settings)
        case .showDoctorDetails:
            if let doctor = state.doctorResult {
                state.detailScroll = 0
                state.overlay = .message(
                    title: doctor.issues.isEmpty
                        ? "Setup details" : "Setup needs attention",
                    message: doctor.issues.first
                        ?? (
                            doctor.notes.isEmpty
                                ? "The selected project and toolchains passed preflight."
                                : "Setup is ready. Exact build context will be "
                                    + "captured during the compatibility check."
                        ),
                    details: (
                        doctor.lines
                            + doctor.notes.map { "Note: \($0)" }
                            + doctor.issues.map { "Issue: \($0)" }
                    ).joined(separator: "\n")
                )
            }
        case let .showRepairDisposition(identifier):
            showRepairDisposition(identifier)
        case .editSelectedRepairDraft:
            guard let candidate = state.selectedRepairCandidate,
                  let draft = state.draft(for: candidate)
            else { return }
            openDraftEditor(draft)
        case .toggleSelectedRepair:
            toggleCurrentRepairCandidate()
        case .repairSelectedFinding:
            if let finding = state.selectedFinding {
                state.settings.workflow.findingIdentifiers = [
                    finding.findingID,
                ]
            }
            selectScreen(.repair)
            if state.report != nil, state.repairPlan == nil {
                start(.planRepair)
            }
        case let .selectRecentProject(path):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                state.overlay = .message(
                    title: "Recent project unavailable",
                    message: "The stored project directory is no longer accessible.",
                    details: path
                )
                return
            }
            state.settings.workflow.projectRoot = URL(
                fileURLWithPath: path
            ).standardizedFileURL.resolvingSymlinksInPath().path
            state.projectWasExplicitlySelected = true
            state.discovery = nil
            state.doctorResult = nil
            state.report = nil
            state.repairPlan = nil
            state.repairFindingDispositions = []
            state.repairCandidates = []
            state.activeRepairCandidateIdentifier = nil
            state.repairDrafts = []
            state.repairCoverage = nil
            state.foundationModelPlanningSummary = nil
            state.selectedRepairIDs = []
            state.validatedRepairCandidateIDs = []
            state.validatedRepairIDs = []
            state.validatedCandidateRepairIdentifiers = [:]
            state.repairValidationMessages = [:]
            state.repairValidationSuccessMessages = [:]
            state.repairValidationSkippedMessages = [:]
            state.staleRepairCandidateIDs = []
            state.selectedContainer = nil
            state.setupNotes = []
            state.settings.workflow.workspacePath = nil
            state.settings.workflow.projectPath = nil
            state.settings.workflow.scheme = nil
            state.settings.workflow.buildConfiguration = nil
            state.settings.workflow.destination = nil
            state.settings.workflow.sdkIdentifiers = []
            for field in [
                TUISetupField.container,
                .scheme,
                .buildConfiguration,
                .destination,
                .sdk,
            ] {
                state.setupOrigins.removeValue(forKey: field)
            }
            saveSettings()
            start(.automaticSetup)
        case let .edit(field):
            state.overlay = .textInput(
                title: row.label,
                field: field,
                value: editableValue(field)
            )
        case let .chooseSetup(field):
            state.requestedSetupField = field
            start(.automaticSetup)
        case let .toggle(toggle):
            setToggle(toggle)
        case let .cycle(cycle):
            setCycle(cycle, forward: cycleForward)
        case let .operation(kind):
            if kind == .doctor, state.screen == .project {
                state.advanceAfterSetup = true
            }
            start(kind)
        case let .confirmation(action):
            state.overlay = confirmationOverlay(for: action)
        }
    }

    private func showRepairDisposition(_ identifier: String) {
        guard let group = state.repairDispositionGroups.first(
            where: { $0.identifier == identifier }
        ) else {
            return
        }
        var details = [
            "Status: \(repairDispositionLabel(group.kind))",
            "Occurrences: \(group.dispositions.count)",
            "Reason: \(group.reason)",
            "",
        ]
        for (index, disposition) in group.dispositions.enumerated() {
            let finding = state.report?.findings.first {
                $0.stableKey == disposition.findingStableKey
            }
            let location = disposition.location.map {
                let line = $0.line.map { ":\($0)" } ?? ""
                let column = $0.column.map { ":\($0)" } ?? ""
                return "\($0.path)\(line)\(column)"
            } ?? "No editable source location"
            details.append(
                "\(index + 1). \(location)"
            )
            details.append(
                "   Finding: \(disposition.findingIdentifier)"
            )
            if let finding {
                details.append(
                    "   Type: \(finding.category.rawValue) · "
                        + "\(finding.origin.rawValue) evidence · "
                        + "\(finding.severity.rawValue) · "
                        + "\(finding.confidence.rawValue) confidence"
                )
                if let evidence = finding.sdkEvidence {
                    details.append(
                        "   Symbol: "
                            + (
                                evidence.preciseIdentifier
                                ?? evidence.fullyQualifiedName
                            )
                    )
                    details.append(
                        "   SDK: \(evidence.platform) · \(evidence.moduleName)"
                    )
                }
            }
            let repairs = state.repairPlan?.repairs.filter {
                disposition.repairIdentifiers.contains(
                    $0.repairIdentifier
                )
            } ?? []
            for repair in repairs {
                details.append(
                    "   Repair evidence: \(repair.evidenceSource.rawValue)"
                )
                details.append(
                    "   Safety: \(repair.safety.rawValue) · "
                        + "\(repair.confidence.rawValue) confidence"
                )
                details.append("   Original: \(repair.originalText)")
                details.append("   Proposed: \(repair.replacementText)")
                details.append(
                    "   Diff: -\(repair.originalText)  +\(repair.replacementText)"
                )
                if repair.modelGenerated == true {
                    details.append(
                        "   Apple Foundation Models · "
                            + "\(repair.execution ?? "On-device") · "
                            + "\(repair.hostModelGeneration ?? "unknown generation") · "
                            + "\(repair.reasoningLevel ?? "unsupported") reasoning · "
                            + "review required"
                    )
                }
                details.append(
                    "   Verification: \(repair.verificationRequirement.rawValue)"
                )
            }
            if index < group.dispositions.count - 1 {
                details.append("")
            }
        }
        state.detailScroll = 0
        state.overlay = .message(
            title: group.title,
            message:
                group.hasConflict
                ? "Conflicting evidence requires review."
                : group.reason,
            details: details.joined(separator: "\n")
        )
    }

    private func repairDispositionLabel(
        _ kind: RepairFindingDispositionKind
    ) -> String {
        switch kind {
        case .automaticallySafe:
            "Automatically safe repair"
        case .foundationModelsProposal:
            "Apple Foundation Models proposal"
        case .manualReviewRequired:
            "Manual review required"
        case .notRepairable:
            "Not repairable"
        }
    }

    func toggleCurrent() {
        if state.screen == .repair {
            if state.selectedRepairCandidate != nil {
                toggleCurrentRepairCandidate()
                return
            }
        }
        let rows = TUIContentRows.rows(for: state)
        guard rows.indices.contains(state.contentIndex) else { return }
        if case let .toggle(toggle) = rows[state.contentIndex].action {
            setToggle(toggle)
        }
    }

    private func toggleCurrentRepairCandidate() {
        guard let plan = state.repairPlan,
              let candidate = state.selectedRepairCandidate
        else {
            return
        }
        guard state.candidateIsSelectable(candidate) else {
            let identifiers = Set(
                state.effectiveRepairIdentifiers(for: candidate)
            )
            let hasConflict = !identifiers.isDisjoint(
                with: state.repairConflictIdentifiers
            )
            let action = state.effectiveRepairIdentifiers(
                for: candidate
            ).isEmpty && state.draft(for: candidate) == nil
                ? "No exact source edit was retained for this item."
                : (hasConflict
                    ? "Resolve the overlapping or contradictory edit before selection."
                    : "Open the proposal and choose Edit or Validate Again.")
            state.overlay = .message(
                title: "Repair cannot be selected",
                message:
                    "\(candidateStatusText(state.effectiveStatus(for: candidate))). "
                    + action,
                details: candidate.explanation
            )
            return
        }
        do {
            try RepairPlanPreflight.validate(
                plan,
                projectRoot: URL(
                    fileURLWithPath: state.settings.workflow.projectRoot
                )
            )
        } catch {
            state.staleRepairCandidateIDs.insert(
                candidate.candidateIdentifier
            )
            state.overlay = .message(
                title: "Repair plan is stale",
                message:
                    "The source no longer matches the preview. Generate a new repair plan.",
                details: String(describing: error)
            )
            return
        }
        let identifiers = Set(
            state.effectiveRepairIdentifiers(for: candidate)
        )
        if identifiers.isSubset(of: state.selectedRepairIDs) {
            state.selectedRepairIDs.subtract(identifiers)
        } else {
            state.selectedRepairIDs.formUnion(identifiers)
        }
    }

    private func candidateStatusText(
        _ status: RepairCandidateStatus
    ) -> String {
        switch status {
        case .ready: "Ready"
        case .needsValidation: "This proposal needs validation."
        case .reviewRequired: "This proposal requires review."
        case .verificationFailed: "Candidate-Xcode verification failed."
        case .rejected: "Safety validation rejected this proposal."
        case .noProposal: "No source proposal was produced."
        }
    }

    private func openDraftEditor(_ draft: RepairDraft) {
        guard !draft.edits.isEmpty else {
            state.overlay = .message(
                title: "Draft has no source edit",
                message:
                    "The on-device model did not return a usable source "
                    + "anchor or replacement for this finding.",
                details: draft.initialIssues.map(\.message)
                    .joined(separator: "\n")
            )
            return
        }
        let firstText = draft.edits[0].originalAnchor
        state.overlay = .draftEditor(
            TUIRepairDraftEditor(
                draftIdentifier: draft.draftIdentifier,
                edits: draft.edits,
                selectedEditIndex: 0,
                field: .originalAnchor,
                cursorOffset: firstText.count,
                explanation: draft.explanation,
                validationProblems: draft.initialIssues.map {
                    "\($0.stage.rawValue): \($0.message)"
                }
            )
        )
    }

    private func saveDraftEditor(_ editor: TUIRepairDraftEditor) {
        guard let index = state.repairDrafts.firstIndex(where: {
            $0.draftIdentifier == editor.draftIdentifier
        }) else {
            state.overlay = .message(
                title: "Draft unavailable",
                message:
                    "The repair preview changed while the draft was open. "
                    + "Generate a new preview.",
                details: nil
            )
            return
        }
        let previous = state.repairDrafts[index]
        state.repairDrafts[index] = previous.replacingEdits(
            editor.edits,
            issues: previous.initialIssues.filter {
                $0.stage == .hardSafetyRejection
            }
        )
        guard let candidate = state.repairCandidates.first(where: {
            $0.draftIdentifier == editor.draftIdentifier
        }) else {
            state.overlay = .none
            return
        }
        let candidateID = candidate.candidateIdentifier
        if let oldIdentifiers =
            state.validatedCandidateRepairIdentifiers.removeValue(
                forKey: candidateID
            )
        {
            state.selectedRepairIDs.subtract(oldIdentifiers)
            state.validatedRepairIDs.subtract(oldIdentifiers)
            if let plan = state.repairPlan {
                state.repairPlan = RepairPlanBuilder.build(
                    projectRoot: URL(
                        fileURLWithPath:
                            state.settings.workflow.projectRoot
                    ),
                    repairs: plan.repairs.filter {
                        !oldIdentifiers.contains($0.repairIdentifier)
                    },
                    planningFailures: plan.planningFailures,
                    generatedAt: plan.generatedAt
                )
            }
        }
        state.validatedRepairCandidateIDs.remove(candidateID)
        state.staleRepairCandidateIDs.remove(candidateID)
        state.repairValidationMessages[candidateID] = nil
        state.repairValidationSuccessMessages[candidateID] = nil
        state.repairValidationSkippedMessages[candidateID] = nil
        state.overlay = .none
    }

    private func handleDraftEditor(
        _ key: TUIKey,
        editor: inout TUIRepairDraftEditor
    ) {
        guard editor.edits.indices.contains(editor.selectedEditIndex) else {
            state.overlay = .none
            return
        }
        switch key {
        case .escape:
            state.overlay = .none
        case .tab, .backTab:
            editor.field = editor.field == .originalAnchor
                ? .proposedSource : .originalAnchor
            editor.cursorOffset = draftEditorText(editor).count
            state.overlay = .draftEditor(editor)
        case .pageUp:
            editor.selectedEditIndex = max(
                0,
                editor.selectedEditIndex - 1
            )
            editor.cursorOffset = draftEditorText(editor).count
            state.overlay = .draftEditor(editor)
        case .pageDown:
            editor.selectedEditIndex = min(
                editor.edits.count - 1,
                editor.selectedEditIndex + 1
            )
            editor.cursorOffset = draftEditorText(editor).count
            state.overlay = .draftEditor(editor)
        case .left:
            editor.cursorOffset = max(0, editor.cursorOffset - 1)
            state.overlay = .draftEditor(editor)
        case .right:
            editor.cursorOffset = min(
                draftEditorText(editor).count,
                editor.cursorOffset + 1
            )
            state.overlay = .draftEditor(editor)
        case .home:
            editor.cursorOffset = lineStartOffset(
                draftEditorText(editor),
                cursor: editor.cursorOffset
            )
            state.overlay = .draftEditor(editor)
        case .end:
            editor.cursorOffset = lineEndOffset(
                draftEditorText(editor),
                cursor: editor.cursorOffset
            )
            state.overlay = .draftEditor(editor)
        case .up:
            moveDraftEditorCursor(&editor, lineDelta: -1)
            state.overlay = .draftEditor(editor)
        case .down:
            moveDraftEditorCursor(&editor, lineDelta: 1)
            state.overlay = .draftEditor(editor)
        case .enter:
            replaceDraftEditorText(&editor, insertion: "\n")
            state.overlay = .draftEditor(editor)
        case .backspace:
            deleteDraftEditorCharacter(&editor, beforeCursor: true)
            state.overlay = .draftEditor(editor)
        case .delete:
            deleteDraftEditorCharacter(&editor, beforeCursor: false)
            state.overlay = .draftEditor(editor)
        case .character("\u{13}"):
            saveDraftEditor(editor)
        case let .character(character):
            guard character.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7F
            }) else {
                return
            }
            replaceDraftEditorText(
                &editor,
                insertion: String(character)
            )
            state.overlay = .draftEditor(editor)
        default:
            break
        }
    }

    private func draftEditorText(
        _ editor: TUIRepairDraftEditor
    ) -> String {
        let edit = editor.edits[editor.selectedEditIndex]
        return editor.field == .originalAnchor
            ? edit.originalAnchor : edit.proposedSource
    }

    private func setDraftEditorText(
        _ editor: inout TUIRepairDraftEditor,
        _ text: String
    ) {
        let edit = editor.edits[editor.selectedEditIndex]
        editor.edits[editor.selectedEditIndex] = RepairDraftEdit(
            operation: edit.operation,
            sourceFileIdentity: edit.sourceFileIdentity,
            originalAnchor:
                editor.field == .originalAnchor
                    ? text : edit.originalAnchor,
            proposedSource:
                editor.field == .proposedSource
                    ? text : edit.proposedSource
        )
    }

    private func replaceDraftEditorText(
        _ editor: inout TUIRepairDraftEditor,
        insertion: String
    ) {
        var characters = Array(draftEditorText(editor))
        let cursor = min(max(0, editor.cursorOffset), characters.count)
        characters.insert(
            contentsOf: Array(insertion),
            at: cursor
        )
        editor.cursorOffset = cursor + insertion.count
        setDraftEditorText(&editor, String(characters))
    }

    private func deleteDraftEditorCharacter(
        _ editor: inout TUIRepairDraftEditor,
        beforeCursor: Bool
    ) {
        var characters = Array(draftEditorText(editor))
        var cursor = min(max(0, editor.cursorOffset), characters.count)
        let index = beforeCursor ? cursor - 1 : cursor
        guard characters.indices.contains(index) else { return }
        characters.remove(at: index)
        if beforeCursor { cursor -= 1 }
        editor.cursorOffset = cursor
        setDraftEditorText(&editor, String(characters))
    }

    private func lineStartOffset(
        _ text: String,
        cursor: Int
    ) -> Int {
        let characters = Array(text)
        var offset = min(max(0, cursor), characters.count)
        while offset > 0, characters[offset - 1] != "\n" {
            offset -= 1
        }
        return offset
    }

    private func lineEndOffset(
        _ text: String,
        cursor: Int
    ) -> Int {
        let characters = Array(text)
        var offset = min(max(0, cursor), characters.count)
        while offset < characters.count, characters[offset] != "\n" {
            offset += 1
        }
        return offset
    }

    private func moveDraftEditorCursor(
        _ editor: inout TUIRepairDraftEditor,
        lineDelta: Int
    ) {
        let text = draftEditorText(editor)
        let characters = Array(text)
        let lineStart = lineStartOffset(
            text,
            cursor: editor.cursorOffset
        )
        let column = editor.cursorOffset - lineStart
        if lineDelta < 0 {
            guard lineStart > 0 else { return }
            let previousEnd = lineStart - 1
            let previousStart = lineStartOffset(
                text,
                cursor: previousEnd
            )
            editor.cursorOffset = min(
                previousStart + column,
                previousEnd
            )
        } else {
            let currentEnd = lineEndOffset(
                text,
                cursor: editor.cursorOffset
            )
            guard currentEnd < characters.count else { return }
            let nextStart = currentEnd + 1
            let nextEnd = lineEndOffset(text, cursor: nextStart)
            editor.cursorOffset = min(nextStart + column, nextEnd)
        }
    }

    func handleOverlay(
        _ key: TUIKey,
        terminalSize: TerminalSize
    ) {
        switch state.overlay {
        case var .draftEditor(editor):
            handleDraftEditor(key, editor: &editor)
        case let .textInput(title, field, value):
            switch key {
            case .escape:
                state.overlay = .none
            case .enter:
                commit(field: field, value: value)
            case .backspace:
                var copy = value
                if !copy.isEmpty { copy.removeLast() }
                state.overlay = .textInput(
                    title: title,
                    field: field,
                    value: copy
                )
            case .delete:
                state.overlay = .textInput(
                    title: title,
                    field: field,
                    value: ""
                )
            case let .character(character):
                guard !character.isNewline,
                      character.unicodeScalars.allSatisfy({
                          $0.value >= 0x20 && $0.value != 0x7F
                      })
                else {
                    return
                }
                state.overlay = .textInput(
                    title: title,
                    field: field,
                    value: value + String(character)
                )
            default:
                break
            }
        case var .requiredInput(input):
            switch key {
            case .escape:
                state.overlay = .none
                state.pendingOperation = nil
            case .enter:
                commitRequiredInput(&input)
            case .backspace:
                if !input.value.isEmpty {
                    input.value.removeLast()
                }
                input.validationMessage = nil
                state.overlay = .requiredInput(input)
            case .delete:
                input.value = ""
                input.validationMessage = nil
                state.overlay = .requiredInput(input)
            case let .character(character):
                guard !character.isNewline,
                      character.unicodeScalars.allSatisfy({
                          $0.value >= 0x20 && $0.value != 0x7F
                      })
                else {
                    return
                }
                input.value.append(character)
                input.validationMessage = nil
                state.overlay = .requiredInput(input)
            default:
                break
            }
        case let .confirmation(_, _, action):
            switch key {
            case .escape, .character("n"), .character("N"):
                state.overlay = .none
            case .enter, .character("y"), .character("Y"):
                state.overlay = .none
                confirm(action)
            default:
                break
            }
        case .message, .shortcuts, .logs:
            switch key {
            case .escape, .enter:
                state.overlay = .none
                state.detailScroll = 0
            case .up:
                state.detailScroll = max(0, state.detailScroll - 1)
            case .down:
                state.detailScroll += 1
            case .pageUp:
                state.detailScroll = max(0, state.detailScroll - 10)
            case .pageDown:
                state.detailScroll += 10
            case .home:
                state.detailScroll = 0
            case .end:
                state.detailScroll = Int.max / 2
            case let .mouse(event):
                clearMouseSelection()
                if event.kind == .scrollUp {
                    state.detailScroll = max(0, state.detailScroll - 3)
                } else if event.kind == .scrollDown {
                    state.detailScroll += 3
                }
            default:
                break
            }
        case var .setupResolution(resolution):
            switch key {
            case .escape:
                state.overlay = .none
                state.pendingOperation = nil
            case .up:
                resolution.selectedIndex = max(
                    0, resolution.selectedIndex - 1
                )
                state.overlay = .setupResolution(resolution)
            case .down:
                resolution.selectedIndex = min(
                    max(0, resolution.choices.count - 1),
                    resolution.selectedIndex + 1
                )
                state.overlay = .setupResolution(resolution)
            case .home:
                resolution.selectedIndex = 0
                state.overlay = .setupResolution(resolution)
            case .end:
                resolution.selectedIndex = max(
                    0, resolution.choices.count - 1
                )
                state.overlay = .setupResolution(resolution)
            case .character("d"):
                resolution.showsTechnicalDetails.toggle()
                state.overlay = .setupResolution(resolution)
            case .enter:
                guard resolution.choices.indices.contains(
                    resolution.selectedIndex
                ) else { return }
                guard resolution.choices[resolution.selectedIndex].enabled else {
                    return
                }
                applySetupChoice(
                    resolution.choices[resolution.selectedIndex].value
                )
            case let .mouse(event):
                switch event.kind {
                case .scrollUp:
                    resolution.selectedIndex = max(
                        0, resolution.selectedIndex - 1
                    )
                    state.overlay = .setupResolution(resolution)
                case .scrollDown:
                    resolution.selectedIndex = min(
                        max(0, resolution.choices.count - 1),
                        resolution.selectedIndex + 1
                    )
                    state.overlay = .setupResolution(resolution)
                case .press:
                    let height = min(
                        34,
                        max(
                            12,
                            min(
                                terminalSize.rows - 4,
                                terminalSize.rows * 3 / 4
                            )
                        )
                    )
                    let panelRow = (terminalSize.rows - height) / 2
                    let listRow = panelRow + 6
                    let footerSpace = resolution.showsTechnicalDetails ? 7 : 3
                    let available = max(
                        1,
                        (height - (listRow - panelRow) - footerSpace) / 2
                    )
                    let selected = min(
                        max(0, resolution.selectedIndex),
                        max(0, resolution.choices.count - 1)
                    )
                    let start = min(
                        max(0, selected - available / 2),
                        max(0, resolution.choices.count - available)
                    )
                    let index = start + (event.row - listRow) / 2
                    guard resolution.choices.indices.contains(index) else {
                        return
                    }
                    resolution.selectedIndex = index
                    state.overlay = .setupResolution(resolution)
                    if resolution.choices[index].enabled,
                       registerSetupChoiceSelection(
                        field: resolution.field,
                        index: index
                    ) {
                        applySetupChoice(
                            resolution.choices[index].value
                        )
                    }
                case .release:
                    break
                }
            default:
                break
            }
        case .none:
            break
        }
    }

    private func commitRequiredInput(
        _ input: inout TUIRequiredInput
    ) {
        let trimmed = input.value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        do {
            guard !trimmed.isEmpty else {
                throw LaunchError("Enter a value before continuing.")
            }
            switch input.field {
            case .projectRoot:
                let expanded = NSString(
                    string: trimmed
                ).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: expanded,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw LaunchError(
                        "The project root must be an accessible directory."
                    )
                }
                state.pendingOperation = input.pendingOperation
                state.overlay = .none
                commit(field: .projectRoot, value: expanded)
            case .reportOutput, .repairOutput:
                let expanded = NSString(
                    string: trimmed
                ).expandingTildeInPath
                let output = NSString(string: expanded).isAbsolutePath
                    ? URL(fileURLWithPath: expanded)
                    : URL(
                        fileURLWithPath:
                            state.settings.workflow.projectRoot,
                        isDirectory: true
                    ).appendingPathComponent(expanded)
                let parent = output.standardizedFileURL
                    .deletingLastPathComponent()
                var parentIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: parent.path,
                    isDirectory: &parentIsDirectory
                ), parentIsDirectory.boolValue else {
                    throw LaunchError(
                        "The selected output directory does not exist."
                    )
                }
                guard FileManager.default.isWritableFile(
                    atPath: parent.path
                ) else {
                    throw LaunchError(
                        "The selected output directory is not writable."
                    )
                }
                var outputIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(
                    atPath: output.path,
                    isDirectory: &outputIsDirectory
                ), outputIsDirectory.boolValue {
                    throw LaunchError(
                        "The selected output path is a directory."
                    )
                }
                state.overlay = .none
                commit(field: input.field, value: output.path)
                state.pendingOperation = nil
                start(input.pendingOperation)
            default:
                throw LaunchError(
                    "This value must be selected from its setup screen."
                )
            }
        } catch {
            input.validationMessage = error.localizedDescription
            state.overlay = .requiredInput(input)
        }
    }

    private func applySetupChoice(_ choice: TUISetupChoiceValue) {
        if case let .baselineXcode(path) = choice,
           !validateXcodeChoice(path, other: state.settings.workflow.candidateXcodePath)
        {
            return
        }
        if case let .candidateXcode(path) = choice,
           !validateXcodeChoice(path, other: state.settings.workflow.baselineXcodePath)
        {
            return
        }
        invalidateDownstreamEvidence()
        let field: TUISetupField?
        switch choice {
        case let .project(path):
            state.settings.workflow.projectPath = path
            state.settings.workflow.workspacePath = nil
            field = .container
        case let .workspace(path):
            state.settings.workflow.workspacePath = path
            state.settings.workflow.projectPath = nil
            field = .container
        case let .packageRoot(path):
            state.settings.workflow.projectRoot = path
            state.settings.workflow.workspacePath = nil
            state.settings.workflow.projectPath = nil
            field = .container
        case let .scheme(value):
            state.settings.workflow.scheme = value
            field = .scheme
        case let .buildConfiguration(value):
            state.settings.workflow.buildConfiguration = value
            field = .buildConfiguration
        case let .sdk(identifier, destination):
            state.settings.workflow.sdkIdentifiers = [identifier]
            state.settings.workflow.destination = destination
            state.setupOrigins[.destination] = .saved
            field = .sdk
        case let .baselineXcode(path):
            state.settings.workflow.baselineXcodePath = path
            field = .baselineXcode
        case let .candidateXcode(path):
            state.settings.workflow.candidateXcodePath = path
            field = .candidateXcode
        case let .manual(editable):
            state.overlay = .textInput(
                title: "Enter \(editable.rawValue)",
                field: editable,
                value: editableValue(editable)
            )
            return
        }
        if let field {
            state.setupOrigins[field] = .saved
        }
        state.settings.workflow.setupValueOrigins = Dictionary(
            uniqueKeysWithValues: state.setupOrigins.map {
                ($0.key.rawValue, $0.value)
            }
        )
        state.overlay = .none
        saveSettings()
        start(.automaticSetup)
    }

    var contentCount: Int {
        if state.screen == .findings {
            let controls = TUIContentRows.resultControls(for: state).count
            return controls + (
                state.resultsView == .findings ? state.findings.count : 0
            )
        }
        let rows = TUIContentRows.rows(for: state)
        if state.screen == .repair {
            return rows.count + state.displayedRepairCandidates.count
        }
        return rows.count
    }

    func selectScreen(_ screen: TUIScreen) {
        if screen == .repair {
            refreshFoundationModelStatus()
        }
        state.screen = screen
        state.navigationIndex = state.navigationScreens.firstIndex(
            of: screen
        ) ?? 0
        state.contentIndex = 0
        state.detailScroll = 0
        state.horizontalScroll = 0
        state.detailPresentation = .none
        state.advancedOptionsExpanded = false
    }

    func cycleFocus(
        forward: Bool,
        terminalSize: TerminalSize
    ) {
        let mode = TUILayoutMode(columns: terminalSize.columns)
        var values: [TUIFocus] = [.content]
        let detailsAvailable = mode == .wide
            && (
                (state.screen == .findings && state.selectedFinding != nil)
                    || (state.screen == .repair && state.selectedRepair != nil)
            )
        if detailsAvailable {
            values.append(.details)
        }
        guard let index = values.firstIndex(of: state.focus) else {
            state.focus = .content
            return
        }
        let delta = forward ? 1 : values.count - 1
        state.focus = values[(index + delta) % values.count]
    }

}
