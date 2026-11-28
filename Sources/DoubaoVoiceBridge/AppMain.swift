import AppKit

@main
enum DoubaoVoiceBridgeMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--history-crash-test" {
            InputHistorySelfTests.crashWriter(path: CommandLine.arguments[2])
        }
        if CommandLine.arguments.contains("--diagnostics") {
            Diagnostics.printReport()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTests.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
