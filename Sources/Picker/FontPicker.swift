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
        /// Set to a Chromium browser's bundle id when the family came back "Unknown"
        /// — Chromium's AX exposes size/weight but not the typeface, so we read the
        /// family from the page itself via JavaScript.
        var jsBundleID: String?
    }

    /// Chromium-family browsers whose accessibility tree omits the font family. We
    /// fall back to reading `getComputedStyle().fontFamily` from the page via the
    /// Chrome AppleScript dictionary, which these all share.
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.google.Chrome.dev", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.brave.Browser", "com.brave.Browser.beta",
        "com.brave.Browser.nightly", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    private static func isChromium(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return chromiumBrowsers.contains(b) || b.lowercased().contains("chrom")
            || b.lowercased().contains("helium")
    }

    /// Begins picking. Returns `.needsPermission` (and triggers the system prompt)
    /// when Accessibility access hasn't been granted yet.
    func start(onResult: @escaping (PickedFont?) -> Void) -> Start {
        guard ensureTrusted() else { return .needsPermission }
        // Cap every AX round-trip. An untimed AXUIElementCopyElementAtPosition can
        // block indefinitely if the app under the cursor is slow to answer — which
        // would freeze the whole picker. 0.25s is plenty for a live hit-test.
        AXUIElementSetMessagingTimeout(Self.systemWide, 0.25)
        warmChromiumAX()
        self.onResult = onResult
        present()
        return .began
    }

    /// Nudge any running Chromium browser into building its accessibility tree before
    /// the first hover. Chromium turns AX on lazily, so the very first hit test on a
    /// freshly launched browser can land on an empty web area — the text run (and its
    /// frame) only materialize once something queries the tree. A quick, bounded walk
    /// off the main thread enables AX so the hover highlight lands on the first try.
    private func warmChromiumAX() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { Self.isChromium($0.bundleIdentifier) }
            .map(\.processIdentifier)
        guard !pids.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for pid in pids {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 1.0)
                // Documented Chromium switch to force-enable AX; harmless if unsupported.
                AXUIElementSetAttributeValue(
                    app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                Self.warmWalk(app, depth: 0)
            }
        }
    }

    /// Shallow subtree touch — enough AX traffic to flip Chromium's tree on without
    /// crawling the whole page.
    nonisolated private static func warmWalk(_ e: AXUIElement, depth: Int) {
        if depth > 5 { return }
        var childrenRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &childrenRef) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children.prefix(12) { warmWalk(child, depth: depth + 1) }
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
        guard let hit = readText(atAX: ax) else {
            finish(nil)  // clicked something that isn't text → dismiss
            return
        }
        guard let bundleID = hit.jsBundleID else {
            finish(hit.font)
            return
        }
        // Chromium browser, unknown family: read the family from the page via JS. Run
        // it off the main thread (a Process call), then finish on the main actor. If JS
        // is unavailable (setting off / Automation denied) we keep the AX result.
        let fallback = hit.font
        Task.detached {
            let js = Self.fontViaJS(bundleID: bundleID, screen: ax)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let js, !js.family.isEmpty else {
                    self.finish(fallback)
                    return
                }
                self.finish(
                    PickedFont(
                        family: js.family,
                        pointSize: js.size > 0 ? js.size : fallback.pointSize,
                        weightName: js.weight ?? fallback.weightName,
                        sampleSnippet: fallback.sampleSnippet))
            }
        }
    }

    // MARK: Reading the font from a Chromium page via JavaScript

    /// Ask the browser for `getComputedStyle().fontFamily/Size/Weight` of the element
    /// at the click point, converting screen → viewport coordinates inside the page.
    /// Returns nil if JS-from-Apple-Events is off, Automation is denied, or it times out.
    nonisolated static func fontViaJS(bundleID: String, screen: CGPoint) -> (
        family: String, size: Double, weight: String?
    )? {
        let x = Int(screen.x.rounded()), y = Int(screen.y.rounded())
        // No double-quotes or backslashes in the JS, so it drops cleanly into the
        // AppleScript double-quoted string with no escaping.
        let js =
            "(function(){var x=\(x),y=\(y);"
            + "var vx=x-window.screenX,vy=y-window.screenY-(window.outerHeight-window.innerHeight);"
            + "var el=document.elementFromPoint(vx,vy);if(!el)return '';"
            + "var s=getComputedStyle(el);"
            + "return s.fontFamily+'|||'+s.fontSize+'|||'+s.fontWeight;})()"
        let script =
            "tell application id \"\(bundleID)\" to tell active tab of front window "
            + "to execute javascript \"\(js)\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2.5)
        while proc.isRunning && Date() < deadline { usleep(15_000) }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }  // JS off / denied / error
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty
        else { return nil }
        let parts = result.components(separatedBy: "|||")
        let family = firstFamily(parts.first ?? "")
        guard !family.isEmpty else { return nil }
        let size =
            parts.count > 1 ? Double(parts[1].replacingOccurrences(of: "px", with: "")) ?? 0 : 0
        let weight = parts.count > 2 ? weightLabel(parts[2]) : nil
        return (family, size, weight)
    }

    /// First concrete family in a CSS font stack (`"Helvetica Neue", Arial, sans-serif`
    /// → `Helvetica Neue`), mapping the system-font keywords to a friendly name.
    nonisolated private static func firstFamily(_ stack: String) -> String {
        guard let first = stack.split(separator: ",").first else { return "" }
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        let systemKeywords = [
            "-apple-system", "system-ui", "blinkmacsystemfont", "ui-sans-serif",
            "ui-serif", "ui-monospace", "ui-rounded",
        ]
        if systemKeywords.contains(name.lowercased()) { return "System Font" }
        return name
    }

    nonisolated private static func weightLabel(_ w: String) -> String? {
        switch w.trimmingCharacters(in: .whitespaces) {
        case "100": return "Thin"
        case "200": return "Extralight"
        case "300": return "Light"
        case "400", "normal": return "Regular"
        case "500": return "Medium"
        case "600": return "Semibold"
        case "700", "bold": return "Bold"
        case "800": return "Extrabold"
        case "900": return "Black"
        default: return nil
        }
    }

    // MARK: Accessibility reading

    private func readText(atAX ax: CGPoint) -> Hit? {
        // The system-wide hit test descends to the deepest leaf under the pointer. Our
        // overlay is click-through and accessibility-invisible, so it reads through it.
        var elem: AXUIElement?
        let hitOK =
            AXUIElementCopyElementAtPosition(Self.systemWide, Float(ax.x), Float(ax.y), &elem)
            == .success
        let hit = hitOK ? elem : nil

        var epid: pid_t = 0
        if let hit { AXUIElementGetPid(hit, &epid) }
        if epid == ownPID { return nil }  // resolved to our own overlay — ignore

        // Who owns this text, and is it a Chromium browser? Chromium needs a different
        // strategy on two fronts (geometry lookup + JS font), and crucially it must be
        // reachable even when the hit test itself returned nothing: a freshly woken Blink
        // tree answers slowly, so a cold hit test can blow the 0.25s budget and come back
        // empty. When that happens but the foreground app is Chromium, drive the lookup
        // from its app root anyway.
        var bundle =
            epid != 0 ? NSRunningApplication(processIdentifier: epid)?.bundleIdentifier : nil
        var chromium = Self.isChromium(bundle)
        if !chromium, hit == nil,
            let front = NSWorkspace.shared.frontmostApplication,
            Self.isChromium(front.bundleIdentifier)
        {
            epid = front.processIdentifier
            bundle = front.bundleIdentifier
            chromium = true
        }

        // Resolve the text run under the point.
        //  • Safari/native: the hit test lands on (or just above) the AXStaticText —
        //    descend from it.
        //  • Chromium: the hit test is unreliable — it returns a giant scroll-container
        //    AXGroup whose children don't bracket the point (or nothing at all). Locate
        //    the run by geometry from the app root instead.
        var resolved: AXUIElement?
        if let hit, !chromium {
            resolved = textLeaf(from: hit, at: ax)
        } else if chromium {
            let root = AXUIElementCreateApplication(epid)
            AXUIElementSetMessagingTimeout(root, 1.0)  // a cold Blink tree is slow to answer
            resolved =
                hit.flatMap { textLeaf(from: $0, at: ax) } ?? textRunByPosition(in: root, at: ax)
        }
        guard let textEl = resolved else { return nil }

        // Chromium's Blink tree often exposes the text run and its frame but *no* AXFont —
        // no font attribute to read at all, especially right after launch. Safari/WebKit
        // and native apps always carry AXFont, so for them a nil dictionary really means
        // "not text". For Chromium we must NOT bail: we still highlight the run and read
        // the real family from the page via JavaScript.
        let font = fontDict(at: textEl)
        if font == nil && !chromium { return nil }  // unreadable and not JS-probeable → ignore

        let family = cleanFamily(
            (font?["AXFontFamily"] as? String) ?? (font?["AXFontName"] as? String) ?? "Unknown")
        let size = (font?["AXFontSize"] as? Double) ?? 0
        let weight = weight(fromName: font?["AXFontName"] as? String)
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

        // Chromium's AX doesn't reliably report the family — flag it so commit() reads
        // the real family (and size/weight) from the page via JavaScript.
        let jsBundle = (family == "Unknown" && chromium) ? bundle : nil
        return Hit(font: picked, frame: appKitFrame, jsBundleID: jsBundle)
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

    /// Locate a text run by geometry, used for Chromium where the hit test can't be
    /// trusted to land on (or above) the run. Returns the deepest AXStaticText whose
    /// frame contains the point, searched from `root` down only the branches whose frames
    /// bracket it. Depth- and budget-capped so a pathological page can't stall a hover.
    private func textRunByPosition(in root: AXUIElement, at p: CGPoint) -> AXUIElement? {
        var budget = 1500
        return deepestTextContaining(root, p, depth: 0, budget: &budget)
    }

    private func deepestTextContaining(
        _ e: AXUIElement, _ p: CGPoint, depth: Int, budget: inout Int
    ) -> AXUIElement? {
        if depth > 60 || budget <= 0 { return nil }
        budget -= 1

        var best: AXUIElement? =
            (axString(e, "AXRole") == "AXStaticText" && (frame(of: e)?.contains(p) ?? false))
            ? e : nil

        var childrenRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(e, "AXChildren" as CFString, &childrenRef) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return best }

        for child in children {
            let f = frame(of: child)
            if f == nil || f!.contains(p) {
                if let found = deepestTextContaining(child, p, depth: depth + 1, budget: &budget) {
                    best = found
                }
            }
        }
        return best
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
