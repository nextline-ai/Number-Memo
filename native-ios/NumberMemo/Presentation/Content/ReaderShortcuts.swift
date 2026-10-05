import SwiftUI

/// Shared by the native reader and the local WebKit media document.
enum ReaderShortcut: String, CaseIterable {
    case exit = "Escape", previous = "ArrowLeft", next = "ArrowRight"
    case menu = "m", favorite = "f", details = "i"

    var title: String {
        switch self {
        case .exit: return "Exit"
        case .previous: return "Previous"
        case .next: return "Next"
        case .menu: return "Quick Menu"
        case .favorite: return "Toggle Saved"
        case .details: return "Details"
        }
    }
    var displayKey: String {
        switch self {
        case .exit: return "Esc"
        case .previous: return "←"
        case .next: return "→"
        default: return rawValue.uppercased()
        }
    }
}

/// A viewer-scoped responder. Activate only on appearance or after a modal closes;
/// never steal focus on routine renders or while typing into a dialog.
struct ReaderKeyboardCommands: UIViewControllerRepresentable {
    let enabled: Bool
    let action: (ReaderShortcut) -> Void
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ host: Host, context: Context) {
        host.responder.action = action
        host.responder.commandsEnabled = enabled
    }
    final class Host: UIViewController {
        let responder = ShortcutResponder()
        override func loadView() { view = responder }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            responder.activate()
        }
    }
    final class ShortcutResponder: UIView {
        var action: ((ReaderShortcut) -> Void)?
        var commandsEnabled = false {
            didSet {
                if !commandsEnabled { if isFirstResponder { resignFirstResponder() } }
                else if !oldValue { activate() }
            }
        }
        override var canBecomeFirstResponder: Bool { commandsEnabled }
        override func didMoveToWindow() { super.didMoveToWindow(); activate() }
        func activate() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.commandsEnabled, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }
        override var keyCommands: [UIKeyCommand]? {
            guard commandsEnabled else { return [] }
            return ReaderShortcut.allCases.map { shortcut in
                let input: String
                switch shortcut {
                case .exit: input = UIKeyCommand.inputEscape
                case .previous: input = UIKeyCommand.inputLeftArrow
                case .next: input = UIKeyCommand.inputRightArrow
                default: input = shortcut.rawValue
                }
                let command = UIKeyCommand(title: L10n.text(shortcut.title), action: #selector(performShortcut(_:)), input: input, modifierFlags: [])
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticMirroring = false
                return command
            }
        }
        @objc private func performShortcut(_ command: UIKeyCommand) {
            guard commandsEnabled, let input = command.input else { return }
            let shortcut: ReaderShortcut?
            switch input {
            case UIKeyCommand.inputEscape: shortcut = .exit
            case UIKeyCommand.inputLeftArrow: shortcut = .previous
            case UIKeyCommand.inputRightArrow: shortcut = .next
            default: shortcut = ReaderShortcut(rawValue: input)
            }
            if let shortcut { action?(shortcut) }
        }
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        List {
            Section(L10n.text("Viewer")) {
                ForEach(ReaderShortcut.allCases, id: \.self) { command in
                    LabeledContent(L10n.text(command.title)) {
                        Text(command.displayKey).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(L10n.text("Arrow keys follow the reading direction. Shortcuts pause while a dialog or text field is open."))
                Text(L10n.text("Image viewer: click the center or right-click to open the menu. Double-click to zoom. Click the sides to turn when tap navigation is enabled."))
                Text(L10n.text("Video playback keeps its standard mouse and keyboard controls."))
            }
        }.navigationTitle(L10n.text("Keyboard & Mouse")).navigationBarTitleDisplayMode(.inline)
    }
}
