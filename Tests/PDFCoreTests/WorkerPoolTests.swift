import Foundation
import Testing
@testable import PDFCore

@Suite struct WorkerPoolTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-cli-pool-\(UUID())")

    @Test func thePoolHoldsNoMoreThanItsSize() throws {
        let first = try #require(WorkerPool.acquire(foreground: true, size: 2, directory: folder))
        let second = try #require(WorkerPool.acquire(foreground: true, size: 2, directory: folder))
        #expect(Set([first.number, second.number]) == [0, 1])
        #expect(WorkerPool.acquire(foreground: true, size: 2, directory: folder) == nil)
        second.release()
        #expect(WorkerPool.acquire(foreground: true, size: 2, directory: folder)?.number == 1)
    }

    @Test func pagesNobodyWaitsForLeaveTheFirstSlotFree() throws {
        let background = try #require(WorkerPool.acquire(foreground: false, size: 2, directory: folder))
        #expect(background.number == 1)
        #expect(WorkerPool.acquire(foreground: false, size: 2, directory: folder) == nil)
        #expect(WorkerPool.acquire(foreground: true, size: 2, directory: folder)?.number == 0)
    }

    @Test func aPoolOfOneServesBoth() throws {
        let background = try #require(WorkerPool.acquire(foreground: false, size: 1, directory: folder))
        #expect(background.number == 0)
        #expect(WorkerPool.acquire(foreground: true, size: 1, directory: folder) == nil)
    }

    @Test func aSlotFreedFromMemoryGoesBack() throws {
        do {
            let slot = try #require(WorkerPool.acquire(foreground: true, size: 1, directory: folder))
            #expect(slot.number == 0)
        }
        #expect(WorkerPool.acquire(foreground: true, size: 1, directory: folder) != nil)
    }

    @Test func aPoolOfOneLetsPagesNobodyWaitsForYieldToACommandThatWaits() throws {
        // Nobody waits: background work takes the one slot.
        let background = try #require(WorkerPool.acquire(foreground: false, size: 1, directory: folder))
        // A command that waits fails to get it, and says so.
        #expect(WorkerPool.acquire(foreground: true, size: 1, directory: folder) == nil)
        #expect(WorkerPool.foregroundWaiting(directory: folder))
        background.release()
        // The slot is free, but background work stays out while a command waits: it cannot retake the slot.
        #expect(WorkerPool.acquire(foreground: false, size: 1, directory: folder) == nil)
        // A process another test spawns at this moment may hold the released slot until it execs.
        var taken: WorkerPool.Slot?
        for _ in 0..<100 where taken == nil {
            taken = WorkerPool.acquire(foreground: true, size: 1, directory: folder)
            if taken == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        try #require(taken).release()
        // The mark expires by itself, so a command that went away does not hold background work back.
        #expect(!WorkerPool.foregroundWaiting(directory: folder, now: Date().addingTimeInterval(WorkerPool.waitingWindow + 0.1)))
        // A pool of two keeps slot 0 for commands without any mark, as before.
        #expect(WorkerPool.acquire(foreground: false, size: 2, directory: folder)?.number == 1)
    }
}
