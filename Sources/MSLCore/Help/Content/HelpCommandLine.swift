import Foundation

/// Every `msl` command, as data: printed by `msl --help` (Sources/msl/Help.swift)
/// and shown as the Command line chapter of MSL Help, so the terminal and the
/// app can never describe different commands.
public enum CLIReference {
    public struct Entry: Sendable {
        public let command: String
        public let summary: String
    }

    public struct Section: Sendable {
        public let title: String
        public let entries: [Entry]
    }

    public static var sections: [Section] {
        let distros = GuestDistro.allCases.filter { !$0.isCustom }.map(\.rawValue).joined(separator: ", ")
        return [
            Section(title: "Get started", entries: [
                Entry(command: "msl install <distro>", summary: "Download a distro, then set up its first instance - name, CPUs, memory and disk"),
                Entry(command: "msl <instance>", summary: "Open a shell. A distro name works too: msl debian"),
                Entry(command: "msl <instance> <command>", summary: "Run one command; exits with its exit code, like ssh"),
                Entry(command: "msl", summary: "Open a shell in the instance you used last"),
                Entry(command: "msl -- <command>", summary: "Run one command in the instance you used last"),
                Entry(command: "msl files", summary: "Open MSL Files, to browse your instances from the Mac (also --files)"),
            ]),
            Section(title: "Shell options", entries: [
                Entry(command: "-u, --user <name>", summary: "Log in as this user instead of your default account (root is always there)"),
                Entry(command: "-d, --distro <distro>", summary: "The distro for a new instance: \(distros), or custom:<image>"),
            ]),
            Section(title: "Instances", entries: [
                Entry(command: "msl list", summary: "Every instance and whether it's running (also: instances, ls)"),
                Entry(command: "msl new [name] [sizes]", summary: "Create an instance without opening a shell. No name: asks for name, CPUs, memory and disk"),
                Entry(command: "msl resources [instance] [sizes]", summary: "Show or change CPUs, memory and disk (also: config)"),
                Entry(command: "msl storage [instance] [show|fixed <size>|dynamic <size>]", summary: "Disk size, and whether its space is reserved on your Mac"),
                Entry(command: "msl status [instance]", summary: "Whether an instance is running, paused or off"),
                Entry(command: "msl suspend | resume | hibernate [instance]", summary: "Pause in memory, continue, or save to disk and stop"),
                Entry(command: "msl --shutdown [instance]", summary: "Power off cleanly; every running instance if none is named"),
                Entry(command: "msl snapshot save|restore <instance> <name>", summary: "Save or return to a named point"),
                Entry(command: "msl snapshot list [instance]", summary: "The snapshots an instance has"),
                Entry(command: "msl remove <instance> [--keep-disk]", summary: "Delete an instance. Removing a distro's last instance also deletes its disk"),
                Entry(command: "msl remove-distro <distro> [--yes]", summary: "Delete every instance of a distro and its disk"),
            ]),
            Section(title: "Sizes, for new and resources", entries: [
                Entry(command: "--cpus <n>", summary: "How many CPU cores the instance gets"),
                Entry(command: "--memory 6G | 2G-8G", summary: "A fixed amount, or a range that grows and shrinks with use"),
                Entry(command: "--disk 64G", summary: "Disk size; your Mac only gives up space as files are written"),
                Entry(command: "--disk-fixed 64G", summary: "Disk size, reserved on your Mac up front"),
            ]),
            Section(title: "Linux apps", entries: [
                Entry(command: "msl apps list | scan [instance]", summary: "The instance's GUI apps; scan reads them again from Linux"),
                Entry(command: "msl apps install <instance> <app>", summary: "Make a Mac app for it in ~/Applications/MSL (install-all: every app)"),
                Entry(command: "msl apps uninstall <instance> <app>", summary: "Remove that Mac app"),
                Entry(command: "msl apps pin | unpin <instance> <app>", summary: "Add or remove its Dock tile"),
            ]),
            Section(title: "Connect", entries: [
                Entry(command: "msl ssh [instance] [--print]", summary: "SSH in, setting access up the first time; --print shows the command"),
                Entry(command: "msl images [list|open]", summary: "Your own images in Custom Images; use one with --distro custom:<image>"),
                Entry(command: "msl images new <image> --distro <distro>", summary: "Start a custom image as a copy of an installed distro"),
            ]),
            Section(title: "Maintenance", entries: [
                Entry(command: "msl doctor [--fix]", summary: "Find leftover state, missing images and uninstalled tools; --fix cleans up"),
                Entry(command: "msl keyboard [--keysyms]", summary: "The Mac keyboard layout, and what Linux apps see"),
                Entry(command: "msl install-tools", summary: "From a build: install msl and mslhd into Application Support"),
                Entry(command: "msl uninstall [--everything] [--dry-run]", summary: "Remove MSL and keep your Linux; --everything deletes that too"),
                Entry(command: "msl help [--no-app]", summary: "This help, and MSL Help in the app; --no-app just prints"),
            ]),
            Section(title: "Experimental and debugging", entries: [
                Entry(command: "msl gui-native <instance> [app]", summary: "Run a Linux app on MSL's own display server"),
                Entry(command: "msl gui <instance> [app]", summary: "Run a Linux app through XQuartz"),
                Entry(command: "msl cage-view <instance> [app]", summary: "A Wayland (cage) session in a Mac window"),
                Entry(command: "msl cage-bridge-test | cage-input-test <instance>", summary: "Wayland frame and input round-trip checks"),
                Entry(command: "msl power-test <event>", summary: "Replay a power event: sleep, shutdown, logout, lowbattery, wake, battery..."),
            ]),
        ]
    }

}

// Chapter: Command line.

extension HelpChapter {
    static let commandLine = HelpChapter(
        id: "cli", title: "Command line", symbol: "terminal", tint: .gray,
        blurb: "Everything msl --help prints, here.",
        articles: [.cliReference])
}

extension HelpArticle {
    static let cliReference = HelpArticle(
        id: "cli-help", title: "msl --help", symbol: "terminal",
        summary: "Every msl command in Terminal.app, grouped the way msl --help prints them.",
        keywords: ["cli", "terminal", "command line", "msl help", "--help", "usage", "commands", "flags", "options"],
        related: ["msl-command", "command-line"],
        body: cliMarkup)

    /// Tables built from `CLIReference`. A `|` inside a cell would end it, so
    /// "suspend | resume" is written with slashes here.
    static var cliMarkup: String {
        var text = "Type these in Terminal.app. `msl --help` prints the same list, and `msl files` opens MSL Files.\n"
        for section in CLIReference.sections {
            let anchor = section.title.lowercased().filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "-")
            text += "\n## \(section.title) {#\(anchor)}\n\n| Command | Does |\n|---|---|\n"
            for entry in section.entries {
                let command = entry.command.replacingOccurrences(of: " | ", with: " / ").replacingOccurrences(of: "|", with: "/")
                let summary = entry.summary.replacingOccurrences(of: "|", with: "/")
                text += "| `\(command)` | \(summary) |\n"
            }
        }
        return text
    }
}
