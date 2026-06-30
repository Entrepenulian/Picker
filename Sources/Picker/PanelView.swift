import AppKit
import SwiftUI

// MARK: - Panel
//
// The instrument's face. Vertical rhythm reads top-to-bottom as a story:
// the latest pick (hero) → its readable values → the action that creates more →
// the palette of everything grabbed so far.

struct PanelView: View {
    @ObservedObject var store: ColorStore
    @ObservedObject var fonts: FontStore
    @ObservedObject var app: AppState
    var onPick: () -> Void
    var onGrabFont: () -> Void
    var onResize: () -> Void

    @State private var section: Section = .colors  // drives the page (instant)
    @State private var pillSection: Section = .colors  // drives the pill (animated)
    @State private var toast: Toast?
    @State private var toastToken = 0
    @State private var selectedFontID: PickedFont.ID?

    private let width: CGFloat = 320

    enum Section: Hashable { case colors, fonts }
    struct Toast: Equatable {
        var text: String
        var icon: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SectionSwitch(pillSection: pillSection, selected: section, onSelect: selectSection)

            switch section {
            case .colors: colorsSection
            case .fonts: fontsSection
            }
        }
        .padding(Space.lg)
        .frame(width: width)
        .background(panelSurface)
        .overlay(alignment: .bottom) { toastView }
        .animation(Motion.settle, value: store.colors.isEmpty)
        .animation(Motion.settle, value: fonts.fonts.isEmpty)
        .onChange(of: app.fontFeedback) { _, feedback in
            guard let feedback else { return }
            if feedback.ok { selectedFontID = nil }
            flash(feedback.text, icon: feedback.ok ? "checkmark" : "exclamationmark.triangle.fill")
        }
    }

    // MARK: Colors section

    @ViewBuilder private var colorsSection: some View {
        HeroCard(picked: store.latest, isSampling: app.isSampling) { copy($0) }
            .animation(Motion.settle, value: store.latest)

        if let latest = store.latest {
            formatsCard(latest)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        EyedropperButton(isSampling: app.isSampling, action: onPick)

        if !store.colors.isEmpty {
            SwatchStrip(store: store) { copy($0) }
                .transition(.opacity)
        }
    }

    // MARK: Fonts section

    @ViewBuilder private var fontsSection: some View {
        FontHeroCard(picked: shownFont(), onCopy: { copy($0) }, onFind: openURL)

        GrabFontButton(isPicking: app.isPickingFont, action: onGrabFont)

        if !fonts.fonts.isEmpty {
            FontStrip(
                fonts: fonts,
                selectedID: selectedFontID,
                onSelect: { f in
                    selectedFontID = f.id
                    copy(f.family)
                }
            )
            .transition(.opacity)
        }
    }

    private func shownFont() -> PickedFont? {
        if let id = selectedFontID, let f = fonts.fonts.first(where: { $0.id == id }) { return f }
        return fonts.latest
    }

    private func openURL(_ url: URL) {
        // Open in Safari specifically — its WebKit text AX is what "Grab Font" reads
        // best — even when Safari isn't the default browser. Fall back if it's absent.
        if let safari = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari")
        {
            NSWorkspace.shared.open(
                [url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Switch pages: swap the content and resize the panel to the new page's height
    /// INSTANTLY (no empty-space / clipping gap), then slide the pill on the next
    /// runloop tick — so the resize is already finished and can't cancel the slide.
    private func selectSection(_ value: Section) {
        guard value != section else { return }
        section = value  // page swaps instantly
        onResize()  // panel snaps to the new height immediately
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.28)) { pillSection = value }  // pill slides after
        }
    }

    // MARK: Formats

    private func formatsCard(_ c: PickedColor) -> some View {
        VStack(spacing: 0) {
            FormatRow(label: "HEX", value: c.hex) { copy(c.hex) }
            divider
            FormatRow(label: "RGB", value: c.rgbString) { copy(c.rgbString) }
            divider
            FormatRow(label: "HSL", value: c.hslString) { copy(c.hslString) }
        }
        .padding(.vertical, Space.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(Hairline.soft, lineWidth: 1)
                )
        )
    }

    private var divider: some View {
        Rectangle().fill(Hairline.soft).frame(height: 1).padding(.horizontal, Space.md)
    }

    // MARK: Panel surface — the liquid glass

    private var panelSurface: some View {
        RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            .fill(.clear)
            .glassEffect(
                .regular, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .stroke(Hairline.medium, lineWidth: 1)
            )
    }

    // MARK: Copy feedback

    private var toastView: some View {
        Group {
            if let toast {
                HStack(spacing: Space.xs) {
                    Image(systemName: toast.icon)
                        .font(.system(size: 10, weight: .bold))
                    Text(toast.text)
                        .font(TypeScale.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                .overlay(Capsule().stroke(Hairline.medium, lineWidth: 1))
                .padding(.bottom, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.arrive, value: toast)
    }

    private func flash(_ text: String, icon: String = "checkmark") {
        toast = Toast(text: text, icon: icon)
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if token == toastToken { toast = nil }
        }
    }

    private func copy(_ string: String) {
        Clipboard.copy(string)
        Haptics.confirm()
        flash("Copied \(string)")
    }
}

// MARK: - Hero card

private struct HeroCard: View {
    var picked: PickedColor?
    var isSampling: Bool
    var onCopy: (String) -> Void

    @State private var hovering = false
    @State private var justCopied = false
    @State private var copyToken = 0

    var body: some View {
        Group {
            if let picked {
                filled(picked)
            } else {
                empty
            }
        }
        .frame(height: 146)
        .frame(maxWidth: .infinity)
    }

    private func filled(_ c: PickedColor) -> some View {
        let ink = c.prefersDarkInk ? Color.black : Color.white
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let showIcon = hovering || justCopied
        return Button {
            copy(c.hex)
        } label: {
            ZStack(alignment: .bottomLeading) {
                shape.fill(c.color)  // pure color, no border or sheen

                HStack(alignment: .center, spacing: 10) {
                    Text(c.hex)
                        .font(TypeScale.heroHex)
                        .foregroundStyle(ink)
                        .contentTransition(.numericText())
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink.opacity(justCopied ? 1 : 0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(showIcon ? 1 : 0)
                        .offset(x: showIcon ? 0 : -6)
                        .animation(.easeOut(duration: 0.18), value: hovering)
                        // Icon-swap timing, adapted from transitions-dev (200ms ease-in-out),
                        // nudged a touch faster so the copy→check morph feels snappier.
                        .animation(.easeInOut(duration: 0.16), value: justCopied)
                    Spacer(minLength: 0)
                }
                .padding(Space.lg)
            }
            .contentShape(shape)
        }
        .pressable(scale: 0.99)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }

    /// Copy, flip the icon to a checkmark, then let it fade back / away shortly after.
    private func copy(_ hex: String) {
        onCopy(hex)
        justCopied = true
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if token == copyToken { justCopied = false }
        }
    }

    private var empty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(
                            Hairline.medium,
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 5])
                        )
                )
            VStack(spacing: Space.sm) {
                Image(systemName: isSampling ? "loupe" : "eyedropper")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Ink.tertiary)
                    .symbolEffect(.pulse, isActive: isSampling)
                Text(isSampling ? "Pick a pixel…" : "No color yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text(isSampling ? "Click anywhere on screen" : "Grab one to begin your palette")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }
}

// MARK: - Primary action

private struct EyedropperButton: View {
    var isSampling: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: isSampling ? "loupe" : "eyedropper.halffull")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.pulse, isActive: isSampling)
                Text(isSampling ? "Sampling…" : "Pick a Color")
                    .font(TypeScale.button)
            }
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay(Capsule().stroke(Hairline.soft, lineWidth: 1))
        .scaleEffect(hovering && !isSampling ? 1.012 : 1)
        .brightness(hovering && !isSampling ? 0.04 : 0)
        .animation(Motion.micro, value: hovering)
        .onHover { hovering = $0 }
        .disabled(isSampling)
    }
}

