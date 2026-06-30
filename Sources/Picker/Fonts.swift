import AppKit
import SwiftUI

// MARK: - Font value semantics
//
// A typeface the user spotted somewhere and wanted to keep. macOS has no
// system "font loupe" the way it has a color sampler, so a font is captured
// from the clipboard: when you copy styled text from Safari or Chrome the
// pasteboard carries rich text (RTF / HTML) that names the rendered font.
// We pull the dominant family out of that and remember it.

struct PickedFont: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    /// The family name as the source named it, e.g. "Helvetica Neue", "Inter".
    let family: String
    /// Point size of the dominant run, for reference.
    let pointSize: Double
    /// Best-effort weight label ("Regular", "Bold", …) when the source carried it.
    let weightName: String?
    /// A short snippet of the copied text, shown as the specimen when present.
    let sampleSnippet: String?
    let addedAt: Date

    init(
        family: String,
        pointSize: Double = 0,
        weightName: String? = nil,
        sampleSnippet: String? = nil,
        id: UUID = UUID(),
        addedAt: Date = .now
    ) {
        self.id = id
        self.family = family
        self.pointSize = pointSize
        self.weightName = weightName
        self.sampleSnippet = sampleSnippet
        self.addedAt = addedAt
    }

    /// Whether the real face is available to render — installed locally OR downloaded
    /// and registered this run by `FontLoader`. Drives the "preview approximate" note.
    /// Uses descriptor resolution (not `availableFontFamilies`, which doesn't list
    /// process-registered fonts).
    var isInstalled: Bool {
        FontLoader.resolves(family)
    }

    /// Where to go to get the font. Google Fonts search is the best single
    /// default — it resolves most web typefaces and links onward to foundries.
    var findURL: URL {
        let q = family.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? family
        return URL(string: "https://fonts.google.com/?query=\(q)")
            ?? URL(string: "https://fonts.google.com")!
    }

    var sizeWeightLabel: String {
        var parts: [String] = []
        if let weightName { parts.append(weightName) }
        if pointSize >= 1 { parts.append("\(Int(pointSize.rounded()))pt") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store
//
// The saved fonts, mirroring ColorStore: main-actor only, persists to
// UserDefaults as JSON on every change, pings onChange so the panel resizes.

@MainActor
final class FontStore: ObservableObject {
    @Published private(set) var fonts: [PickedFont] = []

    var onChange: (() -> Void)?
    var persistenceEnabled = true

    private let key = "picker.pickedFonts.v1"
    private let limit = 60

    init() { load() }

    var latest: PickedFont? { fonts.first }

    func add(_ font: PickedFont) {
        // Re-grabbing the same family moves it to the front rather than piling up.
        if let idx = fonts.firstIndex(where: {
            $0.family.caseInsensitiveCompare(font.family) == .orderedSame
        }) {
            fonts.remove(at: idx)
        }
        fonts.insert(font, at: 0)
        if fonts.count > limit { fonts.removeLast(fonts.count - limit) }
        persist()
    }

    func remove(_ font: PickedFont) {
        fonts.removeAll { $0.id == font.id }
        persist()
    }

    func clear() {
        fonts.removeAll()
        persist()
    }

    private func persist() {
        if persistenceEnabled, let data = try? JSONEncoder().encode(fonts) {
            UserDefaults.standard.set(data, forKey: key)
        }
        onChange?()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([PickedFont].self, from: data)
        else { return }
        fonts = decoded
    }
}
