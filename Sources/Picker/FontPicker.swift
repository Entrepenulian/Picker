import AppKit
import ApplicationServices

// MARK: - Font picker
//
// The font equivalent of the color loupe. macOS has no system font sampler, so
// this overlays a full-screen, click-through, accessibility-invisible window for
// the visuals and installs a CGEventTap that *consumes* mouse events before any
// app sees them — so the page beneath stays completely inert (a dropdown won't
// open on hover, a link won't follow on click). A system-wide Accessibility hit
// test reads the deepest text leaf (AXStaticText) under the pointer — works for
// any text anywhere, including items inside an open dropdown — and the overlay
// draws a crosshair, a box hugging just that text, and a live label. A click on
// text grabs it; a click on anything that isn't text (or Esc / right-click)
// closes the picker.

@MainActor
final class FontPicker {

    enum Start { case began, needsPermission }

    private var window: NSWindow?
    private var view: OverlayView?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var escMonitors: [Any] = []
    private var onResult: ((PickedFont?) -> Void)?
    private var current: Hit?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let systemWide = AXUIElementCreateSystemWide()

    var isPicking: Bool { window != nil }

    struct Hit {
        var font: PickedFont
        /// Text bounds in global AppKit (bottom-left) coordinates.
        var frame: CGRect
    }

    /// Begins picking. Returns `.needsPermission` (and triggers the system prompt)
    /// when Accessibility access hasn't been granted yet.
    func start(onResult: @escaping (PickedFont?) -> Void) -> Start {
        guard ensureTrusted() else { return .needsPermission }
        // Cap every AX round-trip. An untimed AXUIElementCopyElementAtPosition can
        // block indefinitely if the app under the cursor is slow to answer — which
        // would freeze the whole picker. 0.25s is plenty for a live hit-test.
        AXUIElementSetMessagingTimeout(Self.systemWide, 0.25)
        self.onResult = onResult
        present()
        return .began
    }

    func cancel() { finish(nil) }

    // MARK: Permission

    private func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Literal value of kAXTrustedCheckOptionPrompt (the global var isn't
        // concurrency-safe under Swift 6). Shows the system permission prompt.
        let key = "AXTrustedCheckOptionPrompt" as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }

    // MARK: Overlay lifecycle

    private func present() {
        let frame = Self.unionFrame()
        let win = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.ignoresMouseEvents = true  // click-through, so the AX hit test sees beneath
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let v = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        win.contentView = v
        v.setAccessibilityElement(false)
        win.orderFrontRegardless()

        window = win
        view = v
        installTap()
        installEscMonitors()
        NSCursor.crosshair.set()
        let m = NSEvent.mouseLocation
        refresh(atAX: CGPoint(x: m.x, y: Self.primaryHeight() - m.y))
    }