// MARK: - Format row

private struct FormatRow: View {
    var label: String
    var value: String
    var onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: Space.md) {
                Text(label)
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 34, alignment: .leading)
                Text(value)
                    .font(TypeScale.valueStrong)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Space.sm)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.chip - 3, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .padding(.horizontal, Space.xs)
            )
        }
        .buttonStyle(.plain)
        .animation(Motion.micro, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Saved palette

private struct SwatchStrip: View {
    @ObservedObject var store: ColorStore
    var onCopy: (String) -> Void

    @State private var clearHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("PALETTE")
                    .font(TypeScale.sectionTitle)
                    .tracking(1.2)
                    .foregroundStyle(Ink.tertiary)
                Text("\(store.colors.count)")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.faint)
                    .contentTransition(.numericText())
                Spacer()
                clearButton
            }

            WheelHScroll {
                HStack(spacing: Space.sm) {
                    ForEach(store.colors) { c in
                        SwatchChip(
                            color: c,
                            onCopy: { onCopy(c.hex) },
                            onDelete: { store.remove(c) }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.4).combined(with: .opacity),
                                removal: .scale(scale: 0.6).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 2)
                .padding(.trailing, 24)  // empty room so the last chip clears the fade
                .animation(Motion.arrive, value: store.colors)
            }
            .frame(height: 58)
            // Soft trailing fade instead of a hard edge where the row overflows.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    private var clearButton: some View {
        Button {
            store.clear()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))
                Text("Clear")
                    .font(TypeScale.caption)
            }
            .foregroundStyle(clearHover ? Ink.secondary : Ink.tertiary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(clearHover ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.micro, value: clearHover)
        .onHover { clearHover = $0 }
    }
}

