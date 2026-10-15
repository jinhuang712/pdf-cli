import ArgumentParser

@main
struct PDF: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "A PDF CLI tool that lets you read fast, cheap and accurately.",
        version: "0.0.0-spike",
        subcommands: [AddCommand.self, InfoCommand.self, ReadCommand.self, PickCommand.self, ListCommand.self, RemoveCommand.self,
                      GCCommand.self, Spike.self, DebugPages.self, DebugOCR.self, RunnerCommand.self, WorkerCommand.self]
    )
}