    private func finish(_ font: PickedFont?) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors = []
        NSCursor.arrow.set()
        window?.orderOut(nil)
        window = nil
        view = nil
        current = nil
        let callback = onResult
        onResult = nil
        callback?(font)
    }

    // MARK: Event tap (consumes the mouse so the page never reacts)

    private func installTap() {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<FontPicker>.fromOpaque(refcon).takeUnretainedValue()
            return picker.onTap(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    nonisolated func onTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Pull out only Sendable values; CGEvent can't cross the isolation boundary.
        let raw = type.rawValue
        let location = event.location
        let consume = MainActor.assumeIsolated { self.process(typeRaw: raw, location: location) }
        return consume ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when the event should be consumed (swallowed from all apps).
    private func process(typeRaw: UInt32, location: CGPoint) -> Bool {
        guard let type = CGEventType(rawValue: typeRaw) else { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .mouseMoved, .leftMouseDragged:
            refresh(atAX: location)  // CGEvent.location is top-left global
            NSCursor.crosshair.set()
            return true  // consume → page gets no hover
        case .leftMouseDown:
            commit(atAX: location)
            return true  // consume → no link/dropdown activation
        case .leftMouseUp:
            return true  // swallow the paired up
        case .rightMouseDown:
            cancel()
            return true
        default:
            return false
        }
    }

    private func installEscMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.cancel() } }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
        escMonitors = [global, local].compactMap { $0 }
    }

    // MARK: Hover / commit

    private func refresh(atAX ax: CGPoint) {
        let cursorAppKit = CGPoint(x: ax.x, y: Self.primaryHeight() - ax.y)
        if let hit = readText(atAX: ax) {
            current = hit
            let label =
                hit.font.sizeWeightLabel.isEmpty
                ? hit.font.family
                : "\(hit.font.family) · \(hit.font.sizeWeightLabel)"
            view?.update(highlight: hit.frame, label: label, cursor: cursorAppKit)
        } else {
            current = nil
            view?.update(highlight: nil, label: nil, cursor: cursorAppKit)
        }
    }

    private func commit(atAX ax: CGPoint) {
        if let hit = readText(atAX: ax) {
            finish(hit.font)
        } else {
            finish(nil)  // clicked something that isn't text → dismiss
        }
    }

    // MARK: Accessibility reading

    private func readText(atAX ax: CGPoint) -> Hit? {
        // The system-wide hit test descends straight to the deepest leaf — any text
        // anywhere, including inside an open dropdown. Our overlay is click-through
        // and accessibility-invisible, so the hit test reads through it.
        var elem: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(Self.systemWide, Float(ax.x), Float(ax.y), &elem)
                == .success, let e = elem
        else { return nil }

        var epid: pid_t = 0
        AXUIElementGetPid(e, &epid)
        if epid == ownPID { return nil }  // resolved to our own overlay — ignore

        // Resolve to a real text leaf: the hit test usually lands on the AXStaticText
        // directly, but on padding/edges it returns a container — descend to the text
        // run under the point. Either way we only ever match actual text, so the
        // highlight hugs the run and never the surrounding div/group/cell.
        guard let textEl = textLeaf(from: e, at: ax), let font = fontDict(at: textEl) else {
            return nil
        }

        let family = cleanFamily(
            (font["AXFontFamily"] as? String) ?? (font["AXFontName"] as? String) ?? "Unknown")
        let size = (font["AXFontSize"] as? Double) ?? 0
        let weight = weight(fromName: font["AXFontName"] as? String)
        let text =
            (axString(textEl, "AXValue") ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let h = Self.primaryHeight()
        let axFrame = frame(of: textEl) ?? CGRect(x: ax.x - 24, y: ax.y - 9, width: 48, height: 18)
        let appKitFrame = CGRect(
            x: axFrame.origin.x,
            y: h - (axFrame.origin.y + axFrame.height),
            width: axFrame.width,
            height: axFrame.height)

        let picked = PickedFont(
            family: family,
            pointSize: size,
            weightName: weight,
            sampleSnippet: text.isEmpty ? nil : String(text.prefix(60)))
        return Hit(font: picked, frame: appKitFrame)
    }

    /// Resolve an element to the AXStaticText run under an AX (top-left) point:
    /// return it directly if it's already text, else descend its subtree.
    private func textLeaf(from element: AXUIElement, at p: CGPoint) -> AXUIElement? {
        if axString(element, "AXRole") == "AXStaticText" { return element }
        return deepestText(in: element, at: p, depth: 0)
    }

    private func deepestText(in element: AXUIElement, at p: CGPoint, depth: Int) -> AXUIElement? {
        if depth > 30 { return nil }
        if axString(element, "AXRole") == "AXStaticText" { return element }

        var childrenRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenRef)
                == .success,
            let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            // Follow children that contain the point; frameless containers (some
            // groups don't publish AXFrame) are followed too.
            let f = frame(of: child)
            if f == nil || f!.contains(p) {
                if let found = deepestText(in: child, at: p, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func fontDict(at e: AXUIElement) -> NSDictionary? {
        // Web text (WebKit / Blink): attributes live on text-marker ranges.
        if let markerRange = paramValue(e, "AXTextMarkerRangeForUIElement", e),
            let cf = paramValue(e, "AXAttributedStringForTextMarkerRange", markerRange),
            CFGetTypeID(cf) == CFAttributedStringGetTypeID(),
            let dict = fontAttribute(in: cf as! CFAttributedString)
        {
            return dict
        }
        // Native Cocoa text: character-range attributed string.
        var lengthValue: AnyObject?
        AXUIElementCopyAttributeValue(e, "AXNumberOfCharacters" as CFString, &lengthValue)
        if let length = lengthValue as? Int, length > 0 {
            var range = CFRange(location: 0, length: 1)
            if let axRange = AXValueCreate(.cfRange, &range),
                let cf = paramValue(e, "AXAttributedStringForRange", axRange),
                CFGetTypeID(cf) == CFAttributedStringGetTypeID(),
                let dict = fontAttribute(in: cf as! CFAttributedString)
            {
                return dict
            }
        }
        return nil
    }

    private func fontAttribute(in astr: CFAttributedString) -> NSDictionary? {
        guard CFAttributedStringGetLength(astr) > 0 else { return nil }
        var effective = CFRange()
        let attrs = CFAttributedStringGetAttributes(astr, 0, &effective) as NSDictionary?
        return attrs?["AXFont"] as? NSDictionary
    }

    private func frame(of e: AXUIElement) -> CGRect? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, "AXFrame" as CFString, &v) == .success,
            let axv = v, CFGetTypeID(axv) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(axv as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private func paramValue(_ e: AXUIElement, _ attr: String, _ param: AnyObject) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyParameterizedAttributeValue(e, attr as CFString, param, &v)
            == .success
            ? v : nil
    }

    private func axString(_ e: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success
            ? v as? String : nil
    }

    private func cleanFamily(_ name: String) -> String {
        name.hasPrefix(".") ? "System Font" : name
    }

    private func weight(fromName name: String?) -> String? {
        guard let n = name?.lowercased() else { return nil }
        let table: [(String, String)] = [
            ("thin", "Thin"), ("extralight", "Extralight"), ("ultralight", "Ultralight"),
            ("semibold", "Semibold"), ("demibold", "Semibold"), ("extrabold", "Extrabold"),
            ("ultrabold", "Extrabold"), ("medium", "Medium"), ("black", "Black"),
            ("heavy", "Heavy"), ("light", "Light"), ("bold", "Bold"),
            ("book", "Regular"), ("regular", "Regular"),
        ]
        for (needle, label) in table where n.contains(needle) { return label }
        return nil
    }

    static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }

    static func unionFrame() -> CGRect {
        NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
    }
}

