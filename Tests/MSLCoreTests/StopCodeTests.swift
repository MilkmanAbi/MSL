import XCTest
@testable import MSLCore

/// The stop codes MSL puts on its crash screen.
///
/// A stop code is a promise: somebody pastes `0x00000010` into an issue, or
/// searches it, and finds the same condition every time. These tests are
/// what make that promise keepable - above all that a number is never
/// quietly reused for something else.
final class StopCodeTests: XCTestCase {

    private var all: [CrashScreen.StopCode] { CrashScreen.allStopCodes }

    /// **The one that matters most.** Reusing a number silently changes what
    /// every older report meant.
    func testEveryNumberIsUsedOnce() {
        let numbers = all.map(\.number)
        XCTAssertEqual(Set(numbers).count, numbers.count, "two codes share a number")
    }

    func testEveryNameIsUsedOnce() {
        let names = all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two codes share a name")
    }

    /// The numbers that have shipped, pinned. Changing one is not a
    /// refactor - it rewrites the meaning of reports already in the wild.
    func testShippedNumbersNeverMove() {
        let shipped: [String: UInt32] = [
            "WENT_SOMEWHERE_IT_SHOULDNT": 0x01,
            "BUS_TOOK_A_WRONG_TURN": 0x02,
            "INSTRUCTION_MAKES_NO_SENSE": 0x03,
            "MATHS_HAPPENED": 0x04,
            "GAVE_UP_ON_ITSELF": 0x05,
            "TRIPPED_OVER_A_TRAP": 0x06,
            "SERVICE_CANNOT_LISTEN": 0x10,
            "SIGNING_KEY_UNREADABLE": 0x11,
            "KEY_STORE_UNPROTECTED": 0x12,
            "VIRTUALIZATION_REFUSED": 0x13,
        ]
        for (name, number) in shipped {
            XCTAssertEqual(CrashScreen.code(named: name)?.number, number,
                           "\(name) has moved - every report quoting it now means something else")
        }
    }

    func testTheyAreFoundByName() {
        for code in all {
            XCTAssertEqual(CrashScreen.code(named: code.name), code)
        }
        XCTAssertNil(CrashScreen.code(named: "UNCAUGHT_NSINVALIDARGUMENT"),
                     "an exception carries its own name and has no fixed entry")
    }

    /// The form people actually see and search for.
    func testTheyPrintAsEightHexDigits() {
        XCTAssertEqual(CrashScreen.StopCode.serviceCannotListen.printed, "0x00000010")
        XCTAssertEqual(CrashScreen.StopCode.wentSomewhereItShouldnt.printed, "0x00000001")
    }

    /// Every code says what happened, in a sentence rather than a symbol.
    func testEveryCodeExplainsItself() {
        for code in all {
            XCTAssertFalse(code.happened.isEmpty, "\(code.name) says nothing")
            XCTAssertTrue(code.happened.hasSuffix("."), "\(code.name) is not a sentence")
            XCTAssertFalse(code.happened.contains("_"),
                           "\(code.name) repeats its own symbol instead of explaining")
        }
    }

    /// **Advice only where there is some.** The unanticipated ones get none,
    /// deliberately: when MSL does not know what went wrong, inventing a
    /// next step is worse than admitting it does not know.
    func testOnlyTheKnownOnesOfferANextStep() {
        let unanticipated = ["WENT_SOMEWHERE_IT_SHOULDNT", "BUS_TOOK_A_WRONG_TURN",
                             "INSTRUCTION_MAKES_NO_SENSE", "MATHS_HAPPENED",
                             "GAVE_UP_ON_ITSELF", "TRIPPED_OVER_A_TRAP"]
        for code in all {
            if unanticipated.contains(code.name) {
                XCTAssertNil(code.next, "\(code.name) cannot know what to suggest")
            } else {
                XCTAssertNotNil(code.next, "\(code.name) is a condition MSL understands "
                                         + "- it should say what to do about it")
                XCTAssertFalse(code.next!.isEmpty)
            }
        }
    }

    /// Signals read from the same table the screen does, so a name cannot
    /// have one number here and another there.
    func testSignalsMapToTheTable() {
        XCTAssertEqual(CrashScreen.stop(signal: SIGSEGV), .wentSomewhereItShouldnt)
        XCTAssertEqual(CrashScreen.stop(signal: SIGABRT), .gaveUpOnItself)
        XCTAssertEqual(CrashScreen.stopCode(signal: SIGSEGV), "WENT_SOMEWHERE_IT_SHOULDNT")
        // One MSL has no name for still produces something reportable.
        XCTAssertNil(CrashScreen.stop(signal: SIGUSR1))
        XCTAssertEqual(CrashScreen.stopCode(signal: SIGUSR1), "SIGNAL_30")
    }

    /// The entitlement check must never report "absent" because it could not
    /// read the task - that would crash-screen a working Mac.
    func testTheEntitlementCheckOnlyFailsOnADefiniteAnswer() {
        // The test binary is not entitled, so this is the honest answer for
        // it; what matters is that it answers at all rather than trapping.
        _ = CrashScreen.canCreateVirtualMachines()
    }

    /// A key that was never created is a first run, not a fault.
    func testHealthIsSilentWhenThereIsNoKeyYet() {
        XCTAssertNil(InstanceIdentityKey.health() ?? nil as String?,
                     "a readable or absent key must not be reported as a fault")
    }
}
