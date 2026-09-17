import Foundation

/// Builds the X11 "connection setup, Success" response - the single most
/// failure-sensitive part of this server: every byte here has a fixed,
/// spec-defined position (X Window System Protocol, chapter 8), and one
/// miscounted field makes every client fail before it ever sends a real
/// request. One screen, one visual (24-bit TrueColor) is all this
/// skeleton advertises.
enum X11ConnectionSetup {
    struct Config {
        var littleEndian: Bool
        var resourceIdBase: UInt32
        var resourceIdMask: UInt32
        var rootWindowID: UInt32
        var colormapID: UInt32
        var visualID: UInt32
        var argbVisualID: UInt32
        var screenWidthPixels: Int
        var screenHeightPixels: Int
    }

    /// Byte sizes of each fixed-layout chunk, named so the length math
    /// below reads as arithmetic on real spec sections rather than magic
    /// numbers - each is checked against a live capture the first time
    /// this was gotten right (see `X11Server`'s "kickstart" testing notes).
    private static let fixedHeaderAfterFirst8Bytes = 32 // release-number..unused, i.e. everything between the 8-byte common header and vendor
    private static let pixmapFormatEntryBytes = 8
    private static let screenFixedBytes = 40
    private static let depthFixedBytes = 8
    private static let visualTypeBytes = 24

