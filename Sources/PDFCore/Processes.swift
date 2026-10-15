import Darwin
import Foundation

struct SpawnError: Error, CustomStringConvertible {
    let code: Int32
    var description: String { "could not start a process: \(String(cString: strerror(code)))" }
}

/// Starting, watching and stopping the tool's own child processes.
enum Processes {
    /// Starts `executable`. A detached process gets its own session, so it keeps running after
    /// the command that started it returns. With `captureOutput`, the child's standard output
    /// comes back as a readable file descriptor. The child inherits no other open files.
    static func spawn(_ executable: String, _ arguments: [String],
                      detached: Bool, captureOutput: Bool) throws -> (pid: pid_t, output: Int32?) {
        var pipeEnds: [Int32] = [-1, -1]
        if captureOutput {
            guard pipe(&pipeEnds) == 0 else { throw SpawnError(code: errno) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if captureOutput {
            posix_spawn_file_actions_adddup2(&actions, pipeEnds[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if detached { flags |= Int32(POSIX_SPAWN_SETSID) }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environment)
        if captureOutput { close(pipeEnds[1]) }
        guard result == 0 else {
            if captureOutput { close(pipeEnds[0]) }
            throw SpawnError(code: result)
        }
        return (pid, captureOutput ? pipeEnds[0] : nil)
    }

    /// The memory a process holds, as Activity Monitor counts it.
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// Collects a child that has exited, without waiting. Returns its wait status.
    static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid ? status : nil
    }

    /// Describes how a child ended, from its wait status.
    static func describe(status: Int32) -> String {
        let signal = status & 0x7f
        if signal == 0 { return "exited with code \((status >> 8) & 0xff)" }
        return "stopped by signal \(signal)"
    }

    static func exitedCleanly(status: Int32) -> Bool { status == 0 }
}

/// Reads a child's standard output on a thread of its own, one line at a time.
final class LineReader: @unchecked Sendable {
    private let descriptor: Int32
    private let onLine: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void

    init(descriptor: Int32, onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor
        self.onLine = onLine
        self.onEnd = onEnd
    }

    func start() {
        let thread = Thread { [self] in self.loop() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func loop() {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(descriptor)
        onEnd()
    }
}
