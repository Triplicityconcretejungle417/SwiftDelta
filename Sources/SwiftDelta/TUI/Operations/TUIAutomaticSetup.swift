//===--- TUIAutomaticSetup.swift - SwiftDelta ------------------------------------------===//
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

struct TUIAutomaticSetupSelector {
    struct SDKContext: Equatable, Sendable {
        let identifier: String
        let destination: String
        let detail: String

        var label: String {
            detail
        }
    }

    func container(
        from discovery: DiscoveryResult,
        root: URL
    ) -> (selected: ProjectContainer?, choices: [ProjectContainer]) {
        let xcodeContainers = discovery.containers.filter {
            $0.kind == .project || $0.kind == .workspace
        }
        let packages = discovery.containers.filter { $0.kind == .package }
        guard !xcodeContainers.isEmpty else {
            return packages.count == 1
                ? (packages[0], packages)
                : (nil, packages)
        }
        guard xcodeContainers.count > 1 else {
            return (xcodeContainers[0], xcodeContainers)
        }

        let projects = xcodeContainers.filter { $0.kind == .project }
        let workspaces = xcodeContainers.filter { $0.kind == .workspace }
        let associated = workspaces.filter {
            workspace($0, referencesAnyOf: projects)
        }
        if associated.count == 1 {
            return (associated[0], xcodeContainers)
        }

        let rootName = root.lastPathComponent.lowercased()
        let named = xcodeContainers.filter {
            URL(fileURLWithPath: $0.path)
                .deletingPathExtension().lastPathComponent.lowercased()
                == rootName
        }
        if named.count == 1 {
            return (named[0], xcodeContainers)
        }
        return (nil, xcodeContainers)
    }

    func scheme(
        available: [String],
        container: ProjectContainer,
        targets: [String]
    ) -> (selected: String?, ordered: [String]) {
        let unique = Array(Set(available)).sorted()
        guard unique.count > 1 else {
            return (unique.first, unique)
        }
        let containerName = URL(fileURLWithPath: container.path)
            .deletingPathExtension().lastPathComponent
        let exactContainer = unique.filter {
            $0.compare(containerName, options: .caseInsensitive)
                == .orderedSame
        }
        if exactContainer.count == 1 {
            return (exactContainer[0], exactContainer + unique.filter {
                $0 != exactContainer[0]
            })
        }
        let targetMatches = unique.filter { scheme in
            targets.contains {
                $0.compare(scheme, options: .caseInsensitive) == .orderedSame
            }
        }
        if targetMatches.count == 1 {
            return (targetMatches[0], targetMatches + unique.filter {
                $0 != targetMatches[0]
            })
        }
        return (nil, unique)
    }

    func sdkContexts(
        from snapshots: [BuildSettingsSnapshot]
    ) -> [SDKContext] {
        let identifiers = BuildSettingsAnalyzer().sdkIdentifiers(in: snapshots)
        let productTypes = snapshots.compactMap {
            $0.settings["PRODUCT_TYPE"]
        }
        let isApplication = productTypes.contains {
            $0 == "com.apple.product-type.application"
        }
        var contexts = identifiers.compactMap(context)
        let supportsCatalyst = snapshots.contains {
            $0.settings["SUPPORTS_MACCATALYST"] == "YES"
        }
        if supportsCatalyst, identifiers.contains("macosx") {
            contexts.removeAll {
                $0.identifier == "macosx"
                    && $0.destination == "platform=macOS"
            }
            contexts.append(
                SDKContext(
                    identifier: "macosx",
                    destination: "platform=macOS,variant=Mac Catalyst",
                    detail: "Mac Catalyst"
                )
            )
            let hasNativeMacTarget = snapshots.contains {
                $0.settings["PLATFORM_NAME"] == "macosx"
                    && $0.settings["SUPPORTS_MACCATALYST"] != "YES"
            }
            if hasNativeMacTarget {
                contexts.append(
                    SDKContext(
                        identifier: "macosx",
                        destination: "platform=macOS",
                        detail: "macOS"
                    )
                )
            }
        }

        // Xcode may list macosx for an iOS target solely because Catalyst is
        // enabled. The device SDK remains the normal application context.
        if isApplication, identifiers.contains("iphoneos") {
            contexts.sort {
                if $0.identifier == "iphoneos" { return true }
                if $1.identifier == "iphoneos" { return false }
                return rank($0.identifier) < rank($1.identifier)
            }
            return contexts
        }

        let sdkRoots = snapshots.compactMap { $0.settings["SDKROOT"] }
        contexts.sort {
            let leftIdentifier = $0.identifier
            let rightIdentifier = $1.identifier
            let leftRoot = sdkRoots.contains {
                $0.lowercased().contains(leftIdentifier)
            }
            let rightRoot = sdkRoots.contains {
                $0.lowercased().contains(rightIdentifier)
            }
            if leftRoot != rightRoot { return leftRoot }
            return rank($0.identifier) < rank($1.identifier)
        }
        return contexts
    }