private struct SwatchChip: View {
    var color: PickedColor
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    private let size: CGFloat = 46

    var body: some View {
        // Copy chip and delete button are SIBLINGS layered in a ZStack — never a
        // button nested in another button's label, which would swallow the tap.
        ZStack(alignment: .topTrailing) {
            Button(action: onCopy) {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(color.color)
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .stroke(Hairline.onColor, lineWidth: 1)
                    )
                    .shadow(
                        color: .black.opacity(hovering ? 0.18 : 0),
                        radius: hovering ? 6 : 0, x: 0, y: hovering ? 2 : 0
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            }
            .pressable(scale: 0.92)

            deleteButton
                .allowsHitTesting(hovering)  // only intercepts while shown
        }
        .frame(width: size, height: size)
        .offset(y: hovering ? -3 : 0)
        .animation(Motion.micro, value: hovering)
        .onHover { hovering = $0 }
        .help(color.hex)
    }

    private var deleteButton: some View {
        // Original look (overhanging the top-right corner). The fix was structural —
        // it lives as a sibling with hit-testing gated to hover — not visual.
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.6)
    }
}

// MARK: - Wheel-friendly horizontal scroller
//
// A horizontal scroller that also moves on a plain vertical mouse wheel (no Shift
// needed) whenever the cursor is over it. Real trackpad horizontal swipes pass
// straight through to native handling.

private struct WheelHScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HorizontalWheelScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false

        let host = NSHostingView(rootView: AnyView(content))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = [.intrinsicContentSize]
        scroll.documentView = host

        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<AnyView>)?.rootView = AnyView(content)
    }
}

private final class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // A deliberate horizontal gesture (trackpad swipe) → native behavior.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        guard let documentView else { return }
        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        guard maxX > 0 else { return }

        // Mouse wheels report coarse line deltas; scale them so a notch travels a
        // sensible distance. Trackpads already report precise point deltas.
        let step =
            event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 16
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x - step), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Section switch

private struct SectionSwitch: View {
    let pillSection: PanelView.Section  // pill position (animated by the parent)
    let selected: PanelView.Section  // which label is lit (instant)
    var onSelect: (PanelView.Section) -> Void

