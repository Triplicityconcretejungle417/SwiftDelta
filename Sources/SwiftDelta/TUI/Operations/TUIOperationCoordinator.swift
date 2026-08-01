//===--- TUIOperationCoordinator.swift - SwiftDelta ------------------------------------------===//
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

enum TUIOperationEvent: Sendable {
    case started(TUIOperationKind, Date)
    case progress(TUIOperationProgressUpdate)
    case completed(TUIOperationKind, TUIOperationResult)
    case failed(TUIOperationKind, String, String)
    case cancelled(TUIOperationKind)
}

final class TUIOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false

    func cancel() {
        lock.withLock {
            cancelled = true
            paused = false
        }
    }

    func reset() {
        lock.withLock {
            cancelled = false
            paused = false
        }
    }

    func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }

    func togglePause() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            paused.toggle()
            return paused
        }
    }

    func isPaused() -> Bool {
        lock.withLock { paused }
    }
}

final class TUIOperationCoordinator: @unchecked Sendable {
    private let service: any TUIOperationServing
    private let queue = DispatchQueue(
        label: "org.swiftdelta.tui.operations",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let cancellation = TUIOperationCancellation()
    private var events: [TUIOperationEvent] = []
    private var activeKind: TUIOperationKind?

    init(service: any TUIOperationServing = CoreTUIOperationService()) {
        self.service = service
    }

    func start(
        _ kind: TUIOperationKind,
        request: TUIOperationRequest
    ) -> Bool {
        let accepted = lock.withLock {
            guard activeKind == nil else { return false }
            activeKind = kind
            return true
        }
        guard accepted else { return false }
        cancellation.reset()
        append(.started(kind, Date()))
        queue.async { [self] in
            do {
                let result = try service.perform(
                    kind,
                    request: request,
                    cancellation: { self.cancellation.isCancelled() },
                    pauseRequested: { self.cancellation.isPaused() },
                    progress: { self.append(.progress($0)) }
                )
                if cancellation.isCancelled() {
                    append(.cancelled(kind))
                } else {
                    append(.completed(kind, result))
                }
            } catch {
                if cancellation.isCancelled() {
                    append(.cancelled(kind))
                } else {
                    append(
                        .failed(
                            kind,
                            error.localizedDescription,
                            error.localizedDescription
                        )
                    )
                }
            }
            lock.withLock {
                activeKind = nil
            }
        }
        return true
    }

    func cancel() {
        cancellation.cancel()
    }

    func togglePause() -> Bool {
        cancellation.togglePause()
    }

    func isPaused() -> Bool {
        cancellation.isPaused()
    }

    func drainEvents() -> [TUIOperationEvent] {
        lock.withLock {
            let result = events
            events.removeAll(keepingCapacity: true)
            return result
        }
    }

    func isRunning() -> Bool {
        lock.withLock { activeKind != nil }
    }

    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isRunning()
    }

    private func append(_ event: TUIOperationEvent) {
        lock.withLock {
            events.append(event)
        }
    }
}
