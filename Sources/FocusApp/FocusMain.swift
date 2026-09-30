import AppKit

@main
enum FocusMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }   // before NSApplication: no UI, no prompt
        let app = NSApplication.shared
        // LSUIElement does this for the bundle; set it in code too so `swift run Focus` has no Dock icon.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(options: LaunchOptions(args))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    var controller: AppController?
    init(options: LaunchOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController(options: options)
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.saveLearned() }
}
