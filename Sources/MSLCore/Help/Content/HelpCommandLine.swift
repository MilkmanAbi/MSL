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
                Entry(command: "msl", summary: "What you have and what to type next"),
                Entry(command: "msl install <distro>", summary: "Download a distro, then set up its first instance - name, CPUs, memory and disk"),
                Entry(command: "msl run <instance>", summary: "Open a shell. Short form: msl <instance>"),
                Entry(command: "msl run <instance> <command>", summary: "Run one command; exits with its exit code, like ssh"),
                Entry(command: "msl run", summary: "Open a shell in the instance you used last"),
                Entry(command: "msl -- <command>", summary: "Run one command in the instance you used last"),
                Entry(command: "msl distros", summary: "Every distro you can install, and which you already have"),
                Entry(command: "msl files", summary: "Open MSL Files, to browse your instances from the Mac (also --files)"),
                Entry(command: "msl help", summary: "This list, in your terminal"),
                Entry(command: "msl version", summary: "Which MSL this is (also --version, -v)"),
            ]),
            Section(title: "Shell options", entries: [
                Entry(command: "-u, --user <name>", summary: "Log in as this user instead of your default account (root is always there)"),
                Entry(command: "-d, --distro <distro>", summary: "The distro for a new instance: \(distros), or custom:<image>"),
            ]),
            Section(title: "Instances", entries: [
                Entry(command: "msl list", summary: "Every instance and whether it's running (also: instances, ls)"),
                Entry(command: "msl list online", summary: "Every distro you can install, with its download size"),
                Entry(command: "msl list installed", summary: "The distro images already downloaded to this Mac"),
                Entry(command: "msl new [name] [sizes]", summary: "Create an instance without opening a shell. No name: asks for name, CPUs, memory and disk"),
                Entry(command: "msl resources [instance] [sizes]", summary: "Show or change CPUs, memory and disk (also: config)"),
                Entry(command: "msl storage [instance] [show|fixed <size>|dynamic <size>]", summary: "Disk size, and whether its space is reserved on your Mac"),
                Entry(command: "msl status [instance]", summary: "Whether an instance is running, paused or off"),
                Entry(command: "msl suspend | resume [instance]", summary: "Pause in memory and continue - keeps everything exactly as it is, apps and all"),
                Entry(command: "msl hibernate [instance]", summary: "Save to disk and stop. Survives a Mac restart, but Linux apps are closed and reopened - only suspend keeps their windows"),
                Entry(command: "msl --shutdown [instance]", summary: "Power off cleanly; every running instance if none is named"),
                Entry(command: "msl snapshot save|restore <instance> <name>", summary: "Save or return to a named point"),
                Entry(command: "msl snapshot list [instance]", summary: "The snapshots an instance has"),
                Entry(command: "msl forward <instance> <mac port>:<linux port> [--ssh]", summary: "Reach a guest's port at localhost on this Mac"),
                Entry(command: "msl forward <instance> list", summary: "What is forwarded for an instance"),
                Entry(command: "msl unforward <mac port>", summary: "Close a forwarded port"),
                Entry(command: "msl vault <instance> [status|unlock|lock|adopt]", summary: "Whose key opens its container, and supply one you hold"),
                Entry(command: "msl protect <instance>", summary: "Move its disk into an encrypted container, so a copy of the file is useless"),
                Entry(command: "msl unprotect <instance>", summary: "Move it back out, as a plain file"),
                Entry(command: "msl identity [instance]", summary: "Where an instance came from - whether it is an original or a copy"),
                Entry(command: "msl rename <instance> <new name>", summary: "Give an instance another name, carrying its disk and settings with it"),
                Entry(command: "msl clone <instance> <new name>", summary: "Make a second instance from this one - its disk, accounts and settings"),
                Entry(command: "msl remove <instance> [--keep-disk]", summary: "Delete an instance. Removing a distro's last instance also deletes its disk"),
                Entry(command: "msl remove-distro <distro> [--yes]", summary: "Delete every instance of a distro and its disk"),
                Entry(command: "msl <instance> --shipment [-o FILE]", summary: "Package the whole instance into one .mslship file"),
                Entry(command: "msl shipment info <file>", summary: "What a shipment contains, without installing it"),
                Entry(command: "msl shipment install <file> [--name N]", summary: "Install a shipment as a new instance"),
                Entry(command: "msl lock [instance] [on | off]", summary: "Ask for Touch ID or your password before this instance starts"),
                Entry(command: "msl dns [instance] [auto | cloudflare | google | quad9 | <address>]", summary: "Which resolver the instance uses for name lookups"),
                Entry(command: "msl vpn [instance] [status | install | remove]", summary: "The hide.me VPN client inside one instance; you log in with your own account"),
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
                Entry(command: "msl usb list", summary: "USB devices on the Mac: which macOS driver holds each one, and which instance has it"),
                Entry(command: "msl usb attach <device> [instance]", summary: "Give that USB device to a running instance. <device> is a location ID or vendor:product from the list. A device macOS has no driver for goes straight through; one it does asks for your password and goes back on detach"),
                Entry(command: "msl usb detach <device> [instance]", summary: "Take it back; macOS picks it up again"),
                Entry(command: "msl usb test [instance]", summary: "Attach MSL's own virtual test device - checks passthrough works with nothing plugged in"),
            ]),
            Section(title: "Maintenance", entries: [
                Entry(command: "msl doctor [--fix]", summary: "Find leftover state, missing images and uninstalled tools; --fix cleans up"),
                Entry(command: "msl fix-home [instance] [--dry-run]", summary: "Give files back to your Linux account after apps that ran as root left root-owned files behind"),
                Entry(command: "msl keyboard [--keysyms]", summary: "The Mac keyboard layout, and what Linux apps see"),
                Entry(command: "msl kitty [on | off | <words>]", summary: "The cat at the top of every shell, with the greeting under her. With words, she says them in a speech bubble instead; on and off decide whether she turns up in shells"),
                Entry(command: "msl greeter [on | off]", summary: "The greeting line under the shell banner"),
                Entry(command: "msl update [--download | --install]", summary: "Check for a newer MSL; download it to your Downloads, or download it and replace this one"),
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
