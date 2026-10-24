import Foundation

/// A model that `pdf setup` can download. None is built yet: M2.4's layout model is built only
/// if rules fail a goal, and M3.1's search by meaning may need an embedding model if Apple's
/// built-in embeddings fall short (DESIGNS.md → Open questions). This is the small mechanism a
/// task that brings one fills in: a list, and a notice the user accepts before a download.
///
/// MIT covers only this tool's own code. A model has its own licence, and the user reads and
/// accepts it before the model is downloaded.
public struct ModelSpec: Equatable, Sendable {
    /// The folder's name under `Models.directory`, and what commands call it.
    public var name: String
    /// What it unlocks, in a sentence.
    public var unlocks: String
    public var bytes: Int64
    public var sourceURL: String
    /// Who made it.
    public var author: String
    /// The licence's name, such as "Apache-2.0".
    public var license: String
    public var licenseURL: String

    public init(
        name: String, unlocks: String, bytes: Int64, sourceURL: String, author: String, license: String,
        licenseURL: String
    ) {
        self.name = name
        self.unlocks = unlocks
        self.bytes = bytes
        self.sourceURL = sourceURL
        self.author = author
        self.license = license
        self.licenseURL = licenseURL
    }

    /// The notice shown before a download. The user accepts it, or nothing is downloaded.
    public var licenseNotice: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return """
            \(name) is not part of pdf-cli, and pdf-cli's MIT licence does not cover it.
            Made by \(author), licensed \(license): \(licenseURL)
            Download \(size) from \(sourceURL).
            It unlocks: \(unlocks)
            """
    }
}

public enum Models {
    /// Every model `pdf setup` can download. Empty: no task has brought one yet.
    public static let available: [ModelSpec] = []

    /// Where downloaded models live: the user's own folder, not the cache, so a cleanup never
    /// removes what took a download to get.
    public static var directory: URL { Env.supportDirectory.appendingPathComponent("models", isDirectory: true) }

    /// The models installed: the folders under `directory`.
    public static func installed(in directory: URL = Models.directory) -> [String] {
        let found = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted()
    }

    /// The models in `list` that are not installed yet.
    public static func missing(from list: [ModelSpec] = available, installed: [String]) -> [ModelSpec] {
        list.filter { !installed.contains($0.name) }
    }
}
