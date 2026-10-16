import Darwin

/// The password `--password-stdin` gives, as typed, spaces included. On a terminal it asks for it,
/// with the typing hidden; otherwise it reads the first line, as
/// `echo "$PW" | pdf add paper.pdf --password-stdin` pipes it in.
enum Password {
    static func read(for file: String) -> String? {
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine(strippingNewline: true).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }
        return ask("Password for \(file): ")
    }

    /// The terminal and its settings while the typing is hidden, for the signal handler.
    nonisolated(unsafe) private static var terminal: Int32 = -1
    nonisolated(unsafe) private static var settings = termios()
    private static let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    /// Asks on the terminal with the typing hidden. A command runs off the main thread, where a
    /// signal lands, so Ctrl-C could not interrupt the read, and readpassphrase waited for Enter:
    /// here the handler puts the terminal back and ends the command at once. Nil at the end of
    /// input with nothing typed, as after Ctrl-D.
    private static func ask(_ prompt: String) -> String? {
        let tty = open("/dev/tty", O_RDWR)
        guard tty >= 0 else { return nil }
        defer { close(tty) }
        var shown = termios()
        guard tcgetattr(tty, &shown) == 0 else { return nil }
        (terminal, settings) = (tty, shown)
        let previous = signals.map { number in
            signal(number) { number in
                _ = tcsetattr(Password.terminal, TCSAFLUSH, &Password.settings)
                _ = write(Password.terminal, "\n", 1)
                _exit(128 + number)
            }
        }
        var hidden = shown
        hidden.c_lflag &= ~tcflag_t(ECHO)
        _ = write(tty, prompt, prompt.utf8.count)
        _ = tcsetattr(tty, TCSAFLUSH, &hidden)
        var typed: [UInt8] = []
        var byte: UInt8 = 0
        var ended = true
        while Darwin.read(tty, &byte, 1) == 1 {
            if byte == 0x0A || byte == 0x0D {
                ended = false
                break
            }
            if typed.count < 4_096 { typed.append(byte) }
        }
        _ = tcsetattr(tty, TCSAFLUSH, &shown)
        _ = write(tty, "\n", 1)
        for (number, handler) in zip(signals, previous) { signal(number, handler) }
        defer { typed.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return ended && typed.isEmpty ? nil : String(decoding: typed, as: UTF8.self)
    }
}
