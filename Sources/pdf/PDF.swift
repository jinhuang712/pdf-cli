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
              pdf crop <pdf> --figure 4      see a figure, table or equation
              pdf dump <pdf> --markdown      write text and figures to files
              pdf pick, pdf transcribe       keep what you read
              pdf add, ls, rm, gc            the library: add, list, remove, clean
              pdf agent-guide                the guide that teaches an agent

            Example:
              pdf info paper.pdf
              pdf read paper.pdf --section Method
              pdf crop paper.pdf --table 2

            Run pdf <command> --help for a command's options and examples.
            """,
        version: "0.0.0-spike",
        subcommands: [AddCommand.self, InfoCommand.self, ReadCommand.self, SearchCommand.self, CropCommand.self, DumpCommand.self, PickCommand.self, TranscribeCommand.self,
                      ListCommand.self, RemoveCommand.self,
                      GCCommand.self, AgentGuideCommand.self, Spike.self, DebugPages.self, DebugOCR.self, RunnerCommand.self, WorkerCommand.self]
    )
}
