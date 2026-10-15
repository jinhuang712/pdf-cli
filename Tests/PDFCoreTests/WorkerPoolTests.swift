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
}