    func preferredSDKContext(
        from snapshots: [BuildSettingsSnapshot]
    ) -> SDKContext? {
        let contexts = sdkContexts(from: snapshots)
        guard !contexts.isEmpty else { return nil }
        let identifiers = Set(contexts.map(\.identifier))
        let isApplication = snapshots.contains {
            $0.settings["PRODUCT_TYPE"]
                == "com.apple.product-type.application"
        }
        if isApplication, identifiers.contains("iphoneos") {
            return contexts.first { $0.identifier == "iphoneos" }
        }
        let effectiveRoots = Set(snapshots.compactMap {
            sdkIdentifier(from: $0.settings["SDKROOT"])
        })
        if effectiveRoots.count == 1, let identifier = effectiveRoots.first {
            return contexts.first { $0.identifier == identifier }
        }
        return contexts.count == 1 ? contexts[0] : nil
    }

    private func workspace(
        _ workspace: ProjectContainer,
        referencesAnyOf projects: [ProjectContainer]
    ) -> Bool {
        let contents = URL(fileURLWithPath: workspace.path)
            .appendingPathComponent("contents.xcworkspacedata")
        guard let data = try? Data(contentsOf: contents, options: [.mappedIfSafe]),
              data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return projects.contains {
            text.contains(URL(fileURLWithPath: $0.path).lastPathComponent)
        }
    }

    private func context(_ identifier: String) -> SDKContext? {
        switch identifier {
        case "iphoneos":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=iOS",
                detail: "iOS Device"
            )
        case "iphonesimulator":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=iOS Simulator",
                detail: "iOS Simulator"
            )
        case "macosx":
            SDKContext(
                identifier: identifier,
                destination: "platform=macOS",
                detail: "macOS"
            )
        case "appletvos":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=tvOS",
                detail: "tvOS Device"
            )
        case "appletvsimulator":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=tvOS Simulator",
                detail: "tvOS Simulator"
            )
        case "watchos":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=watchOS",
                detail: "watchOS Device"
            )
        case "watchsimulator":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=watchOS Simulator",
                detail: "watchOS Simulator"
            )
        case "xros":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=visionOS",
                detail: "visionOS Device"
            )
        case "xrsimulator":
            SDKContext(
                identifier: identifier,
                destination: "generic/platform=visionOS Simulator",
                detail: "visionOS Simulator"
            )
        default:
            nil
        }
    }

    private func rank(_ identifier: String) -> Int {
        [
            "iphoneos", "iphonesimulator", "appletvos",
            "watchos", "xros", "macosx",
        ].firstIndex(of: identifier) ?? Int.max
    }

    private func sdkIdentifier(from value: String?) -> String? {
        guard let value else { return nil }
        let leaf = URL(fileURLWithPath: value).lastPathComponent
            .lowercased().replacingOccurrences(of: ".sdk", with: "")
        return [
            "iphonesimulator", "iphoneos", "appletvsimulator", "appletvos",
            "watchsimulator", "watchos", "xrsimulator", "xros", "macosx",
        ].first { leaf.hasPrefix($0) }
    }

}

