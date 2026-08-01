//===--- TUIApplication.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
import SwiftDeltaCore

final class TUIApplication {
    private let launch: LaunchOptions
    private let settingsStore: TUISettingsStore
    private let coordinator: TUIOperationCoordinator

    init(
        launch: LaunchOptions,
        settingsStore: TUISettingsStore = TUISettingsStore(),
        service: any TUIOperationServing = CoreTUIOperationService()
    ) {
        self.launch = launch
        self.settingsStore = settingsStore
        coordinator = TUIOperationCoordinator(service: service)
    }

    func run() throws -> Int32 {
        guard TerminalSession.isInteractive() else {
            throw LaunchError(
                "SwiftDelta requires an interactive terminal or PTY. "
                    + "Use swiftdelta --help for launch information."
            )
        }
        let loaded = settingsStore.loadSettings(safeMode: launch.safeMode)
        var settings = loaded.settings
        if let projectPath = launch.projectPath {
            settings.workflow.projectRoot = projectPath
        }
        let historyResult = settingsStore.loadHistory(
            enabled: settings.interaction.historyEnabled,
            safeMode: launch.safeMode
        )
        let warning = [loaded.warning, historyResult.warning]
            .compactMap { $0 }
            .joined(separator: "\n")
        var initialState = TUIState(
            settings: settings,
            history: historyResult.history,
            safeMode: launch.safeMode,
            settingsWarning: warning.isEmpty ? nil : warning,
            foundationModelStatus: OnDeviceFoundationModelStatus.current()
        )
        if launch.projectPath != nil {
            initialState.screen = .project
            initialState.projectWasExplicitlySelected = true
            initialState.advanceAfterSetup = true
        }
        if let warning = initialState.settingsWarning {
            initialState.overlay = .message(
                title: "Stored state was not loaded",
                message: warning,
                details: "The stored files were not deleted or modified."
            )
        }
        let controller = TUIController(
            state: initialState,
            settingsStore: settingsStore,
            coordinator: coordinator,
            foundationModelStatusProvider: {
                OnDeviceFoundationModelStatus.current()
            }
        )
        let terminal = TerminalSession(
            mouseEnabled:
                settings.interaction.mouseEnabled
                    && controller.capabilities.mouseSupported
        )
        try terminal.open()
        defer {
            controller.cancelAndWaitForExit()
            terminal.close()
        }
        if launch.projectPath != nil {
            controller.start(.automaticSetup)
        }
        let renderer = DifferentialTerminalRenderer()
        let theme = TerminalTheme()
        var previousSize = TerminalSize(columns: 0, rows: 0)
        while !controller.state.shouldQuit {
            controller.consumeOperationEvents()
            let size = terminal.size()
            let resized = size != previousSize
            if resized {
                renderer.invalidate()
                previousSize = size
                controller.handleResize(size)
            }
            let screen = TUIScreenRenderer(
                theme: theme,
                capabilities: controller.capabilities
            ).render(controller.state, size: size)
            renderer.render(
                screen,
                theme: theme,
                capabilities: controller.capabilities,
                force: resized
            )
            if let key = try terminal.readKey(timeoutMilliseconds: 100) {
                controller.handle(key, terminalSize: size)
            }
        }
        return 0
    }
}
