import Darwin

/// The password `--password-stdin` gives. On a terminal it asks for it, with the typing hidden;
/// otherwise it reads the first line, as `echo "$PW" | pdf add paper.pdf --password-stdin`
/// pipes it in.
enum Password {
    static func read(for file: String) -> String? {
        guard isatty(STDIN_FILENO) != 0 else {
            return readLine(strippingNewline: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard readpassphrase("Password for \(file): ", &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
        let typed = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: typed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
