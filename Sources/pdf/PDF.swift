import ArgumentParser

@main
struct PDF: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "A PDF CLI tool that lets you read fast, cheap and accurately.",
        discussion: """
            Which command:
              pdf info <pdf>                 look first: title, size, sections
              pdf read <pdf>                 then read it, or a part of it
              pdf search [<pdf>] <words>     find the pages with some words
              pdf note <pdf> 7               look up one footnote or endnote
              pdf ref <pdf> 12               look up one cited reference
              pdf crop <pdf> --figure 4      see a figure, table or equation
              pdf dump <pdf> --markdown --figures  write them to files
              pdf pick, pdf transcribe       keep what you read
              pdf reparse <pdf> --page 7     read pages again, or with --step ocr by OCR
              pdf add, ls, rm, gc            the library: add, list, remove, clean
              pdf agent-guide                the guide that teaches an agent

            Examples:
              pdf info paper.pdf
              pdf read paper.pdf --section Method
              pdf crop paper.pdf --table 2

            Every command takes --json. It ends 0 ok; 2 pages flagged, from read, add, reparse and dump only (info, \
            search and crop end 0 and name the flagged pages); 3 the file failed, or read found no page \
            with text; 1 it could not run (a missing file); 64 used wrongly. A failure reads \
            <path>: failed: <reason>.

            Run pdf <command> --help for a command's options and examples.
            """,
        version: "0.0.0-spike",
        subcommands: [
            AddCommand.self, ReparseCommand.self, InfoCommand.self, ReadCommand.self, NoteCommand.self, RefCommand.self, SearchCommand.self,
            CropCommand.self, DumpCommand.self, PickCommand.self, TranscribeCommand.self,
            ListCommand.self, RemoveCommand.self,
            GCCommand.self, AgentGuideCommand.self, Spike.self, DebugPages.self, DebugOCR.self, RunnerCommand.self, WorkerCommand.self,
        ]
    )
}