    static func buildSuccessResponse(_ config: Config) -> [UInt8] {
        let w = X11ByteWriter(littleEndian: config.littleEndian)

        let vendor = "MSL X11Server (experimental, Phase 2 skeleton)"
        let vendorBytes = Array(vendor.utf8)
        let vendorPadded = X11Wire.pad(vendorBytes.count)

        let depthBytes = depthFixedBytes + visualTypeBytes // one DEPTH, one VISUALTYPE in it
        // One SCREEN: the 24-bit and 32-bit ARGB depths (see `argbVisualID`'s
        // doc comment) each with a visual, plus depth 1 with none.
        let screenBytes = screenFixedBytes + depthBytes * 2 + depthFixedBytes

        let additionalDataBytes = fixedHeaderAfterFirst8Bytes
            + vendorPadded
            + pixmapFormatEntryBytes * 3 // one PIXMAP FORMAT per depth advertised anywhere: 1, 24, 32
            + screenBytes
        precondition(additionalDataBytes % 4 == 0, "X11 connection setup response must be a whole number of 4-byte units")

        w.writeU8(1) // Success
        w.writeU8(0) // unused
        w.writeU16(11) // protocol-major-version
        w.writeU16(0)  // protocol-minor-version
        w.writeU16(UInt16(additionalDataBytes / 4)) // length of everything after this 8-byte header, in 4-byte units

        w.writeU32(0) // release-number
        w.writeU32(config.resourceIdBase)
        w.writeU32(config.resourceIdMask)
        w.writeU32(0) // motion-buffer-size
        w.writeU16(UInt16(vendorBytes.count))
        w.writeU16(65535) // maximum-request-length - generous; this server doesn't actually enforce a cap
        w.writeU8(1) // number of SCREENs
        w.writeU8(3) // number of PIXMAP FORMATs
        w.writeU8(config.littleEndian ? 0 : 1) // image-byte-order: 0 = LSBFirst, matches the connection's own order
        w.writeU8(config.littleEndian ? 0 : 1) // bitmap-format-bit-order
        w.writeU8(32) // bitmap-format-scanline-unit
        w.writeU8(32) // bitmap-format-scanline-pad
        w.writeU8(8) // min-keycode
        w.writeU8(255) // max-keycode
        w.writePadding(4) // unused

        w.writeString8Padded(vendor)

        // PIXMAP FORMAT (8 bytes) - depth 1, the bitmap depth every X server
        // has. Cursors, window shapes and stipples are depth-1 pixmaps, and
        // cairo wraps one as an A1 picture. Without it GTK3 crashed on the
        // first character typed into any text field: `GtkEntry` hides the
        // pointer while typing, the blank cursor is a 1x1 bitmap, and
        // `XRenderCreatePicture` dereferenced the NULL format it got back.
        w.writeU8(1) // depth
        w.writeU8(1) // bits-per-pixel
        w.writeU8(32) // scanline-pad
        w.writePadding(5)

        // PIXMAP FORMAT (8 bytes) - depth 24 (the root/default visual)
        w.writeU8(24) // depth
        w.writeU8(32) // bits-per-pixel
        w.writeU8(32) // scanline-pad
        w.writePadding(5)

        // PIXMAP FORMAT (8 bytes) - depth 32 (the ARGB visual, `argbVisualID`
        // below). Without this second entry, this list had ONLY the depth-24
        // format even though the SCREEN's own DEPTH list (below) advertises
        // a depth-32 DEPTH too - a real mismatch confirmed live against Qt's
        // xcb platform plugin (Krita): "XCB failed to find an xcb_format_t
        // for depth: 32", since Qt looks up the pixel encoding for every
        // depth a screen claims to support against THIS top-level list, not
        // just the one depth its default visual happens to use.
        w.writeU8(32) // depth
        w.writeU8(32) // bits-per-pixel
        w.writeU8(32) // scanline-pad
        w.writePadding(5)

        // SCREEN (40 bytes + its DEPTH list)
        w.writeU32(config.rootWindowID)
        w.writeU32(config.colormapID)
        w.writeU32(0x00FF_FFFF) // white-pixel
        w.writeU32(0x0000_0000) // black-pixel
        w.writeU32(0) // current-input-masks
        w.writeU16(UInt16(clamping: config.screenWidthPixels))
        w.writeU16(UInt16(clamping: config.screenHeightPixels))
        w.writeU16(UInt16(clamping: config.screenWidthPixels * 254 / 960)) // width-in-millimeters, ~96dpi
        w.writeU16(UInt16(clamping: config.screenHeightPixels * 254 / 960))
        w.writeU16(1) // min-installed-maps
        w.writeU16(1) // max-installed-maps
        w.writeU32(config.visualID) // root-visual
        w.writeU8(0) // backing-stores: Never
        w.writeU8(0) // save-unders: False
        w.writeU8(24) // root-depth
        w.writeU8(3) // number of DEPTHs in allowed-depths

        // DEPTH (8 bytes + its VISUALTYPE list)
        w.writeU8(24) // depth
        w.writePadding(1)
        w.writeU16(1) // number of VISUALTYPEs
        w.writePadding(4)

        // VISUALTYPE (24 bytes)
        w.writeU32(config.visualID)
        w.writeU8(4) // class: TrueColor
        w.writeU8(8) // bits-per-rgb-value
        w.writeU16(256) // colormap-entries
        w.writeU32(0x00FF_0000) // red-mask
        w.writeU32(0x0000_FF00) // green-mask
        w.writeU32(0x0000_00FF) // blue-mask
        w.writePadding(4)

        // Second DEPTH (32-bit, ARGB) - see `argbVisualID`'s doc comment
        // on why this needs to exist at all, not just the 24-bit one.
        w.writeU8(32) // depth
        w.writePadding(1)
        w.writeU16(1) // number of VISUALTYPEs
        w.writePadding(4)

        // VISUALTYPE (24 bytes) for the ARGB visual
        w.writeU32(config.argbVisualID)
        w.writeU8(4) // class: TrueColor
        w.writeU8(8) // bits-per-rgb-value
        w.writeU16(256) // colormap-entries
        w.writeU32(0x00FF_0000) // red-mask
        w.writeU32(0x0000_FF00) // green-mask
        w.writeU32(0x0000_00FF) // blue-mask
        w.writePadding(4)

        // Third DEPTH: 1, with no visuals - pixmaps only, as on xorg.
        w.writeU8(1) // depth
        w.writePadding(1)
        w.writeU16(0) // number of VISUALTYPEs
        w.writePadding(4)

        return w.bytes
    }
}
