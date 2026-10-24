import CoreGraphics
import Foundation

/// Writes what a PDF carries to files (FEATURES.md → F6). Attachments and scripts are copied out
/// of their streams as bytes and text and never opened, run or launched (DESIGNS.md → Principles →
/// Safety): a file never gets an executable mode, and a name from the PDF never picks the folder
/// it lands in.
public enum Dump {
    /// A file written, or an item left out and why.
    public struct Item: Codable, Equatable, Sendable {
        public var kind: String
        public var path: String?
        public var page: Int?
        public var detail: String
        public var skipped: String?
    }

    /// The most files and bytes one dump writes, and the memory and time its reader may take.
    static let maxFiles = 1_000
    static let maxBytes = 1 << 30

    /// A name safe to use in a folder: the PDF's name cut to its last component, with control and
    /// format characters, leading dots and spaces, and anything past 200 bytes of UTF-8 dropped, and a
    /// number added when the name is taken (APFS treats names alike that differ in case or form).
    public static func safeName(_ name: String, fallback: String, taken: inout Set<String>) -> String {
        var base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let unsafe: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned]
        base = String(base.unicodeScalars.filter { !unsafe.contains($0.properties.generalCategory) })
        base = String(base.drop { $0 == "." || $0.isWhitespace })
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallback }
        let ext = (base as NSString).pathExtension
        let suffix = ext.utf8.count <= 12 && !ext.isEmpty ? "." + ext : ""
        var stem = suffix.isEmpty ? base : String(base.dropLast(suffix.count))
        func fit(_ stem: String, _ number: String) -> String {
            var stem = stem
            while (stem + number + suffix).utf8.count > 200, !stem.isEmpty { stem.removeLast() }
            return (stem.isEmpty ? "file" : stem) + number + suffix
        }
        stem = String(stem)
        var candidate = fit(stem, "")
        var number = 2
        func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
        while taken.contains(key(candidate)) {
            candidate = fit(stem, "-\(number)")
            number += 1
        }
        taken.insert(key(candidate))
        return candidate
    }

    /// Saves the attachments and the scripts of the file into `folder/attachments` and
    /// `folder/scripts`, in this process. Only what was asked for is decoded or written. `pdf dump`
    /// runs it in a worker (`supervised`), which a file that exhausts memory cannot take down with it.
    public static func payloads(path: String, folder: URL, attachments: Bool, scripts: Bool) throws -> [Item] {
        let url = URL(fileURLWithPath: path)
        guard let document = CGPDFDocument(url as CFURL) else { throw DumpError(description: OpenFailure.classify(url: url), fileFailed: true) }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("") || document.unlockWithPassword(Env.password)
        }
        guard document.isUnlocked else { throw DumpError(description: OpenFailure.locked, fileFailed: true) }
        var items: [Item] = []
        var names = (attachments: Set<String>(), scripts: Set<String>())
        var files = 0, bytes = 0
        var capped = false
        let quarantine = readQuarantine(of: url)
        _ = FactReader.read(document, url: url, attachments: attachments, scripts: scripts) { payload in
            guard !capped else { return }
            let kind: String, name: String, sub: String, page: Int?, data: Data?, skipped: String?, detail: String
            switch payload {
            case .attachment(let n, let p, let d, let s):
                kind = "attachment"; sub = "attachments"; page = p; data = d; skipped = s
                name = safeName(n, fallback: "attachment", taken: &names.attachments); detail = name
            case .script(let trigger, let k, let p, let text, let s):
                let stem = "\(k.lowercased())-\(names.scripts.count + 1)"
                kind = "script"; sub = "scripts"; page = p; skipped = s; detail = trigger
                name = safeName(stem + (k == "JavaScript" ? ".js.txt" : ".txt"), fallback: stem, taken: &names.scripts)
                let header = "// \(k) on \(trigger)" + (p.map { ", p.\($0 + 1)" } ?? "") + "; saved as text by pdf dump, never run\n"
                data = text.map { Data((header + $0).utf8) }
            }
            guard let data else {
                items.append(Item(kind: kind, path: nil, page: page, detail: detail, skipped: skipped))
                return
            }
            if files >= maxFiles || bytes + data.count > maxBytes {
                capped = true
                items.append(Item(kind: kind, path: nil, page: page, detail: detail,
                                  skipped: "the dump reached its limit of \(maxFiles) files or \(maxBytes >> 20) MB; the rest was left"))
                return
            }
            do {
                let target = try write(data, as: name, in: folder, sub: sub, quarantine: quarantine)
                files += 1
                bytes += data.count
                items.append(Item(kind: kind, path: target.path, page: page, detail: kind == "attachment" ? "\(data.count) bytes" : detail, skipped: nil))
            } catch {
                items.append(Item(kind: kind, path: nil, page: page, detail: detail, skipped: "\(error)"))
            }
        }
        return items
    }

    /// Runs `payloads` in a worker, within the pool's time and memory limits. Items the worker
    /// wrote before it was stopped are found in the folder and listed with the reason it stopped.
    public static func supervised(path: String, folder: URL, attachments: Bool, scripts: Bool, password: String?) throws -> [Item] {
        var arguments = ["__worker", "dump", path, "--out", folder.path]
        if attachments { arguments.append("--attachments") }
        if scripts { arguments.append("--scripts") }
        do {
            let event = try Crop.runWorker(arguments, environment: password.map { [Env.passwordVariable: $0] } ?? [:])
            if let reason = event?.reason { throw DumpError(description: reason, fileFailed: true) }
            guard let text = event?.text, let items = try? JSONDecoder().decode([Item].self, from: Data(text.utf8)) else {
                throw DumpError(description: "the reader stopped before it reported", fileFailed: true)
            }
            return items
        } catch let error as CropError {
            var items: [Item] = []
            for sub in ["attachments", "scripts"] {
                let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? []
                for file in found.sorted() {
                    items.append(Item(kind: sub == "scripts" ? "script" : "attachment", path: folder.appendingPathComponent(sub).appendingPathComponent(file).path,
                                      page: nil, detail: "written before the reader stopped", skipped: nil))
                }
            }
            items.append(Item(kind: "dump", path: nil, page: nil, detail: "attachments and scripts", skipped: error.description + "; the rest was left"))
            return items
        }
    }

    /// The Gatekeeper quarantine mark of the PDF, which its attachments inherit as they would from
    /// an archive that was downloaded.
    static func readQuarantine(of url: URL) -> Data? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.quarantine", &value, size, 0, 0) == size else { return nil }
        return Data(value)
    }

    /// Makes `folder` and `sub` inside it, refusing a symbolic link in the way: a link there could
    /// send files anywhere.
    static func directory(_ folder: URL, sub: String?) throws -> URL {
        func plain(_ url: URL) throws {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw DumpError(description: "\(url.path) is \(info.st_mode & S_IFMT == S_IFLNK ? "a link" : "not a folder"), so nothing is written there")
                }
            }
        }
        try plain(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let sub else { return folder }
        let inner = folder.appendingPathComponent(sub, isDirectory: true)
        try plain(inner)
        if !FileManager.default.fileExists(atPath: inner.path) {
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        }
        return inner
    }

    /// Creates a new file, never over one and never through a link, with no execute permission.
    public static func create(_ name: String, in folder: URL, sub: String? = nil) throws -> (url: URL, handle: FileHandle) {
        let directory = try Dump.directory(folder, sub: sub)
        let target = directory.appendingPathComponent(name)
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            throw DumpError(description: "\(target.path) could not be created: \(String(cString: strerror(errno)))")
        }
        return (target, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// Writes `data` as a new file; a name that is taken gets a number.
    public static func write(_ data: Data, as name: String, in folder: URL, sub: String? = nil, quarantine: Data? = nil) throws -> URL {
        var attempt = 1
        var candidate = name
        while true {
            do {
                let (url, handle) = try create(candidate, in: folder, sub: sub)
                try handle.write(contentsOf: data)
                try handle.close()
                if let quarantine { _ = quarantine.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } }
                return url
            } catch let error as DumpError where error.description.hasSuffix("File exists") && attempt < 50 {
                attempt += 1
                let ext = (name as NSString).pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                candidate = "\(stem)-\(attempt)" + (ext.isEmpty ? "" : "." + ext)
            }
        }
    }
}

public struct DumpError: Error, CustomStringConvertible {
    public var description: String
    /// The file could not be read (exit 3), as against a folder that could not be written (exit 1).
    public var fileFailed: Bool
    public init(description: String, fileFailed: Bool = false) {
        self.description = description
        self.fileFailed = fileFailed
    }
}