    // Fixed geometry (panel inner width is a constant 320 − 2·16 = 288). No
    // GeometryReader — it re-measures during the panel resize and jitters.
    private let totalW: CGFloat = 288
    private let height: CGFloat = 30
    private let pad: CGFloat = 3

    var body: some View {
        let segW = (totalW - pad * 2) / 2
        ZStack(alignment: .leading) {
            // Only the pill moves. Its offset follows `pillSection`, which the parent
            // animates via withAnimation one tick AFTER the instant resize, so the
            // resize can't cancel the slide.
            Capsule()
                .fill(Color.primary.opacity(0.09))
                .overlay(Capsule().stroke(Hairline.soft, lineWidth: 1))
                .frame(width: segW, height: height - pad * 2)
                .offset(x: pad + (pillSection == .fonts ? segW : 0))

            HStack(spacing: 0) {
                label("Colors", icon: "paintpalette", value: .colors, width: segW)
                label("Fonts", icon: "textformat", value: .fonts, width: segW)
            }
            .padding(.horizontal, pad)
        }
        .frame(width: totalW, height: height)
        .background(
            Capsule().fill(Color.primary.opacity(0.04))
                .overlay(Capsule().stroke(Hairline.soft, lineWidth: 1))
        )
    }

    private func label(_ title: String, icon: String, value: PanelView.Section, width: CGFloat)
        -> some View
    {
        let isSelected = selected == value
        return HStack(spacing: Space.xs) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(TypeScale.label)
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(value) }
    }
}

// MARK: - Font specimen card

/// "Text states swap" (transitions.dev): the outgoing details blur and glide up and
/// out while the incoming details blur in from just below — an in-place content swap,
/// not a hard cut.
private struct FontDetailSwap: ViewModifier {
    var y: CGFloat
    var blur: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).offset(y: y)
    }
}

extension AnyTransition {
    fileprivate static var fontDetails: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: FontDetailSwap(y: 6, blur: 3, opacity: 0),
                identity: FontDetailSwap(y: 0, blur: 0, opacity: 1)),
            removal: .modifier(
                active: FontDetailSwap(y: -6, blur: 3, opacity: 0),
                identity: FontDetailSwap(y: 0, blur: 0, opacity: 1)))
    }
}

private struct FontHeroCard: View {
    var picked: PickedFont?
    var onCopy: (String) -> Void
    var onFind: (URL) -> Void

    @State private var hovering = false
    @State private var justCopied = false
    @State private var copyToken = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Group {
            if let picked {
                ZStack(alignment: .topLeading) {
                    // Static card — persists across font swaps, so only the data moves.
                    shape.fill(Color.primary.opacity(0.04))
                        .overlay(shape.stroke(Hairline.soft, lineWidth: 1))

                    // Keyed by font id: selecting another saved font swaps the old set
                    // out and the new set in with a blurred up-and-down crossfade.
                    details(picked)
                        .padding(Space.lg)
                        .id(picked.id)
                        .transition(.fontDetails)
                }
                .clipShape(shape)
                .contentShape(shape)
                .onTapGesture { copy(picked.family) }
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .overlay(alignment: .bottomTrailing) { copyBadge }
            } else {
                empty
            }
        }
        .frame(height: 168)
        .frame(maxWidth: .infinity)
        .animation(Motion.fontSwap, value: picked?.id)
    }

    private func details(_ f: PickedFont) -> some View {
        let specimen = (f.sampleSnippet?.isEmpty == false) ? f.sampleSnippet! : "AaBbCcDd 0123"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.family)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(metaLine(f))
                        .font(TypeScale.caption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                findButton(f)
            }

            Spacer(minLength: Space.sm)

            Text("AaBbCcDdEe")
                .font(.custom(f.family, size: 32))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(specimen)
                .font(.custom(f.family, size: 15))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .padding(.top, 4)
        }
    }

    private var copyBadge: some View {
        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(justCopied ? Ink.secondary : Ink.tertiary)
            .contentTransition(.symbolEffect(.replace))
            .opacity(hovering || justCopied ? 1 : 0)
            .padding(Space.md)
            .animation(.easeInOut(duration: 0.16), value: justCopied)
            .animation(.easeOut(duration: 0.18), value: hovering)
    }

    private func metaLine(_ f: PickedFont) -> String {
        let base = f.sizeWeightLabel
        if !f.isInstalled {
            return base.isEmpty
                ? "Preview approximate — not installed"
                : base + " · approx."
        }
        return base.isEmpty ? "Tap to copy name" : base
    }

    private func findButton(_ f: PickedFont) -> some View {
        Button {
            onFind(f.findURL)
        } label: {
            HStack(spacing: 3) {
                Text("Find")
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().stroke(Hairline.soft, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private func copy(_ name: String) {
        onCopy(name)
        justCopied = true
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if token == copyToken { justCopied = false }
        }
    }

    private var empty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(
                            Hairline.medium,
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 5])
                        )
                )
            VStack(spacing: Space.sm) {
                Image(systemName: "textformat")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Ink.tertiary)
                Text("No font yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text("Grab Font, then click any text on a site")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.md)
        }
    }
}

