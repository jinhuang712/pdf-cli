// Makes testdata/locked/locked.pdf: the first page of a smoke-set paper, locked with the
// password "open sesame", for the checks of `pdf add --password`.
//
// Run from the repo root: swift scripts/make-locked-fixture.swift
import Foundation
import PDFKit

let source = PDFDocument(url: URL(fileURLWithPath: "testdata/smoke/arxiv-2608.04589.pdf"))!
let locked = PDFDocument()
locked.insert(source.page(at: 0)!, at: 0)
let folder = URL(fileURLWithPath: "testdata/locked", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let written = locked.write(to: folder.appendingPathComponent("locked.pdf"), withOptions: [
    .userPasswordOption: "open sesame",
    .ownerPasswordOption: "owner of the fixture",
])
print(written ? "wrote testdata/locked/locked.pdf" : "could not write the file")
