//===--- URLContainment.swift - SwiftDelta ------------------------------------------===//
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

extension URL {
    /// A stable filesystem identity used when paths may pass through aliases
    /// such as macOS's `/tmp` and `/private/tmp` spellings.
    var canonicalFileURL: URL {
        standardizedFileURL.resolvingSymlinksInPath()
    }

    var canonicalPath: String {
        canonicalFileURL.path
    }

    func isContained(in root: URL) -> Bool {
        let candidateComponents = canonicalFileURL.pathComponents
        let rootComponents = root.canonicalFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
