import AppKit

/// Watches the Fn (🌐) key anywhere in macOS, Wispr Flow style:
///   • hold Fn → talk, release → text is typed
///   • double-tap Fn → hands-free; tap Fn again to finish
///   • hold Fn + Control → command mode (edit the selected text by voice)
@MainActor
final class HotkeyMonitor {
    enum Event {
        case begin(command: Bool)
        case finish
        case cancel
    }

    var onEvent: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var fnDown = false
    private var downAt = Date.distantPast
    private var lastQuickTap = Date.distantPast
    private var recording = false
    private var handsFree = false

    private static let fnKeyCode: UInt16 = 63
    private let quickTap: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.45

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Called by the controller when a recording ends for another reason (e.g. menu button).
    func reset() {
        recording = false
        handsFree = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        guard isDown != fnDown else { return }
        fnDown = isDown

        if isDown {
            downAt = Date()
            if handsFree {
                handsFree = false
                recording = false
                onEvent?(.finish)
            } else if !recording {
                recording = true
                onEvent?(.begin(command: event.modifierFlags.contains(.control)))
            }
        } else {
            guard recording, !handsFree else { return }
            let held = Date().timeIntervalSince(downAt)
            if held < quickTap {
                if Date().timeIntervalSince(lastQuickTap) < doubleTapWindow {
                    // Second quick tap: keep recording, hands-free.
                    handsFree = true
                    lastQuickTap = .distantPast
                } else {
                    // A lone quick tap is probably accidental: throw it away.
                    lastQuickTap = Date()
                    recording = false
                    onEvent?(.cancel)
                }
            } else {
                recording = false
                onEvent?(.finish)
            }
        }
    }
}
