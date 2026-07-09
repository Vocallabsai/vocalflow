import UIKit

/// VocalFlow keyboard — Wispr-style background dictation.
///
/// iOS forbids audio capture inside keyboard extensions, so the keyboard never
/// records. Instead: 🎤 tap → the VocalFlow app flickers open, starts recording
/// (background-audio mode keeps it running), and bounces straight back. This
/// keyboard then acts as the remote control: it shows the live partial
/// transcript + waveform (state read from the App Group, pinged via Darwin
/// notifications) and its ✓ / ✕ send stop/cancel commands to the app. On
/// completion it inserts the transcript via `textDocumentProxy`.
class KeyboardViewController: UIInputViewController {

    private enum Mode { case idle, recording, transcribing }
    private var mode: Mode = .idle { didSet { applyMode() } }

    // Idle UI
    private let micButton = UIButton(type: .system)
    // Recording UI
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let waveformStack = UIStackView()
    private var waveTimer: Timer?
    // Shared
    private let statusLabel = UILabel()
    private let nextKeyboardButton = UIButton(type: .system)

    private var stateObserver: DarwinObserver?
    private var pollTimer: Timer?

    private let brandBg = UIColor(red: 0.047, green: 0.027, blue: 0.078, alpha: 1)   // #0C0714
    private let brandAccent = UIColor(red: 0.52, green: 0, blue: 1, alpha: 1)        // #8400FF

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        applyMode()
        stateObserver = DarwinObserver(name: SharedTranscript.stateDidChangeNote) { [weak self] in
            self?.refreshFromState()
        }
        if !hasFullAccess {
            statusLabel.text = "Enable “Allow Full Access” for VocalFlow in Settings → General → Keyboard — dictation needs it to hand text back."
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFromState()
        // Darwin pings can be missed while detached — poll as a safety net.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refreshFromState()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        stopWaveAnimation()
    }

    // MARK: State sync (the heart of the remote control)

    private func refreshFromState() {
        // A finished transcript beats everything: insert it.
        if let text = SharedTranscript.consume() {
            textDocumentProxy.insertText(text)
            SharedTranscript.clearState()
            mode = .idle
            statusLabel.text = "Inserted ✓"
            return
        }

        guard let state = SharedTranscript.readState() else {
            if mode != .idle { mode = .idle; statusLabel.text = defaultHint }
            return
        }
        let age = Date().timeIntervalSince1970 - state.date
        let stale = age > 120

        switch state.phase {
        case .recording where !stale:
            if mode != .recording { mode = .recording }
            statusLabel.text = state.partial.isEmpty ? "Listening…" : state.partial
        case .transcribing where !stale:
            if mode != .transcribing { mode = .transcribing }
            statusLabel.text = "Transcribing…"
        case .failed:
            SharedTranscript.clearState()
            mode = .idle
            statusLabel.text = state.message.isEmpty ? "Dictation failed — try again." : state.message
        default:
            if mode != .idle {
                mode = .idle
                statusLabel.text = defaultHint
            }
        }
    }

    private var defaultHint: String { "Tap the mic and just start speaking." }

    // MARK: Actions

    /// 🎤 tapped. First try the instant path: ping the app with a "start"
    /// command — if its mic is still hot from a recent dictation, recording
    /// begins in the background and we never leave this app. If no recording
    /// state shows up quickly, fall back to opening the app (the flicker).
    @objc private func micTapped() {
        statusLabel.text = "Starting…"
        SharedTranscript.sendCommand("start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            if let state = SharedTranscript.readState(),
               state.phase == .recording,
               Date().timeIntervalSince1970 - state.date < 5 {
                return   // hot start worked — refreshFromState already flipped the UI
            }
            self.openDictation()
        }
    }

