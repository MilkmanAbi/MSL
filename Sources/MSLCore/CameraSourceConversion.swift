import Foundation

/// The camera's one piece of real arithmetic: macOS's frames into the
/// format a Linux `v4l2loopback` device serves.
///
/// In MSLCore rather than in the helper app because both sides of mslps
/// need to agree on it, and because a conversion that can only be exercised
/// by pointing a real camera at something is a conversion that never gets
/// tested. A U/V mix-up does not crash: it produces a perfectly good
/// picture of someone with the wrong skin tone.
public enum CameraSourceConversion {
    /// NV12 (what macOS hands over) to YUYV (what every V4L2 application
    /// understands without negotiating).
    ///
    /// YUYV packs two pixels into four bytes as Y0 U Y1 V, sharing one
    /// chroma pair. NV12 keeps a full-size luma plane and a half-height
    /// interleaved chroma plane, so each chroma row serves two luma rows.
    ///
    /// `lumaStride` and `chromaStride` are not the width: camera buffers
    /// are padded, and reading by width shears the picture.
    public static func yuyv(fromNV12 luma: [UInt8], chroma: [UInt8],
                            width: Int, height: Int,
                            lumaStride: Int, chromaStride: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 2)
        for row in 0..<height {
            let lumaRow = row * lumaStride
            let chromaRow = (row / 2) * chromaStride
            var index = row * width * 2
            var column = 0
            while column < width {
                let y0 = lumaRow + column < luma.count ? luma[lumaRow + column] : 0
                let y1 = lumaRow + column + 1 < luma.count ? luma[lumaRow + column + 1] : y0
                let chromaIndex = chromaRow + (column / 2) * 2
                // Grey rather than garbage when a frame arrives short.
                let u = chromaIndex < chroma.count ? chroma[chromaIndex] : 128
                let v = chromaIndex + 1 < chroma.count ? chroma[chromaIndex + 1] : 128
                out[index] = y0
                out[index + 1] = u
                out[index + 2] = y1
                out[index + 3] = v
                index += 4
                column += 2
            }
        }
        return out
    }
}
