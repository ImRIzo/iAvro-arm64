import Cocoa
import os

@objc(MainMenuAppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.omicronlab.avro", category: "AppDelegate")

    /// Menu shown under the Avro entry in the menu-bar input menu.
    @objc let menu: NSMenu

    @objc var imPref: IMPreferences?

    override init() {
        self.menu = AppDelegate.makeInputMenu()
        super.init()
    }

    /// Builds the input-source menu in code (previously defined in MainMenu.nib).
    private static func makeInputMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu")
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(AvroKeyboardController.showPreferences(_:)),
            keyEquivalent: ""
        )
        prefsItem.tag = 1
        menu.addItem(prefsItem)
        return menu
    }

    /// Loads dictionary data (previously done in awakeFromNib).
    func loadResources() {
        if UserDefaults.standard.bool(for: .includeDictionary) {
            Self.log.info("Loading Dictionary...")
            _ = Database.shared
            _ = RegexParser.shared
            _ = CacheManager.shared
        }
        _ = AutoCorrect.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        if UserDefaults.standard.bool(for: .includeDictionary) {
            CacheManager.shared.persist(synchronously: true)
        }
    }
}
