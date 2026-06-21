import AppKit

// MARK: - Sampling
//
// Thin wrapper over NSColorSampler — the same magnified-pixel loupe Apple's own
// color picker uses. Showing it turns the cursor into the loupe; a click resolves
// one pixel and hands back its NSColor (nil if the user hits Escape).

@MainActor
enum ColorSampler {
    static func sample() async -> PickedColor? {
        let nsColor: NSColor? = await withCheckedContinuation { continuation in
            NSColorSampler().show { sampled in
                continuation.resume(returning: sampled)
            }
        }
        guard let nsColor else { return nil }
        return PickedColor(nsColor: nsColor)
    }
}
