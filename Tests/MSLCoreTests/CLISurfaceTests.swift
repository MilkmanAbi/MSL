import XCTest
@testable import MSLCore

/// The CLI's shape: which words are commands, which names an instance may
/// have, and what plain `msl` prints.
final class CLISurfaceTests: XCTestCase {

    // MARK: - The command table

    /// Every command the help guide documents has to exist, or `msl --help`
    /// and the guide's Command line chapter promise something that isn't
    /// there. Both are generated from `CLIReference`, so this checks the
    /// reference against the dispatch table rather than against prose.
    func testEveryDocumentedCommandExists() {
        var missing: [String] = []
        for section in CLIReference.sections {
            for entry in section.entries {
                let words = entry.command.split(separator: " ").map(String.init)
                // "msl <verb> ..." - options-only rows ("-u, --user") and the
                // bare "msl" row have no verb to check.
                guard words.first == "msl", words.count > 1 else { continue }
                let verb = words[1]
                guard !verb.hasPrefix("-"), !verb.hasPrefix("<") else { continue }
                if !CLICommands.all.contains(verb) { missing.append(verb) }
            }
        }
        XCTAssertEqual(missing, [], "documented but not a command")
    }

    func testRunAndVersionAreCommands() {
        for verb in ["run", "version", "distros", "list", "help"] {
            XCTAssertTrue(CLICommands.all.contains(verb), "\(verb) should be a command")
        }
    }

    /// `all` drops `--`, which is a separator rather than a word anyone
    /// could name an instance after.
    func testDashDashIsNotACommandWord() {
        XCTAssertFalse(CLICommands.all.contains("--"))
    }

    // MARK: - Names

    /// The reason the reserved list exists: an instance called `run` could
    /// never be addressed as `msl run` again.
    func testCommandWordsAreRefusedAsNames() {
        for name in ["run", "list", "help", "version", "install", "RUN"] {
            XCTAssertFalse(CLICommands.isAvailableName(name), "\(name) should be refused")
            XCTAssertNotNil(CLICommands.nameRefusal(name))
        }
    }

    /// `msl fedora` naming a Fedora instance "fedora" is the whole of a
    /// fresh install's instructions, so distro names stay available.
    func testDistroNamesStayAvailable() {
        for distro in GuestDistro.allCases where !distro.isCustom {
            XCTAssertTrue(CLICommands.isAvailableName(distro.rawValue),
                          "\(distro.rawValue) must stay usable as an instance name")
        }
    }

    /// `default` is `InstanceRegistry.defaultInstanceName` - the instance a
    /// first-ever run lands on. Reserving it refused MSL's own pick.
    func testDefaultInstanceNameStaysAvailable() {
        XCTAssertTrue(CLICommands.isAvailableName(InstanceRegistry.defaultInstanceName))
    }

    /// A mistyped flag is not an attempt to name an instance, and the
    /// message has to send the reader to the option list rather than to
    /// `msl new`.
    func testMistypedFlagReadsAsAnOption() {
        let refusal = CLICommands.nameRefusal("--nonsense")
        XCTAssertEqual(refusal?.contains("unknown option"), true)
        XCTAssertEqual(refusal?.contains("instance name"), false)
    }

    func testOrdinaryNamesAreAccepted() {
        for name in ["work", "my-box", "box_2", "Milk"] {
            XCTAssertTrue(CLICommands.isAvailableName(name), "\(name) should be allowed")
            XCTAssertNil(CLICommands.nameRefusal(name))
        }
    }

    func testTooLongAndEmptyAreRefused() {
        XCTAssertFalse(CLICommands.isAvailableName(""))
        XCTAssertFalse(CLICommands.isAvailableName(String(repeating: "a", count: 33)))
        XCTAssertFalse(CLICommands.isAvailableName("has space"))
    }

    // MARK: - Plain `msl`

    func testOverviewListsInstancesAndMarksTheLastUsed() {
        let text = CLIOverview.render(
            instances: [.init(name: "work", distro: "debian", isLastUsed: true),
                        .init(name: "tiny", distro: "alpine", isLastUsed: false)],
            styled: false)
        XCTAssertTrue(text.contains("work"))
        XCTAssertTrue(text.contains("tiny"))
        XCTAssertTrue(text.contains("msl run` opens this one"))
        XCTAssertTrue(text.contains("msl help"))
    }

    /// An empty Mac is told what to type, not shown a list of nothing.
    func testOverviewOnAnEmptyMac() {
        let text = CLIOverview.render(instances: [], styled: false)
        XCTAssertTrue(text.contains("msl install debian"))
        XCTAssertTrue(text.contains("No instances yet"))
        // The heading, not the words "Your instances" - which also appear in
        // the summary of `msl list` further down.
        XCTAssertFalse(text.contains("\nYour instances\n"))
    }

    /// Piped output carries no escape codes.
    func testUnstyledOverviewHasNoEscapes() {
        let text = CLIOverview.render(instances: [.init(name: "work", distro: "debian", isLastUsed: false)],
                                      styled: false)
        XCTAssertFalse(text.contains("\u{1B}"))
    }

    func testStyledOverviewHasEscapes() {
        let text = CLIOverview.render(instances: [], styled: true)
        XCTAssertTrue(text.contains("\u{1B}["))
    }

    /// The overview names the version, since "which MSL is this" was the
    /// first thing plain `msl` could not answer.
    func testOverviewCarriesTheVersion() {
        XCTAssertTrue(CLIOverview.render(instances: [], version: "9.9.9", styled: false)
            .contains("9.9.9"))
    }

    // MARK: - The distro table

    private func catalogRows(installed: Set<String>, counts: [String: Int]) -> [DistroListing.Row] {
        DistroListing.rows(catalog: nil, instanceCounts: counts,
                           isInstalled: { installed.contains($0.rawValue) })
    }

    /// No catalog is a degraded listing, not an empty one: the names and
    /// what this Mac has are known offline.
    func testRowsWithoutACatalog() {
        let rows = catalogRows(installed: ["debian"], counts: ["debian": 2])
        XCTAssertFalse(rows.isEmpty)
        let debian = rows.first { $0.distro == "debian" }
        XCTAssertEqual(debian?.isInstalled, true)
        XCTAssertEqual(debian?.instances, 2)
        XCTAssertNil(debian?.downloadBytes)
    }

    func testTableMarksInstalledAndCountsInstances() {
        let table = DistroListing.table(catalogRows(installed: ["debian"], counts: ["debian": 2]))
        XCTAssertTrue(table.contains("ok"))
        XCTAssertTrue(table.contains("installed, 2 instances"))
    }

    func testTableSaysOneInstanceSingly() {
        let table = DistroListing.table(catalogRows(installed: ["debian"], counts: ["debian": 1]))
        XCTAssertTrue(table.contains("installed, 1 instance"))
        XCTAssertFalse(table.contains("1 instances"))
    }

    /// A column of nothing but blanks just indents the table, so the marker
    /// column only appears once something is installed.
    func testNoMarkerColumnWhenNothingIsInstalled() {
        let table = DistroListing.table(catalogRows(installed: [], counts: [:]))
        for line in table.split(separator: "\n") {
            XCTAssertFalse(line.hasPrefix("      "), "unexpected indent: \(line)")
        }
    }

    func testEmptyRowsRenderNothing() {
        XCTAssertEqual(DistroListing.table([]), "")
    }
}
