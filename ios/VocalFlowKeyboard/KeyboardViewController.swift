import UIKit

/// VocalFlow keyboard — the "bounce" architecture.
///
/// iOS forbids audio capture inside keyboard extensions (both AVAudioEngine and
/// AudioQueue are denied at I/O start, even with Full Access + mic permission —
/// verified on device). So the keyboard doesn't record. Instead:
///   1. 🎤 tap → opens the VocalFlow app via the `vocalflow://` URL scheme.
///   2. The app records + streams to Deepgram, then posts the transcript to the
///      shared mailbox (`SharedTranscript`).
///   3. The user taps the system "‹ back" link (top-left) to return.
///   4. This keyboard reappears, finds the pending transcript, and inserts it.
class KeyboardViewController: UIInputViewController {

    private let micButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        if !hasFullAccess {
            statusLabel.text = "Enable “Allow Full Access” for VocalFlow in Settings → General → Keyboard, or inserted text can't come back from the app."
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        insertPendingTranscript()
    }

    // MARK: UI

    private func buildUI() {
        view.backgroundColor = UIColor(red: 0.047, green: 0.027, blue: 0.078, alpha: 1) // brand #0C0714

        statusLabel.text = "Tap the mic — VocalFlow opens, you speak, then tap ‹ to come back."
        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        micButton.setTitle("🎤  Dictate", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        micButton.setTitleColor(.white, for: .normal)
        micButton.backgroundColor = UIColor(red: 0.52, green: 0, blue: 1, alpha: 1) // brand accent #8400FF
        micButton.layer.cornerRadius = 14
        micButton.addTarget(self, action: #selector(openDictation), for: .touchUpInside)

        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.titleLabel?.font = .systemFont(ofSize: 20)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        for v in [statusLabel, micButton, nextKeyboardButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // Keyboard height: priority 999 so it doesn't fight the system's own
        // 'UIView-Encapsulated-Layout-Height' constraint on first layout.
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 240)
        heightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            heightConstraint,

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 14),
            micButton.widthAnchor.constraint(equalToConstant: 260),
            micButton.heightAnchor.constraint(equalToConstant: 66),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: Bounce out (open the app)

    @objc private func openDictation() {
        guard let url = URL(string: "vocalflow://dictate") else { return }
        statusLabel.text = "Opening VocalFlow… speak there, then tap ‹ (top-left) to come back."

        // Attempt 1: the sanctioned extension API. Keyboards historically get
        // `success == false`, but on some OS versions it just works.
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self, !success else { return }
                    self.openViaResponderChain(url)
                }
            }
        } else {
            openViaResponderChain(url)
        }
    }

    /// Keyboard extensions have no `UIApplication.shared`, but the extension
    /// process does host a UIApplication at the top of the responder chain.
    /// The legacy `openURL:` selector silently no-ops on modern iOS — the
    /// 3-argument `openURL:options:completionHandler:` is the one that works,
    /// and it can't go through `perform()` (2-arg limit), so we call its IMP.
    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                let modern = NSSelectorFromString("openURL:options:completionHandler:")
                if app.responds(to: modern) {
                    typealias OpenURLFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Any?) -> Void
                    let fn = unsafeBitCast(app.method(for: modern), to: OpenURLFn.self)
                    fn(app, modern, url as NSURL, [:] as NSDictionary, nil)
                    return
                }
                let legacy = sel_registerName("openURL:")
                if app.responds(to: legacy) {
                    app.perform(legacy, with: url)
                    return
                }
            }
            responder = current.next
        }
        statusLabel.text = "Couldn't open VocalFlow — open it from your home screen; the text will still insert when you come back."
    }

    // MARK: Bounce back (insert the result)

    private func insertPendingTranscript() {
        guard let text = SharedTranscript.consume() else { return }
        textDocumentProxy.insertText(text)
        statusLabel.text = "Inserted ✓ (\(SharedTranscript.transport))"
    }
}