extension CoreTUIOperationService {
    func automaticSetup(
        root: URL,
        workflow: TUIWorkflowSettings,
        runner: any ProcessRunning,
        progress: OperationProgress,
        cancellation: @escaping @Sendable () -> Bool,
        requestedField: TUISetupField? = nil
    ) throws -> TUIAutomaticSetupResult {
        var updated = workflow
        var origins = decodedOrigins(workflow)
        var notes: [String] = []
        let selector = TUIAutomaticSetupSelector()
        let configuration = try effectiveConfiguration(
            root: root,
            workflow: workflow
        )
        let discovery = try progress.phase(
            "Discovering project structure",
            completedMessage: "Discovered project structure"
        ) {
            try ProjectDiscovery().discover(
                root: root,
                excludedPaths: configuration.excludedPaths
            )
        }
        if cancellation() {
            throw CancellationError()
        }

        let applications = progress.phase(
            "Discovering Xcode installations",
            completedMessage: "Discovered Xcode installations"
        ) {
            XcodeInstallation.discoverApplications(runner: runner)
        }
        if let resolution = selectXcodes(
            applications,
            workflow: &updated,
            origins: &origins,
            requestedField: requestedField
        ) {
            return setupResult(
                updated, discovery, origins, nil, resolution, notes
            )
        }

        if requestedField == .container {
            let choice = selector.container(from: discovery, root: root)
            return setupResult(
                updated,
                discovery,
                origins,
                nil,
                containerResolution(choice.choices, root: root),
                notes
            )
        }
        let selectedContainer: ProjectContainer?
        do {
            if configuration.defaultProject != nil
                || configuration.defaultWorkspace != nil
            {
                selectedContainer = try ProjectDiscovery().selectBuildContainer(
                    from: discovery,
                    project: configuration.defaultProject,
                    workspace: configuration.defaultWorkspace
                )
                if selectedContainer?.kind == .workspace {
                    updated.workspacePath = selectedContainer?.path
                    updated.projectPath = nil
                } else if selectedContainer?.kind == .project {
                    updated.projectPath = selectedContainer?.path
                    updated.workspacePath = nil
                }
                origins[.container] = .saved
            } else {
                let choice = selector.container(from: discovery, root: root)
                guard let container = choice.selected else {
                    return setupResult(
                        updated,
                        discovery,
                        origins,
                        nil,
                        containerResolution(choice.choices, root: root),
                        notes
                    )
                }
                selectedContainer = container
                apply(container, to: &updated)
                origins[.container] = .automatic
            }
        } catch {
            return setupResult(
                updated,
                discovery,
                origins,
                nil,
                containerResolution(
                    discovery.containers,
                    root: root,
                    details: error.localizedDescription
                ),
                notes
            )
        }

        guard let selectedContainer else {
            return setupResult(updated, discovery, origins, nil, nil, notes)
        }
        if selectedContainer.kind == .package {
            let analysis = try PackageAnalyzer().analyze(
                manifestURL: URL(fileURLWithPath: selectedContainer.path)
            )
            let contexts = packageContexts(analysis.metadata.minimumPlatforms)
            let availableContexts = contexts.isEmpty ? [
                TUIAutomaticSetupSelector.SDKContext(
                    identifier: "macosx",
                    destination: "platform=macOS",
                    detail: "macOS"
                ),
            ] : contexts
            if updated.buildConfiguration == nil {
                updated.buildConfiguration = "Debug"
                origins[.buildConfiguration] = .automatic
            }
            let hasExplicitPlatform = !updated.sdkIdentifiers.isEmpty
                && updated.destination != nil
                && origins[.sdk] == .saved
                && origins[.destination] == .saved
            if requestedField == .sdk || !hasExplicitPlatform {
                return setupResult(
                    updated,
                    discovery,
                    origins,
                    selectedContainer,
                    sdkResolution(
                        availableContexts,
                        message:
                            "Choose the Apple platform context for this package."
                    ),
                    notes
                )
            }
            updated.setupValueOrigins = encodedOrigins(origins)
            return setupResult(
                updated, discovery, origins, selectedContainer, nil, notes
            )
        }

        guard let xcodePath = updated.candidateXcodePath
                ?? updated.baselineXcodePath
        else {
            return setupResult(
                updated, discovery, origins, selectedContainer, nil, notes
            )
        }
        let developer = try XcodeInstallation.validate(applicationPath: xcodePath)
        let details = try progress.phase(
            "Inspecting shared schemes",
            completedMessage: "Inspected shared schemes"
        ) {
            try XcodeContainerInspector(runner: runner).inspect(
                selectedContainer,
                developerDirectory: developer,
                timeout: min(workflow.doctorTimeout, 30)
            )
        }
        if requestedField == .scheme {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                schemeResolution(details.schemes),
                notes
            )
        }

