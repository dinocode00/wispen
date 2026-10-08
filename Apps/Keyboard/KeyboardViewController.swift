import SwiftUI
import UIKit
import WispenCore

/// The Wispen keyboard: a big mic button that dictates into any app via the Wispen app's flow session.
final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        model = KeyboardModel(controller: self)

        let host = UIHostingController(rootView: KeyboardView(model: model, globeKey: makeGlobeKey()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        let height = view.heightAnchor.constraint(equalToConstant: 276)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.refreshContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.refreshContext()
    }

    /// The system globe key (switch keyboards; long-press for the list).
    private func makeGlobeKey() -> GlobeKey {
        GlobeKey(controller: self)
    }

    /// Keyboard extensions can't call `UIApplication.shared.open`, but the host app's UIApplication
    /// is in the responder chain. This is the same technique Wispr Flow and others use to bounce to
    /// the companion app.
    func openURL(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let imp = application.method(for: selector)
                let open = unsafeBitCast(imp, to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = r.next
        }
        model.message = "Open the Wispen app to start a session."
    }
}

/// Wraps a UIButton so it can use `handleInputModeList(from:with:)` (tap = next keyboard, hold = list).
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor.secondarySystemBackground
        button.layer.cornerRadius = 8
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        let palette = context.environment.keyPalette
        uiView.tintColor = UIColor(palette.text)
        uiView.backgroundColor = palette.softShadow ? UIColor.secondarySystemBackground : UIColor(palette.mod)
        uiView.layer.cornerRadius = palette.radius
        uiView.layer.borderColor = palette.border.map { UIColor($0).cgColor }
        uiView.layer.borderWidth = palette.border == nil ? 0 : (palette.weight == .thin ? 0.75 : 1)
    }
}
