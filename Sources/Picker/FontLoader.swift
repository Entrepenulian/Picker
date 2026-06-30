import AppKit
import CoreText
import SwiftUI

// MARK: - Real-face loader
//
// A grabbed font usually isn't installed locally (it lives on some web page), and
// `Font.custom(family)` silently falls back to the system face when the family is
// missing — so every specimen would look identical. FontLoader fixes that: for any
// family that doesn't already resolve, it pulls the TTF from the Google Fonts CSS
// API (no key required) and registers it with CoreText for this process, so
// `Font.custom` renders the actual typeface. Downloads are cached on disk and the
// `ready` set republishes the views once a face becomes available.

@MainActor
final class FontLoader: ObservableObject {
    /// Lowercased families whose real face now resolves (installed, or downloaded +
    /// registered this run). Publishing it re-renders the specimens that depend on it.
    @Published private(set) var ready: Set<String> = []

    private var inFlight: Set<String> = []
    private let cacheDir: URL

    init() {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("PickerFonts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
    }

    /// True when `family` already resolves to its real face — not a system fallback.
    /// `availableFontFamilies` does NOT list process-registered fonts, so we check by
    /// descriptor resolution, which is what `Font.custom` actually does.
    nonisolated static func resolves(_ family: String) -> Bool {
        guard !family.isEmpty else { return false }
        let f = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: 12)
        return f?.familyName?.caseInsensitiveCompare(family) == .orderedSame
    }

    func isReady(_ family: String) -> Bool {
        ready.contains(family.lowercased()) || Self.resolves(family)
    }

    /// Make `family` renderable. No-op if it already resolves or is downloading.
    func ensure(_ family: String) {
        let key = family.lowercased()
        guard !family.isEmpty, !inFlight.contains(key), !ready.contains(key) else { return }
        if Self.resolves(family) {
            ready.insert(key)
            return
        }
        inFlight.insert(key)
        Task { await load(family, key: key) }
    }

    private func load(_ family: String, key: String) async {
        defer { inFlight.remove(key) }
        let file = cacheDir.appendingPathComponent(
            key.replacingOccurrences(of: " ", with: "_") + ".ttf")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let ttf = await ttfURL(for: family),
                let (data, _) = try? await URLSession.shared.data(from: ttf), !data.isEmpty
            else { return }
            try? data.write(to: file)
        }
        var err: Unmanaged<CFError>?
        // Returns false if it's already registered — that's fine, it still resolves.
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, &err)
        if Self.resolves(family) { ready.insert(key) }
    }

    /// Ask the Google Fonts CSS API for the regular-weight TTF. An empty User-Agent
    /// makes Google serve plain TrueType (CoreText-loadable) instead of woff2.
    private func ttfURL(for family: String) async -> URL? {
        let q = family.replacingOccurrences(of: " ", with: "+")
        guard let url = URL(string: "https://fonts.googleapis.com/css?family=\(q)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
            let css = String(data: data, encoding: .utf8),
            let r = css.range(of: #"url\([^)]*\.ttf\)"#, options: .regularExpression)
        else { return nil }
        return URL(string: String(css[r]).dropFirst(4).dropLast().description)
    }
}
