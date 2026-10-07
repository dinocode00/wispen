import SwiftUI
import WispenCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension View {
    /// Small-title navigation bars on iOS; no-op on macOS.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func sentenceCapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }

    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

extension Color {
    static let wispenAccent = Color(red: 0.42, green: 0.36, blue: 0.95)
}

/// Animated bars driven by the input level.
struct LevelMeter: View {
    var level: Float
    var bars = 5
    var color: Color = .wispenAccent

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let shape = 1 - abs(Double(i) - Double(bars - 1) / 2) / Double(bars)
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: max(4, CGFloat(Double(level) * 28 * shape + 4)))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct StatusBadge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
