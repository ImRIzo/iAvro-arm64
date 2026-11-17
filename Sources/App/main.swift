import Cocoa
@preconcurrency import InputMethodKit

// Entry point for the Avro Keyboard input method.
//
// The original project loaded an Interface Builder NIB (MainMenu.nib) to
// create the app delegate and the input-menu. NIB/XIB files need Xcode's
// `ibtool` to compile, so this port builds everything in code instead —
// that lets the whole app be built with just the Command Line Tools.

MainActor.assumeIsolated {
    // Initialize parsers
    _ = AvroParser.shared
    _ = SuggestionEngine.shared

    // Register default preferences from preferences.plist
    IMPreferences.initializeDefaults()

    // Initialize IMK server
    let connectionName = (Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String)
        ?? "Avro_Keyboard_Connection"
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        fatalError("No bundle identifier")
    }
    guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
        fatalError("Failed to create IMKServer")
    }

    // Initialize candidates panel
    CandidatesPanel.initialize(with: server)

    // App delegate + input menu (replaces MainMenu.nib)
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    appDelegate.imPref = IMPreferences()
    appDelegate.loadResources()
    app.delegate = appDelegate   // NSApplication.delegate is weak — keep our own reference alive below

    // Run the application (blocks until exit)
    withExtendedLifetime((server, appDelegate)) {
        app.run()
    }
}
