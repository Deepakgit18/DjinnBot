import DialogueCore
import SwiftUI

// MARK: - Keyboard Dismiss (swipe down)

/// Installs a downward swipe gesture to dismiss the keyboard.
/// Does not interfere with taps (toolbar dropdowns, buttons, etc.).
struct KeyboardDismissView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismiss))
        swipe.direction = .down
        swipe.cancelsTouchesInView = false
        view.addGestureRecognizer(swipe)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        @objc func dismiss() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}

/// Primary tab-based interface for the iOS Dialogue app.
struct MainView: View {
    var body: some View {
        TabView {
            RecordingTab()
                .tabItem {
                    Label("Record", systemImage: "record.circle")
                }

            MeetingsTab()
                .tabItem {
                    Label("Meetings", systemImage: "list.bullet")
                }

            NotesTab()
                .tabItem {
                    Label("Notes", systemImage: "doc.text")
                }

            ChatTab()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .background(KeyboardDismissView())
    }
}
