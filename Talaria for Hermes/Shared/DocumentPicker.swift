import SwiftUI
import UniformTypeIdentifiers

/// Presents UIKit's `UIDocumentPickerViewController` imperatively from a host
/// controller placed in the view hierarchy.
///
/// Two Mac Catalyst quirks drive this design:
/// 1. SwiftUI's `.fileImporter` shows the NSOpenPanel but its completion handler
///    frequently never fires, so picks silently vanish.
/// 2. Wrapping the picker as `.sheet` content doesn't bridge to the native open
///    panel either. Presenting it ourselves via `present(_:)` — the way the system
///    presents its own pickers — does work, on both iOS and Catalyst.
///
/// `asCopy: true` makes the system copy each pick into the app's own container, so
/// we read a normal local file — no security-scoped bookmarks, the other thing the
/// sandboxed Catalyst build trips over.
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var contentTypes: [UTType] = [.item]
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onFinish = { isPresented = false }

        guard isPresented, !context.coordinator.isPresenting else { return }
        context.coordinator.isPresenting = true

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator

        // Present off the current update cycle to avoid "presenting during a view
        // update" warnings and to let the host settle into the window first.
        DispatchQueue.main.async {
            host.present(picker, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void = { _ in }
        var onFinish: () -> Void = {}
        var isPresenting = false

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            isPresenting = false
            onPick(urls)
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            isPresenting = false
            onFinish()
        }
    }
}