// MARK: - Overlay view (visual only; events arrive via the event tap)

final class OverlayView: NSView {
    private var highlight: CGRect?  // view coordinates
    private var label: String?
    private var cursorPoint: CGPoint = .zero  // view coordinates

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // stay click-through

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { nil }
    override func accessibilityChildren() -> [Any]? { nil }

    /// `highlightGlobal` and `cursorGlobal` are global AppKit (bottom-left) coords.
    func update(highlight highlightGlobal: CGRect?, label: String?, cursor cursorGlobal: CGPoint) {
        guard let win = window else { return }
        if let h = highlightGlobal {
            highlight = convert(win.convertFromScreen(h), from: nil)
        } else {
            highlight = nil
        }
        cursorPoint = convert(win.convertPoint(fromScreen: cursorGlobal), from: nil)
        self.label = label
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        drawCrosshair(at: cursorPoint, color: accent)

        if let h = highlight {
            let box = h.insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            accent.withAlphaComponent(0.16).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }

        drawHUD(label ?? "Click any text to grab its font")
    }

    private func drawCrosshair(at p: CGPoint, color: NSColor) {
        let r: CGFloat = 11
        let gap: CGFloat = 3
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: CGPoint(x: p.x - r, y: p.y))
        path.line(to: CGPoint(x: p.x - gap, y: p.y))
        path.move(to: CGPoint(x: p.x + gap, y: p.y))
        path.line(to: CGPoint(x: p.x + r, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - r))
        path.line(to: CGPoint(x: p.x, y: p.y - gap))
        path.move(to: CGPoint(x: p.x, y: p.y + gap))
        path.line(to: CGPoint(x: p.x, y: p.y + r))
        path.stroke()
    }

    private func drawHUD(_ text: String) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let str = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let textSize = str.size()
        let padX: CGFloat = 10
        let padY: CGFloat = 6
        let w = textSize.width + padX * 2
        let hgt = textSize.height + padY * 2

        var x = cursorPoint.x + 18
        var y = cursorPoint.y - hgt - 18
        if x + w > bounds.maxX - 8 { x = cursorPoint.x - w - 18 }
        if y < bounds.minY + 8 { y = cursorPoint.y + 18 }

        let bg = NSBezierPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: hgt), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.80).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        str.draw(at: CGPoint(x: x + padX, y: y + padY))
    }
}
