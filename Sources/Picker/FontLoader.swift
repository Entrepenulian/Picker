import AppKit
import CoreText
import SwiftUI

// MARK: - Real-face loader + font finder
//
// A grabbed font usually isn't installed locally (it lives on some web page), and
// `Font.custom(family)` silently falls back to the system face — so every specimen
// would look identical. FontLoader fixes that: for any family that doesn't already
// resolve, it pulls the real face from a free web catalog (Google Fonts, then
// Fontsource on jsDelivr as a fallback) and registers it with CoreText for this
// process — CoreText loads TTF, WOFF, and WOFF2 by content, so the format doesn't
// matter. Faces are cached on disk and `ready` republishes the views.
//
// It also powers the "Find" button: a font confirmed on the free catalog deep-links
// to its Google Fonts page; everything else (commercial, foundry, or custom faces
// that aren't free to download) falls back to a web search for the family name, which
// locates the font virtually every time.

@MainActor
final class FontLoader: ObservableObject {
    /// Lowercased families whose real face now resolves (installed, or downloaded +
    /// registered this run). Publishing it re-renders the specimens that depend on it.
    @Published private(set) var ready: Set<String> = []

    /// Lowercased families confirmed to live on Google Fonts — lets "Find" deep-link
    /// straight to the specimen page. Persisted so it survives across launches.
    private var googleFonts: Set<String>
    private let googleKey = "picker.googleFonts.v1"

    /// grabbed-family (lowercased) → the family name the face ACTUALLY registered
    /// under. Some (often variable) fonts ship a named-instance family in their name
    /// table — e.g. "Bricolage Grotesque" arrives as "Bricolage Grotesque 96pt
    /// ExtraBold" — so `Font.custom(grabbedName)` would miss it. The specimen renders
    /// with this resolved name instead.
    private var renderFamily: [String: String] = [:]

    private var inFlight: Set<String> = []
    private let cacheDir: URL

    init() {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = base.appendingPathComponent("PickerFonts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true)
        googleFonts = Set(UserDefaults.standard.stringArray(forKey: googleKey) ?? [])
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

    /// The family name to actually render `family` with — its resolved registered name
    /// if it loaded under a different one, otherwise the grabbed name unchanged.
    func renderName(for family: String) -> String {
        renderFamily[family.lowercased()] ?? family
    }

    /// Where to send the user to GET this font. A confirmed Google Fonts family
    /// deep-links to its specimen page; anything else goes to a web search for the
    /// family name, which finds the font (foundry, marketplace, or free host) nearly
    /// every time — the part that makes "Find" work beyond just Google's catalog.
    func findURL(for family: String) -> URL {
        if googleFonts.contains(family.lowercased()) {
            let q = family.replacingOccurrences(of: " ", with: "+")
            if let u = URL(string: "https://fonts.google.com/specimen/\(q)") { return u }
        }
        let q =
            "\(family) font".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? family
        return URL(string: "https://www.google.com/search?q=\(q)")
            ?? URL(string: "https://www.google.com")!
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
        let file = cacheDir.appendingPathComponent(safeName(key))
        if FileManager.default.fileExists(atPath: file.path) {
            registerAndMap(file, family: family, key: key)
            return
        }
        // Google Fonts (full css2 catalog). If Google HAS it, remember it for the Find
        // deep-link even when the face fails to render (odd internal naming).
        if let url = await googleURL(family) {
            rememberGoogle(key)
            if let data = await fetchFont(url) {
                try? data.write(to: file)
                registerAndMap(file, family: family, key: key)
                if ready.contains(key) { return }
            }
        }
        // Fontsource (jsDelivr) as a resilient fallback.
        if let url = fontsourceURL(family), let data = await fetchFont(url) {
            try? data.write(to: file)
            registerAndMap(file, family: family, key: key)
        }
        // Not on any free catalog (commercial / proprietary): the specimen stays a
        // fallback, but Find still locates it via web search.
    }

    /// Register the file and record the real family name to render with.
    private func registerAndMap(_ file: URL, family: String, key: String) {
        let actual = actualFamily(of: file)
        var err: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, &err)  // ok if already registered
        if let actual, Self.resolves(actual) {
            if actual.caseInsensitiveCompare(family) != .orderedSame {
                renderFamily[key] = actual
            }
            ready.insert(key)
        } else if Self.resolves(family) {
            ready.insert(key)
        }
    }

    /// The family name the file actually carries in its name table.
    private func actualFamily(of file: URL) -> String? {
        guard
            let descs = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL)
                as? [CTFontDescriptor],
            let fam = descs.first.flatMap({
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            })
        else { return nil }
        return fam
    }

    private func rememberGoogle(_ key: String) {
        googleFonts.insert(key)
        UserDefaults.standard.set(Array(googleFonts), forKey: googleKey)
    }

    // MARK: Sources

    /// Download a font file, but only if the response is a real font (guards against
    /// 404 HTML pages and the like, which would otherwise get registered as garbage).
    private func fetchFont(_ url: URL) async -> Data? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
            (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200,
            looksLikeFont(data)
        else { return nil }
        return data
    }

    /// The Google Fonts **css2** API — the full modern catalog (the old `css` endpoint
    /// is missing newer families). A browser User-Agent makes it serve woff2, which
    /// CoreText loads fine; we accept ttf/woff/woff2 to be safe.
    private func googleURL(_ family: String) async -> URL? {
        let q = family.replacingOccurrences(of: " ", with: "+")
        guard let url = URL(string: "https://fonts.googleapis.com/css2?family=\(q)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
            let css = String(data: data, encoding: .utf8),
            let r = css.range(
                of: #"url\([^)]*\.(woff2|woff|ttf)\)"#, options: .regularExpression)
        else { return nil }
        return URL(string: String(css[r]).dropFirst(4).dropLast().description)
    }

    /// Fontsource packages the open-font catalog on jsDelivr; the regular-weight woff2
    /// follows a predictable path. A miss just 404s and we move on.
    private func fontsourceURL(_ family: String) -> URL? {
        let slug = fontsourceSlug(family)
        guard !slug.isEmpty else { return nil }
        return URL(
            string:
                "https://cdn.jsdelivr.net/npm/@fontsource/\(slug)/files/\(slug)-latin-400-normal.woff2"
        )
    }

    private func fontsourceSlug(_ family: String) -> String {
        family.lowercased().map {
            $0.isLetter || $0.isNumber ? String($0) : ($0 == " " ? "-" : "")
        }.joined()
    }

    private func safeName(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + ".font"
    }

    /// sfnt / WOFF / WOFF2 magic numbers.
    private func looksLikeFont(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let m = [UInt8](data.prefix(4))
        let tags: [[UInt8]] = [
            [0x00, 0x01, 0x00, 0x00],  // TrueType
            [0x74, 0x72, 0x75, 0x65],  // 'true'
            [0x4F, 0x54, 0x54, 0x4F],  // 'OTTO' (CFF/OpenType)
            [0x74, 0x74, 0x63, 0x66],  // 'ttcf' (collection)
            [0x77, 0x4F, 0x46, 0x46],  // 'wOFF'
            [0x77, 0x4F, 0x46, 0x32],  // 'wOF2'
        ]
        return tags.contains(m)
    }
}
