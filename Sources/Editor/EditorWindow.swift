import AppKit
import Combine
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let model: EditorModel
    private var dirtyObserver: AnyCancellable?

    init(configURL: URL) {
        model = EditorModel(fileURL: configURL)
        let hosting = NSHostingController(rootView: ProjectsEditorView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Projects"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        window.setFrameAutosaveName("ProjectsEditor")
        super.init(window: window)
        window.delegate = self

        // objectWillChange fires before the change lands, so read isDirty on the next turn.
        dirtyObserver = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.window?.isDocumentEdited = self.model.isDirty
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasUnsavedChanges: Bool { model.isDirty }

    func show() {
        // Pick up edits made to projects.json elsewhere (including other Macs), unless there's unsaved work here.
        if !(window?.isVisible ?? false), !model.isDirty { model.pullAndLoad() }
        // The picker hides the app when it closes; this may run just after.
        NSApp.unhide(nil)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your projects?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return !model.isDirty
        case .alertThirdButtonReturn:
            model.load()
            return true
        default:
            return false
        }
    }
}
