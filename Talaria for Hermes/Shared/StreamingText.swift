import SwiftUI

/// Plain-text view for live assistant output. Newly-arrived characters fade in
/// over a short window instead of popping, so the stream reads as a smooth flow
/// rather than chunks snapping into place.
///
/// Only the trailing (still-fading) characters are rendered per-glyph; everything
/// before them is emitted as a single opaque run, so per-frame cost stays small
/// even for long messages.
struct StreamingText: View {
    let text: String
    var color: Color = .primary
    var font: Font = .body

    /// How long a character takes to ramp from invisible to fully opaque.
    private let fadeDuration: Double = 0.22

    // Birth time (reference-date seconds) per character index. Monotonic:
    // appended to as the text grows, so the fading characters are always a
    // contiguous trailing range.
    @State private var births: [TimeInterval] = []
    @State private var lastText: String = ""
    @State private var settled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Honour Reduce Motion: show text immediately, no per-character fade.
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .foregroundStyle(color)
        } else {
            TimelineView(.animation(paused: settled)) { context in
                Text(attributedText(at: context.date.timeIntervalSinceReferenceDate))
                    .font(font)
                    .textSelection(.enabled)
            }
            .onChange(of: text) { _, newValue in
                syncBirths(to: newValue)
                settled = false
            }
            .onAppear { syncBirths(to: text) }
            .task(id: text) {
                // Re-pause the timeline once the latest characters have finished fading.
                try? await Task.sleep(for: .seconds(fadeDuration + 0.05))
                settled = true
            }
        }
    }

    private func attributedText(at now: TimeInterval) -> AttributedString {
        let chars = Array(text)
        guard !chars.isEmpty else { return AttributedString() }

        // First index whose fade is still in progress (everything before is opaque).
        var firstFading = chars.count
        for idx in chars.indices {
            let birth = idx < births.count ? births[idx] : now
            if now - birth < fadeDuration {
                firstFading = idx
                break
            }
        }

        var result = AttributedString()
        if firstFading > 0 {
            var opaque = AttributedString(String(chars[0..<firstFading]))
            opaque.foregroundColor = color
            result.append(opaque)
        }
        for idx in firstFading..<chars.count {
            let birth = idx < births.count ? births[idx] : now
            let progress = max(0, min(1, (now - birth) / fadeDuration))
            var run = AttributedString(String(chars[idx]))
            run.foregroundColor = color.opacity(progress)
            result.append(run)
        }
        return result
    }

    private func syncBirths(to newValue: String) {
        guard newValue != lastText else { return }
        let now = Date.timeIntervalSinceReferenceDate

        if newValue.hasPrefix(lastText) {
            let added = newValue.count - lastText.count
            if added > 0 {
                births.append(contentsOf: repeatElement(now, count: added))
            }
        } else {
            // Replaced/reset: show everything immediately (no whole-message re-fade).
            births = Array(repeating: now - fadeDuration, count: newValue.count)
        }
        lastText = newValue
    }
}