    @objc private func openDictation() {
        var components = URLComponents(string: "vocalflow://dictate")!
        if let host = hostAppBundleID {
            components.queryItems = [URLQueryItem(name: "host", value: host)]
        }
        guard let url = components.url else { return }
        statusLabel.text = "Starting…"

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

    @objc private func stopTapped() {
        SharedTranscript.sendCommand("stop")
        mode = .transcribing
        statusLabel.text = "Transcribing…"
    }

    @objc private func cancelTapped() {
        SharedTranscript.sendCommand("cancel")
        SharedTranscript.clearState()
        mode = .idle
        statusLabel.text = defaultHint
    }

    // MARK: Host app detection (for auto-return)

    /// KVC never throws here because `value(forUndefinedKey:)` is overridden.
    private var hostAppBundleID: String? {
        for key in ["_hostBundleID", "hostBundleID"] {
            if let id = value(forKey: key) as? String, !id.isEmpty { return id }
        }
        return nil
    }

    override func value(forUndefinedKey key: String) -> Any? { nil }

    // MARK: Opening the app

    /// Keyboard extensions have no `UIApplication.shared`, but the extension
    /// process hosts a UIApplication at the top of the responder chain. The
    /// legacy `openURL:` selector silently no-ops on modern iOS — the 3-arg
    /// `openURL:options:completionHandler:` is the one that works, and it
    /// can't go through `perform()` (2-arg limit), so we call its IMP.
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
        statusLabel.text = "Couldn't open VocalFlow — open it from your home screen."
    }

    // MARK: UI construction

    private func buildUI() {
        view.backgroundColor = brandBg

        statusLabel.text = defaultHint
        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.numberOfLines = 3
        statusLabel.textAlignment = .center

        micButton.setTitle("🎤  Dictate", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .semibold)
        micButton.setTitleColor(.white, for: .normal)
        micButton.backgroundColor = brandAccent
        micButton.layer.cornerRadius = 14
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        cancelButton.setTitle("✕", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.backgroundColor = UIColor(white: 0.25, alpha: 1)
        cancelButton.layer.cornerRadius = 24
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        doneButton.setTitle("✓", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        doneButton.setTitleColor(.black, for: .normal)
        doneButton.backgroundColor = .white
        doneButton.layer.cornerRadius = 24
        doneButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

        waveformStack.axis = .horizontal
        waveformStack.spacing = 5
        waveformStack.alignment = .center
        waveformStack.distribution = .equalSpacing
        for _ in 0..<14 {
            let bar = UIView()
            bar.backgroundColor = brandAccent
            bar.layer.cornerRadius = 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 4).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
            waveformStack.addArrangedSubview(bar)
        }

        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.titleLabel?.font = .systemFont(ofSize: 20)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        for v in [statusLabel, micButton, cancelButton, doneButton, waveformStack, nextKeyboardButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        // Keyboard height: priority 999 so it doesn't fight the system's own
        // 'UIView-Encapsulated-Layout-Height' constraint on first layout.
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 250)
        heightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            heightConstraint,

            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 18),
            micButton.widthAnchor.constraint(equalToConstant: 260),
            micButton.heightAnchor.constraint(equalToConstant: 66),

            waveformStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            waveformStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 18),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            cancelButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 18),
            cancelButton.widthAnchor.constraint(equalToConstant: 48),
            cancelButton.heightAnchor.constraint(equalToConstant: 48),

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            doneButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 18),
            doneButton.widthAnchor.constraint(equalToConstant: 48),
            doneButton.heightAnchor.constraint(equalToConstant: 48),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    private func applyMode() {
        micButton.isHidden = mode != .idle
        let recordingControls = mode == .recording
        cancelButton.isHidden = !recordingControls
        doneButton.isHidden = !recordingControls
        waveformStack.isHidden = mode == .idle
        if mode == .recording { startWaveAnimation() } else { stopWaveAnimation() }
        if mode == .transcribing {
            // Freeze the bars small while we wait for the final text.
            waveformStack.arrangedSubviews.forEach { $0.transform = CGAffineTransform(scaleX: 1, y: 0.25) }
        }
    }

    private func startWaveAnimation() {
        guard waveTimer == nil else { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { [weak self] _ in
            guard let self else { return }
            for bar in self.waveformStack.arrangedSubviews {
                let scale = CGFloat.random(in: 0.2...1.0)
                UIView.animate(withDuration: 0.13) {
                    bar.transform = CGAffineTransform(scaleX: 1, y: scale)
                }
            }
        }
    }

    private func stopWaveAnimation() {
        waveTimer?.invalidate()
        waveTimer = nil
        waveformStack.arrangedSubviews.forEach { $0.transform = .identity }
    }
}
