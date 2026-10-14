import ArgumentParser

@main
struct PDF: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "A PDF CLI tool that lets you read fast, cheap and accurately.",
        version: "0.0.0-spike"
    )
}
