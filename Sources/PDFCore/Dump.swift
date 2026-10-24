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

    /// A name safe to use in `folder`: the PDF's name cut to its last component, with control
    /// characters, a leading dot and anything past 120 characters dropped, and a number added
    /// when the name is taken.
    public static func safeName(_ name: String, fallback: String, taken: inout Set<String>) -> String {
        var base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        base = String(base.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallback }
        if base.count > 120 {
            let ext = (base as NSString).pathExtension
            let stem = String(base.prefix(100))
            base = ext.count <= 12 && !ext.isEmpty ? stem + "." + ext : stem
        }
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
            candidate = "\(stem)-\(number)" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// Saves the attachments and the scripts of the file into `folder/attachments` and
    /// `folder/scripts`. Only what was asked for is written.
    public static func payloads(path: String, folder: URL, attachments: Bool, scripts: Bool, password: String? = nil) throws -> [Item] {
        let url = URL(fileURLWithPath: path)
        guard let document = CGPDFDocument(url as CFURL) else { throw DumpError(description: OpenFailure.classify(url: url)) }
        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("") || document.unlockWithPassword(password ?? "")
        }
        guard document.isUnlocked else { throw DumpError(description: OpenFailure.locked) }
        var items: [Item] = []
        var failure: Error?
        var names = (attachments: Set<String>(), scripts: Set<String>())
        _ = FactReader.read(document, url: url) { payload in
            guard failure == nil else { return }
            do {
                switch payload {
                case .attachment(let name, let page, let data, let skipped):
                    guard attachments else { return }
                    let file = safeName(name, fallback: "attachment", taken: &names.attachments)
                    guard let data else {
                        items.append(Item(kind: "attachment", path: nil, page: page, detail: file, skipped: skipped))
                        return
                    }
                    let target = try write(data, as: file, in: folder.appendingPathComponent("attachments"))
                    items.append(Item(kind: "attachment", path: target.path, page: page, detail: "\(data.count) bytes", skipped: nil))
                case .script(let trigger, let kind, let page, let text, let skipped):
                    guard scripts else { return }
                    let stem = "\(kind.lowercased())-\(names.scripts.count + 1)"
                    let file = safeName(stem + (kind == "JavaScript" ? ".js.txt" : ".txt"), fallback: stem, taken: &names.scripts)
                    guard let text else {
                        items.append(Item(kind: "script", path: nil, page: page, detail: trigger, skipped: skipped))
                        return
                    }
                    let header = "// \(kind) on \(trigger)" + (page.map { ", p.\($0 + 1)" } ?? "") + "; saved as text by pdf dump, never run\n"
                    let target = try write(Data((header + text).utf8), as: file, in: folder.appendingPathComponent("scripts"))
                    items.append(Item(kind: "script", path: target.path, page: page, detail: trigger, skipped: nil))
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return items
    }

    /// Writes `data` as a new file, never over one, with no execute permission.
    public static func write(_ data: Data, as name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            throw DumpError(description: "\(target.path) could not be created: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        return target
    }
}

public struct DumpError: Error, CustomStringConvertible {
    public var description: String
    public init(description: String) { self.description = description }
}
