import SwiftUI

/// One line of text that scrolls itself when it is too long to fit.
///
/// Every app tile is the same size, which means a long name has to go
/// somewhere. Wrapping made tiles different heights; truncating loses the
/// end of exactly the names that need it most ("LibreOffice Calc" and
/// "LibreOffice Draw" truncate to the same thing). So the name scrolls -
/// but only while the pointer is over the tile, because a grid of sixty
/// tiles all animating at once is a slot machine, not a list.
///
/// A name that fits is simply centred and never moves.
struct MarqueeText: View {
    let text: String
    /// Usually the tile's own hover state, so the whole tile is the target
    /// rather than the few pixels of text.
    let isActive: Bool
    var font: Font = .callout
    /// Points per second. Slow enough to read, quick enough to finish.
    var speed: Double = 26

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var fits: Bool { overflow <= 0.5 }

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { textGeometry in
                        Color.clear.onAppear { textWidth = textGeometry.size.width }
                            .onChange(of: textGeometry.size.width) { _, new in textWidth = new }
                    }
                )
                .frame(width: geometry.size.width, alignment: fits ? .center : .leading)
                .offset(x: fits ? 0 : offset)
                .clipped()
                .onAppear { containerWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, new in containerWidth = new }
        }
        .frame(height: lineHeight)
        // Masked rather than plain-clipped: text that simply stops at the
        // edge reads as a rendering glitch, a fade reads as "there is more".
        .mask(fits ? AnyView(Rectangle()) : AnyView(edgeFade))
        .onChange(of: isActive) { _, active in animate(active) }
        .onChange(of: text) { _, _ in offset = 0 }
        .accessibilityLabel(text)
    }

    private var lineHeight: CGFloat { 18 }

    /// Only the edge that has text hidden behind it is faded. At rest the
    /// name starts at the left, so fading its first letter would just look
    /// like a rendering bug; once it scrolls, both ends have more text.
    private var edgeFade: some View {
        let leading: Double = offset < -0.5 ? 0.06 : 0
        return LinearGradient(
            stops: [.init(color: leading > 0 ? .clear : .black, location: 0),
                    .init(color: .black, location: leading),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }

    /// Out and back, then still. Repeating forever would make a hovered
    /// tile jitter under the pointer while someone is trying to click it.
    private func animate(_ active: Bool) {
        guard !fits else { return }
        guard active else {
            withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
            return
        }
        let duration = Double(overflow) / speed
        withAnimation(.linear(duration: duration).delay(0.35)) { offset = -overflow }
        withAnimation(.linear(duration: duration).delay(0.35 + duration + 0.8)) { offset = 0 }
    }
}
