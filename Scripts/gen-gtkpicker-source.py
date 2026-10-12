#!/usr/bin/env python3
"""Regenerate Sources/MSLCore/GuestGTKPicker.swift from Guest/init/msl-gtkpicker.c.

The shim has to exist twice: as the C file the image build compiles, and as a
Swift string the guest kit ships to instances that are already running. This
keeps the second one honest - run it after any edit to the C file.
`GuestIntegrationTests.testGTKPickerSourceMatchesCheckedInFile` fails if you
forget.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Guest/init/msl-gtkpicker.c"
TARGET = ROOT / "Sources/MSLCore/GuestGTKPicker.swift"

HEADER = '''import Foundation

/// The GTK3 file-dialog shim's source, shipped in the guest kit and compiled
/// there on install.
///
/// **Why the source and not a binary.** The kit travels as text inside one
/// `shellinit` EXEC frame, and MSL has no cross-compiler for every guest
/// architecture and libc it supports. The shim deliberately includes no
/// headers and links nothing, so a plain `cc` is the only thing a guest
/// needs - and a guest without one simply keeps its own file dialogs.
///
/// **Generated - do not edit.** The readable copy lives at
/// `Guest/init/msl-gtkpicker.c`, which is what the image build compiles;
/// `Scripts/gen-gtkpicker-source.py` regenerates this file from it, and
/// `testGTKPickerSourceMatchesCheckedInFile` asserts the two are identical so
/// neither can drift from the other.
extension GuestIntegration {
    static let gtkPickerSource = #"""
'''


def main() -> int:
    text = SOURCE.read_text()
    if '"""#' in text or "\\#(" in text:
        print(f"{SOURCE}: contains a raw-string delimiter or interpolation escape",
              file=sys.stderr)
        return 1
    # The extra newline is deliberate: Swift drops the one immediately before
    # the closing delimiter, so without it the constant would lose the file's
    # trailing newline and the equality test would fail.
    TARGET.write_text(HEADER + text + '\n"""#\n}\n')
    print(f"wrote {TARGET.relative_to(ROOT)} ({len(text)} bytes of C)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
