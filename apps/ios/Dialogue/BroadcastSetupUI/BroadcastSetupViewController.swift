import ReplayKit
import UIKit

/// Minimal Broadcast Setup UI Extension.
/// Apple requires this extension even though we use RPSystemBroadcastPickerView
/// in the main app. This provides the standard "Start Broadcast" confirmation.
class BroadcastSetupViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = "Dialogue Meeting Recorder"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = UILabel()
        subtitle.text = "Tap Start to begin recording audio from your meeting."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let startButton = UIButton(type: .system)
        startButton.setTitle("Start Broadcast", for: .normal)
        startButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startButton.addTarget(self, action: #selector(startBroadcast), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelBroadcast), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [label, subtitle, startButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    @objc private func startBroadcast() {
        let setupInfo: [String: NSCoding & NSObjectProtocol]? = nil
        extensionContext?.completeRequest(withBroadcast: URL(string: "dialogue://broadcast")!, setupInfo: setupInfo)
    }

    @objc private func cancelBroadcast() {
        let error = NSError(domain: "bot.djinn.ios.dialogue.BroadcastSetupUI", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "User cancelled broadcast"
        ])
        extensionContext?.cancelRequest(withError: error)
    }
}
