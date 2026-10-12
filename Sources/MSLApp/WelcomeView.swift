import MSLCore
import SwiftUI

/// The first thing a new Mac sees when MSL opens.
///
/// A sheet on the main window rather than a window of its own: it belongs
/// to the app you just opened, it should not be possible to lose behind
/// it, and it has no business appearing in the window list afterwards.
///
/// Skippable from the first page, because somebody who already knows what
/// MSL is should not have to click through six screens to reach it - and
/// skipping counts as having seen it, so it never comes back on its own.
/// The Help menu has it permanently for anyone who wants it again.
struct WelcomeView: View {
    /// Called on Finish, on Skip, and on close - whichever happens, the
    /// guide is done and the caller marks it seen.
    let done: () -> Void

    @State private var index: Int
    @Environment(\.openWindow) private var openWindow

    /// `startingAt` exists for the tests, which render each page on its own
    /// - there is no way to click Next inside an `ImageRenderer`.
    init(done: @escaping () -> Void, startingAt page: Int = 0) {
        self.done = done
        _index = State(initialValue: page)
    }

    private var pages: [WelcomePage] { WelcomeGuide.pages }
    private var page: WelcomePage { pages[index] }
    private var isLast: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            banner
            content
            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        // The sheet is a fixed size, so the page with the most text sets
        // the height for all of them and nothing jumps as you advance.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Banner

    /// The photo, with the title over it.
    ///
    /// `scaledToFill` with a bottom-ish anchor rather than `.center`: the
    /// picture is 4:3 and this strip is far wider than it is tall, so most
    /// of the frame is off-screen either way - and the half worth keeping
    /// is the lower one.
    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                if let url = MSLAsset.url("Welcome_Banner", extension: "jpg"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        // A hair of saturation, because a JPEG of a grey
                        // afternoon goes flat behind a scrim.
                        .saturation(1.12)
                } else {
                    // The asset is missing. A flat accent wash rather than
                    // a hole: MSLAsset returns nil instead of trapping
                    // precisely so a missing image is survivable.
                    LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            // Dark at the bottom, clear at the top: the title sits in the
            // dark part, and the picture keeps its own colour above it.
            // Fixed colours, not semantic ones - this scrim is over a
            // photograph in both appearances, so it must not invert.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.00), location: 0.00),
                    .init(color: .black.opacity(0.18), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 1.00),
                ],
                startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .textCase(.uppercase)
                    .kerning(0.6)
                Text(page.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
            .padding(.horizontal, Design.Spacing.large)
            .padding(.bottom, Design.Spacing.medium + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.subtitle)")
    }

    // MARK: - Body

    private var content: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text(lead(page.lead))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                ForEach(page.points) { point in
                    PointRow(point: point)
                }
            }

            Spacer(minLength: 0)

            if let action = page.action {
                Button {
                    perform(action)
                } label: {
                    Text(action.label)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, Design.Spacing.tight)
            }

            if let article = page.article {
                Button {
                    HelpNavigator.shared.search = ""
                    HelpNavigator.shared.open(article.id)
                    openWindow(id: "help")
                } label: {
                    // Not `.buttonStyle(.link)`: it renders as a solid
                    // block offscreen (so the snapshot tests could never
                    // see this row), and a link affordance is wrong for
                    // something that opens a window inside the app.
                    HStack(spacing: 5) {
                        Image(systemName: "book")
                        Text(.init(article.label))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.top, Design.Spacing.large)
        .padding(.bottom, Design.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Takes the guide's own action.
    ///
    /// It **finishes first**, then opens the window. The guide is a sheet,
    /// so leaving it up would put Permissions & Startup behind a modal the
    /// person then has to dismiss before they can answer anything - and
    /// having reached the end and acted on it, they are done with the
    /// guide either way.
    private func perform(_ action: WelcomePage.Action) {
        switch action {
        case .openPermissions:
            // They have now been shown exactly what that sidebar row is
            // for, so the row's one-time pulse has nothing left to say.
            PermissionsAndStartupButton.hasBeenIntroduced = true
            done()
            openWindow(id: "permissions")
        }
    }

    /// Lets the copy write `` `msl` `` and get a monospaced run, without
    /// every page having to be built out of concatenated `Text`.
    private func lead(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private struct PointRow: View {
        let point: WelcomePage.Point

        var body: some View {
            HStack(alignment: .top, spacing: Design.Spacing.medium) {
                Image(systemName: point.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    // A fixed box, so the text columns line up down the
                    // page however wide each symbol happens to draw.
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(point.title)
                        .font(.callout.weight(.semibold))
                    Text((try? AttributedString(markdown: point.detail)) ?? AttributedString(point.detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Design.Spacing.small) {
            // Where you are, without a number: six dots is faster to read
            // than "4 of 6" and does not imply there is homework.
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { position in
                    Circle()
                        .fill(position == index ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(index + 1) of \(pages.count)")

            Spacer()

            // Gone on the last page: "Skip" next to "Finish" is a choice
            // between two words for the same thing.
            if !isLast {
                Button("Skip") { done() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button("Back") { withAnimation(.easeInOut(duration: 0.18)) { index -= 1 } }
                .disabled(index == 0)
            // "Later" rather than "Finish" on a page whose real action is
            // the big button above it: two buttons both saying "done" in
            // different words is a choice nobody can make.
            Button(isLast ? (page.action == nil ? "Finish" : "Later") : "Next") {
                if isLast { done() } else { withAnimation(.easeInOut(duration: 0.18)) { index += 1 } }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Design.Spacing.large)
        .padding(.vertical, Design.Spacing.medium)
    }
}
