//===--- ProjectModels.swift - SwiftDelta ------------------------------------------===//
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

public enum ProjectContainerKind: String, Codable, Sendable {
    case package
    case project
    case workspace
}

public struct ProjectContainer: Codable, Hashable, Sendable {
    public let kind: ProjectContainerKind
    public let path: String

    public init(kind: ProjectContainerKind, path: String) {
        self.kind = kind
        self.path = path
    }
}

public struct DiscoveryResult: Codable, Sendable {
    public let root: String
    public let containers: [ProjectContainer]
    public let swiftFiles: [String]

    public init(root: String, containers: [ProjectContainer], swiftFiles: [String]) {
        self.root = root
        self.containers = containers
        self.swiftFiles = swiftFiles
    }
}

public struct ProjectDetails: Codable, Sendable {
    public let container: ProjectContainer
    public let schemes: [String]
    public let targets: [String]
    public let configurations: [String]

    public init(
        container: ProjectContainer,
        schemes: [String],
        targets: [String],
        configurations: [String]
    ) {
        self.container = container
        self.schemes = schemes
        self.targets = targets
        self.configurations = configurations
    }
}