        let scheme: String
        if let configured = configuration.defaultScheme {
            guard details.schemes.contains(configured) else {
                return setupResult(
                    updated,
                    discovery,
                    origins,
                    selectedContainer,
                    schemeResolution(
                        details.schemes,
                        message:
                            "The saved scheme '\(configured)' is unavailable."
                    ),
                    notes
                )
            }
            scheme = configured
            updated.scheme = configured
            origins[.scheme] = origins[.scheme] ?? .saved
        } else {
            let choice = selector.scheme(
                available: details.schemes,
                container: selectedContainer,
                targets: details.targets
            )
            guard let selected = choice.selected else {
                return setupResult(
                    updated,
                    discovery,
                    origins,
                    selectedContainer,
                    schemeResolution(choice.ordered),
                    notes
                )
            }
            scheme = selected
            updated.scheme = selected
            origins[.scheme] = .automatic
        }

        if let configured = updated.buildConfiguration {
            if !details.configurations.contains(configured) {
                return setupResult(
                    updated,
                    discovery,
                    origins,
                    selectedContainer,
                    configurationResolution(details.configurations),
                    notes
                )
            }
        } else if details.configurations.count == 1 {
            updated.buildConfiguration = details.configurations[0]
            origins[.buildConfiguration] = .automatic
        } else {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                configurationResolution(
                    details.configurations,
                    message:
                        "Choose the build configuration for Doctor and analysis."
                ),
                notes
            )
        }
        if requestedField == .buildConfiguration {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                configurationResolution(
                    details.configurations,
                    message:
                        "Choose the build configuration for Doctor and analysis."
                ),
                notes
            )
        }

        let snapshots = try progress.phase(
            "Inspecting build settings for \(scheme)",
            completedMessage: "Inspected build settings for \(scheme)"
        ) {
            try XcodeBuildSettingsProvider(runner: runner).showBuildSettings(
                container: selectedContainer,
                scheme: scheme,
                configuration: updated.buildConfiguration,
                developerDirectory: developer,
                timeout: workflow.doctorTimeout
            )
        }
        let contexts = selector.sdkContexts(from: snapshots)
        let hasExplicitPlatform = !updated.sdkIdentifiers.isEmpty
            && updated.destination != nil
            && origins[.sdk] == .saved
            && origins[.destination] == .saved
        if requestedField == .sdk || !hasExplicitPlatform {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                sdkResolution(
                    contexts,
                    message:
                        "Choose the platform context to validate and analyze."
                ),
                notes
            )
        } else if let identifier = updated.sdkIdentifiers.first,
                  let context = contexts.first(where: {
                      $0.identifier == identifier
                          && $0.destination == updated.destination
                  })
        {
            _ = context
        } else {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                sdkResolution(contexts),
                notes
            )
        }
        do {
            try BuildContextSelectionValidator.validate(
                sdkIdentifiers: updated.sdkIdentifiers,
                destination: updated.destination
            )
        } catch {
            return setupResult(
                updated,
                discovery,
                origins,
                selectedContainer,
                sdkResolution(
                    contexts,
                    message:
                        "The saved SDK and destination do not describe the same build context.",
                    details: error.localizedDescription
                ),
                notes
            )
        }
        updated.setupValueOrigins = encodedOrigins(origins)
        notes.append(
            "Selected \(scheme), \(updated.sdkIdentifiers.joined(separator: ", ")), "
                + "\(updated.destination ?? "default destination")."
        )
        return setupResult(
            updated, discovery, origins, selectedContainer, nil, notes
        )
    }

    func selectXcodes(
        _ applications: [String],
        workflow: inout TUIWorkflowSettings,
        origins: inout [TUISetupField: TUISetupValueOrigin],
        requestedField: TUISetupField? = nil
    ) -> TUISetupResolution? {
        let candidates = applications
            + [workflow.baselineXcodePath, workflow.candidateXcodePath]
                .compactMap { $0 }
        let valid = candidates.filter {
            (try? XcodeInstallation.validate(applicationPath: $0)) != nil
        }.reduce(into: [String]()) { result, path in
            if !result.contains(where: { samePath($0, path) }) {
                result.append(path)
            }
        }
        let baselineValid = workflow.baselineXcodePath.flatMap { selected in
            valid.first { samePath($0, selected) }
        }.flatMap { origins[.baselineXcode] == .saved ? $0 : nil }
        let candidateValid = workflow.candidateXcodePath.flatMap { selected in
            valid.first { samePath($0, selected) }
        }.flatMap { origins[.candidateXcode] == .saved ? $0 : nil }
        if let baselineValid {
            workflow.baselineXcodePath = baselineValid
            origins[.baselineXcode] = origins[.baselineXcode] ?? .saved
        }
        if let candidateValid {
            workflow.candidateXcodePath = candidateValid
            origins[.candidateXcode] = origins[.candidateXcode] ?? .saved
        }
        if requestedField == .baselineXcode {
            return xcodeResolution(
                field: .baselineXcode,
                valid: valid,
                excluded: candidateValid,
                workflow: workflow,
                message: "Choose the baseline Xcode explicitly."
            )
        }
        if requestedField == .candidateXcode {
            return xcodeResolution(
                field: .candidateXcode,
                valid: valid,
                excluded: baselineValid,
                workflow: workflow,
                message: "Choose the candidate Xcode explicitly."
            )
        }
        if let baselineValid, let candidateValid {
            if samePath(baselineValid, candidateValid)
                || xcodeIdentity(baselineValid) == xcodeIdentity(candidateValid)
            {
                return xcodeResolution(
                    field: .candidateXcode,
                    valid: valid,
                    excluded: baselineValid,
                    workflow: workflow,
                    message:
                        "Baseline and candidate must have distinct Xcode versions or build numbers."
                )
            }
            return nil
        }
        if workflow.baselineXcodePath != nil,
           origins[.baselineXcode] == .saved,
           baselineValid == nil
        {
            return xcodeResolution(
                field: .baselineXcode,
                valid: valid,
                excluded: candidateValid,
                workflow: workflow,
                message: "The saved baseline Xcode is no longer available."
            )
        }
        if workflow.candidateXcodePath != nil,
           origins[.candidateXcode] == .saved,
           candidateValid == nil
        {
            return xcodeResolution(
                field: .candidateXcode,
                valid: valid,
                excluded: baselineValid,
                workflow: workflow,
                message: "The saved candidate Xcode is no longer available."
            )
        }
        let field: TUISetupField = baselineValid == nil
            ? .baselineXcode : .candidateXcode
        let excluded = field == .baselineXcode ? candidateValid : baselineValid
        return xcodeResolution(
            field: field,
            valid: valid,
            excluded: excluded,
            workflow: workflow,
            message: valid.isEmpty
                ? "No valid Xcode installation was found automatically."
                : "Choose the \(field == .baselineXcode ? "baseline" : "candidate") Xcode explicitly."
        )
    }

    private func xcodeResolution(
        field: TUISetupField,
        valid: [String],
        excluded: String?,
        workflow: TUIWorkflowSettings,
        message: String
    ) -> TUISetupResolution {
        let choices = valid.map { path in
            let conflictsWithOtherRole = excluded.map {
                samePath(path, $0)
                    || xcodeIdentity(path) == xcodeIdentity($0)
            } ?? false
            let identity = xcodeDisplayIdentity(path)
            let roles = [
                workflow.baselineXcodePath.flatMap { selected in
                    samePath(path, selected) ? "selected as baseline" : nil
                },
                workflow.candidateXcodePath.flatMap { selected in
                    samePath(path, selected) ? "selected as candidate" : nil
                },
            ].compactMap { $0 }
            let sdkSummary = installedSDKSummary(path)
            let availability = conflictsWithOtherRole
                ? "unavailable for this role" : ""
            return TUISetupChoice(
                label: identity,
                detail: ([path, sdkSummary] + roles + [availability])
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                value: field == .baselineXcode
                    ? .baselineXcode(path) : .candidateXcode(path),
                recommended: false,
                enabled: !conflictsWithOtherRole
            )
        } + [
            TUISetupChoice(
                label: "Other Xcode…",
                detail:
                    "Enter a path only when the required installation is not listed.",
                value: .manual(
                    field == .baselineXcode
                        ? .baselineXcode : .candidateXcode
                ),
                recommended: false
            ),
        ]
        return TUISetupResolution(
            field: field,
            title: field == .baselineXcode
                ? "Choose baseline Xcode" : "Choose candidate Xcode",
            message: message,
            choices: choices,
            technicalDetails:
                "SwiftDelta found \(valid.count) valid Xcode installation(s). "
                + "Baseline and candidate must be different selections."
        )
    }

    private func containerResolution(
        _ containers: [ProjectContainer],
        root: URL,
        details: String? = nil
    ) -> TUISetupResolution {
        var choices = containers.map { container in
            let value: TUISetupChoiceValue
            switch container.kind {
            case .project:
                value = .project(container.path)
            case .workspace:
                value = .workspace(container.path)
            case .package:
                value = .packageRoot(
                    URL(fileURLWithPath: container.path)
                        .deletingLastPathComponent().path
                )
            }
            return TUISetupChoice(
                label: URL(fileURLWithPath: container.path).lastPathComponent,
                detail: container.kind == .package
                    ? "Swift Package" : container.kind.rawValue.capitalized,
                value: value,
                recommended: false
            )
        }
        choices.append(contentsOf: [
            TUISetupChoice(
                label: "Enter a project path",
                detail: "Enter a .xcodeproj path inside the selected root.",
                value: .manual(.projectPath),
                recommended: false
            ),
            TUISetupChoice(
                label: "Enter a workspace path",
                detail: "Enter a .xcworkspace path inside the selected root.",
                value: .manual(.workspacePath),
                recommended: false
            ),
            TUISetupChoice(
                label: "Choose another project root",
                detail: "Enter another directory to discover.",
                value: .manual(.projectRoot),
                recommended: false
            ),
        ])
        return TUISetupResolution(
            field: .container,
            title: "Choose project container",
            message: containers.isEmpty
                ? "No Swift Package, Xcode project, or workspace was found."
                : "Several unrelated containers are available. Choose the one to analyze.",
            choices: choices,
            technicalDetails: details
                ?? "Project root: \(root.path)\n"
                + containers.map { "\($0.kind.rawValue): \($0.path)" }
                    .joined(separator: "\n")
        )
    }

    private func schemeResolution(
        _ schemes: [String],
        message: String =
            "Several schemes are equally suitable. Choose the scheme whose targets should be analyzed."
    ) -> TUISetupResolution {
        return TUISetupResolution(
            field: .scheme,
            title: "Choose shared scheme",
            message: message,
            choices: schemes.map {
                TUISetupChoice(
                    label: $0,
                    detail: "Shared Xcode scheme",
                    value: .scheme($0),
                    recommended: false
                )
            } + [
                TUISetupChoice(
                    label: "Enter another scheme",
                    detail: "Enter a shared scheme name.",
                    value: .manual(.scheme),
                    recommended: false
                ),
            ],
            technicalDetails: "Available schemes: \(schemes.joined(separator: ", "))"
        )
    }

    private func configurationResolution(
        _ configurations: [String],
        message: String = "The saved build configuration is unavailable."
    ) -> TUISetupResolution {
        let ordered = configurations.sorted {
            if $0 == "Debug" { return true }
            if $1 == "Debug" { return false }
            return $0 < $1
        }
        return TUISetupResolution(
            field: .buildConfiguration,
            title: "Choose build configuration",
            message: message,
            choices: ordered.map {
                TUISetupChoice(
                    label: $0,
                    detail: "Available build configuration",
                    value: .buildConfiguration($0),
                    recommended: $0 == "Debug"
                )
            },
            technicalDetails:
                "Available configurations: \(configurations.joined(separator: ", "))"
        )
    }

    private func sdkResolution(
        _ contexts: [TUIAutomaticSetupSelector.SDKContext],
        message: String =
            "The project has more than one material platform context. Choose the one to analyze.",
        details: String? = nil
    ) -> TUISetupResolution {
        TUISetupResolution(
            field: .sdk,
            title: "Choose platform context",
            message: message,
            choices: contexts.map {
                TUISetupChoice(
                    label: $0.label,
                    detail: "\($0.identifier) · \($0.destination)",
                    value: .sdk(
                        identifier: $0.identifier,
                        destination: $0.destination
                    ),
                    recommended: $0.identifier == "iphoneos"
                )
            },
            technicalDetails: details ?? contexts.map {
                "\($0.identifier): \($0.destination)"
            }.joined(separator: "\n")
        )
    }

    private func packageContexts(
        _ platforms: [String: String]
    ) -> [TUIAutomaticSetupSelector.SDKContext] {
        platforms.keys.sorted().compactMap { platform in
            let identifier = switch platform.lowercased() {
            case "ios": "iphoneos"
            case "macos": "macosx"
            case "tvos": "appletvos"
            case "watchos": "watchos"
            case "visionos": "xros"
            default: ""
            }
            guard !identifier.isEmpty else { return nil }
            return TUIAutomaticSetupSelector().sdkContexts(
                from: [BuildSettingsSnapshot(settings: [
                    "SUPPORTED_PLATFORMS": identifier,
                ])]
            ).first
        }
    }

    private func apply(
        _ container: ProjectContainer,
        to workflow: inout TUIWorkflowSettings
    ) {
        switch container.kind {
        case .project:
            workflow.projectPath = container.path
            workflow.workspacePath = nil
        case .workspace:
            workflow.workspacePath = container.path
            workflow.projectPath = nil
        case .package:
            workflow.workspacePath = nil
            workflow.projectPath = nil
        }
    }

    private func apply(
        _ context: TUIAutomaticSetupSelector.SDKContext,
        to workflow: inout TUIWorkflowSettings
    ) {
        workflow.sdkIdentifiers = [context.identifier]
        workflow.destination = context.destination
    }

    private func setupResult(
        _ workflow: TUIWorkflowSettings,
        _ discovery: DiscoveryResult,
        _ origins: [TUISetupField: TUISetupValueOrigin],
        _ container: ProjectContainer?,
        _ resolution: TUISetupResolution?,
        _ notes: [String]
    ) -> TUIAutomaticSetupResult {
        var value = workflow
        value.setupValueOrigins = encodedOrigins(origins)
        return TUIAutomaticSetupResult(
            workflow: value,
            discovery: discovery,
            origins: origins,
            selectedContainer: container,
            resolution: resolution,
            notes: notes
        )
    }

    private func decodedOrigins(
        _ workflow: TUIWorkflowSettings
    ) -> [TUISetupField: TUISetupValueOrigin] {
        (workflow.setupValueOrigins ?? [:]).reduce(into: [:]) {
            guard let field = TUISetupField(rawValue: $1.key) else { return }
            $0[field] = $1.value
        }
    }

    private func encodedOrigins(
        _ values: [TUISetupField: TUISetupValueOrigin]
    ) -> [String: TUISetupValueOrigin] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    private func samePath(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: right).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func xcodeIdentity(_ path: String) -> String {
        let info = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info, options: [.mappedIfSafe]),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any]
        else {
            return path
        }
        return [
            values["CFBundleShortVersionString"] as? String,
            values["DTXcodeBuild"] as? String
                ?? values["CFBundleVersion"] as? String,
        ].compactMap { $0 }.joined(separator: "|")
    }

    private func xcodeDisplayIdentity(_ path: String) -> String {
        let components = xcodeIdentity(path).split(separator: "|")
        guard components.count == 2 else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "Xcode \(components[0]) (\(components[1]))"
    }

    private func installedSDKSummary(_ path: String) -> String {
        let root = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Developer/Platforms")
        guard let platforms = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return "SDK versions unavailable"
        }
        let names = platforms.flatMap { platform -> [String] in
            let sdkRoot = platform.appendingPathComponent("Developer/SDKs")
            return (
                try? FileManager.default.contentsOfDirectory(
                    at: sdkRoot,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            )?.filter {
                $0.pathExtension == "sdk"
            }.map {
                $0.deletingPathExtension().lastPathComponent
            } ?? []
        }
        let unique = Array(Set(names)).sorted()
        return unique.isEmpty
            ? "No Apple SDKs found"
            : "SDKs: \(unique.joined(separator: ", "))"
    }
}
