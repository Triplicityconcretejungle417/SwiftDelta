//===--- ArgumentListAssertions.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import XCTest

func argumentValue(after option: String, in arguments: [String]) throws -> String {
    let index = try XCTUnwrap(arguments.firstIndex(of: option))
    return arguments[index + 1]
}
