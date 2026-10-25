import ArgumentParser
import Foundation
import PDFCore

/// The output contract every command keeps (FEATURES.md → F7 and F8; DESIGNS.md → Decision: one
/// output contract for every command): `--json`, the exit codes 0, 1, 2, 3 and 64, and one shape
/// for a failure, `<path>: failed: <reason>` or `{"file": …, "failed": …}`.
enum Contract {
    /// The exit codes of FEATURES.md → F8. 0 and 64 are the parser's own, 2 each command's.
    static let couldNotRun: Int32 = 1
    static let fileFailed: Int32 = 3

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    /// One compact JSON line.
    static func json<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A failure as a command reports it: the one shape.
    static func failureLine(_ file: String, _ reason: String, json: Bool) -> String {
        json ? failureJSON(file, reason) : "\(file): failed: \(reason)"
    }

    static func failureJSON(_ file: String, _ reason: String) -> String {
        Contract.json(["file": file, "failed": reason])
    }

    /// Prints a failure and returns the exit code to throw.
    static func fail(_ file: String, _ reason: String, json: Bool, code: Int32 = couldNotRun) -> ExitCode {
        print(failureLine(file, reason, json: json))
        return ExitCode(code)
    }

    /// A file that PDFKit could not open (not a PDF, locked, damaged, slow): exit 3. A locked
    /// file points to the command that opens it, unless `reason` already does.
    static func fail(file: String, reason: String, json: Bool) -> ExitCode {
        fail(file, Output.failure(reason, file: file), json: json, code: fileFailed)
    }

    /// For a locked file: the command again as the user typed it, with `--password-stdin`. Empty
    /// for any other reason, and when the password given did not open it: the same command
    /// again would fail the same way.
    static func unlockHint(_ reason: String, arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> String {
        guard reason.hasPrefix(OpenFailure.locked), !reason.contains("does not open it") else { return "" }
        let again = arguments.filter { $0 != "--password-stdin" }.map(shellWord) + ["--password-stdin"]
        return " · open it with: echo \"$PW\" | pdf " + again.joined(separator: " ")
    }

    /// One argument as a shell takes it back: as it is when it holds only safe characters, else
    /// in single quotes.
    static func shellWord(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+=.,:/@%^")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command's body. Whatever the body throws that is not the parser's own (a usage
    /// error, an exit code) becomes a failure in the one shape, exit 1: the command could not
    /// run, as on a file that does not exist.
    static func guarding(_ file: String, json: Bool, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch let error as CleanExit {
            throw error
        } catch ReadError.notFound {
            throw fail(file, "no such file", json: json)
        } catch {
            throw fail(file, reason(of: error), json: json)
        }
    }

    /// Why a dry run cannot say more: it parses nothing, and the cache holds nothing for this
    /// file version (DESIGNS.md → Decision: a dry run answers from what is kept and never parses).
    static func notReadYet(_ path: String, page: Int, _ why: Reader.Uncached) -> String {
        let file = Output.quoted(path)
        switch why {
        case .neverRead:
            return "not in the cache yet, and a dry run parses nothing; run pdf read \(file), then again"
        case .changed:
            return
                "changed since it was read, or pdf was updated, so its cached pages no longer apply, and a dry run parses nothing; run pdf read \(file), then again"
        case .pageMissing:
            return "p.\(page) is not in the cache yet, and a dry run parses nothing; run pdf read \(file) --page \(page), then again"
        }
    }

    /// A dry run's first step: the file must be there, as for the real run.
    static func requireFile(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: Reader.resolve(path)) else { throw ReadError.notFound(path) }
    }

    /// One clean sentence: a Foundation error (a file or folder that cannot be opened) gives its
    /// localized text, the tool's own errors their description.
    static func reason(of error: Error) -> String {
        if let cutOff = Store.readOnlyFailure(error) { return cutOff }
        let domain = (error as NSError).domain
        if error is CocoaError || domain.hasPrefix("NS") || domain == NSPOSIXErrorDomain {
            return error.localizedDescription
        }
        return "\(error)"
    }
}
