import AppKit
import SwiftUI

@main
struct AppSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        #if DEBUG
        _model = StateObject(wrappedValue: QASmoke.makeModel() ?? AppModel())
        #else
        _model = StateObject(wrappedValue: AppModel())
        #endif
    }

    var body: some Scene {
        WindowGroup("AppSweep") {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 620)
                .onAppear { delegate.model = model }
                .task {
                    await model.load()
                    #if DEBUG
                    await QASmoke.run(model: model)
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Choose application")) { model.chooseApplication() }
                    .keyboardShortcut("o")
                    .disabled(model.isRemoving)
            }
            CommandGroup(after: .newItem) {
                Button(L("Refresh")) { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.isRemoving || model.isLoading)
            }
            CommandGroup(replacing: .help) {
                Button(L("Permissions")) { model.showPermissions = true }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.isRemoving == true ? .terminateCancel : .terminateNow
    }
}