// MARK: - Grab font action

private struct GrabFontButton: View {
    var isPicking: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: isPicking ? "cursorarrow.rays" : "character.cursor.ibeam")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.pulse, isActive: isPicking)
                Text(isPicking ? "Click any text…" : "Grab Font")
                    .font(TypeScale.button)
            }
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay(Capsule().stroke(Hairline.soft, lineWidth: 1))
        .scaleEffect(hovering && !isPicking ? 1.012 : 1)
        .brightness(hovering && !isPicking ? 0.04 : 0)
        .animation(Motion.micro, value: hovering)
        .onHover { hovering = $0 }
        .disabled(isPicking)
    }
}

// MARK: - Saved fonts

private struct FontStrip: View {
    @ObservedObject var fonts: FontStore
    var selectedID: PickedFont.ID?
    var onSelect: (PickedFont) -> Void

    @State private var clearHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Text("SAVED FONTS")
                    .font(TypeScale.sectionTitle)
                    .tracking(1.2)
                    .foregroundStyle(Ink.tertiary)
                Text("\(fonts.fonts.count)")
                    .font(TypeScale.caption)
                    .foregroundStyle(Ink.faint)
                    .contentTransition(.numericText())
                Spacer()
                clearButton
            }

            WheelHScroll {
                HStack(spacing: Space.sm) {
                    ForEach(fonts.fonts) { f in
                        FontChip(
                            font: f,
                            selected: f.id == selectedID,
                            onTap: { onSelect(f) },
                            onDelete: { fonts.remove(f) }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.4).combined(with: .opacity),
                                removal: .scale(scale: 0.6).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 2)
                .padding(.trailing, 24)
                .animation(Motion.arrive, value: fonts.fonts)
            }
            .frame(height: 72)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    private var clearButton: some View {
        Button {
            fonts.clear()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))
                Text("Clear")
                    .font(TypeScale.caption)
            }
            .foregroundStyle(clearHover ? Ink.secondary : Ink.tertiary)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(clearHover ? 0.07 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.micro, value: clearHover)
        .onHover { clearHover = $0 }
    }
}

private struct FontChip: View {
    var font: PickedFont
    var selected: Bool
    var onTap: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    private let w: CGFloat = 96
    private let h: CGFloat = 58

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(spacing: 2) {
                    Text("Ag")
                        .font(.custom(font.family, size: 22))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(font.family)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: w, height: h)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.10 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .stroke(selected ? Hairline.medium : Hairline.soft, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            }
            .pressable(scale: 0.95)

            deleteButton
                .allowsHitTesting(hovering)
        }
        .frame(width: w, height: h)
        .offset(y: hovering ? -3 : 0)
        .animation(Motion.micro, value: hovering)
        .onHover { hovering = $0 }
        .help(font.family)
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.6)
    }
}
