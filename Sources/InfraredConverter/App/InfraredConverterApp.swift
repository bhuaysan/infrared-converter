import AppKit
import SwiftUI

@main
struct InfraredConverterApp: App {

    /// Claims a foreground activation policy before any scene is built.
    ///
    /// ## Why this is here at all
    ///
    /// A SwiftPM executable target produces a bare Mach-O binary, not an
    /// `.app` bundle. macOS decides an application's activation policy from
    /// its bundle, and a process with no `Info.plist` gets `.prohibited`:
    ///
    /// ```text
    /// Bundle.main.bundleIdentifier   nil
    /// Bundle.main.infoDictionary     empty
    /// NSApp.activationPolicy()       .prohibited (2)
    /// ```
    ///
    /// `.prohibited` means the process may not appear in the Dock, may not own
    /// the menu bar, and **may not put a window on screen**. So
    /// `swift run InfraredConverter` used to start, run, and show nothing at
    /// all — no window, no error, no log line. It looked like a hang and was
    /// not one.
    ///
    /// Asking for `.regular` is what a bundle's `Info.plist` would have asked
    /// for. It is done in `init()`, before `body` is evaluated, because the
    /// policy has to be in force by the time the `WindowGroup`'s window is
    /// created.
    ///
    /// ## What this is not
    ///
    /// Not a substitute for an application bundle. A shipping build still
    /// needs one — for the bundle identifier, the display name, the document
    /// types, the icon, code signing and entitlements — and none of that is
    /// here. This makes `swift run` usable for development; it does not make
    /// the executable a distributable application.
    ///
    /// ## What else is built here
    ///
    /// The capture-profile library, and deliberately here rather than in a
    /// view. It reads an application-owned folder, it is shared by every
    /// window, and a profile created in one window must be visible in the next
    /// without a restart — all three of which are properties of the
    /// application, not of a screen. See
    /// `docs/decisions/0021-user-capture-profile-library.md`.
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    /// The one profile library this process has.
    ///
    /// Loaded once, from Application Support, when the application starts. A
    /// location that cannot be determined, or a library that will not read, is
    /// reported through the library's own load failures and still leaves the
    /// built-in uncalibrated profile working: it is a value this build holds
    /// rather than a file it reads.
    @State private var profileLibrary = IRCaptureProfileLibrary.applicationSupport()

    /// The one creative-preset library this process has.
    ///
    /// Loaded once, from its own folder under Application Support, when the
    /// application starts. Separate from the profile library in every respect —
    /// a different folder, a different schema, a different kind of thing — and
    /// a location that cannot be determined leaves an application whose channel
    /// mixer works in full: a preset is a shortcut for reusing a mix, never
    /// something a rendering depends on. See
    /// `docs/decisions/0024-reusable-creative-presets.md`.
    @State private var presetLibrary = IRCreativePresetLibrary.applicationSupport()

    var body: some Scene {
        WindowGroup("Infrared Converter") {
            ContentView(profileLibrary: profileLibrary, presetLibrary: presetLibrary)
                // Brings the window to the front on launch. Without a bundle,
                // nothing else does: `open` is what normally activates an
                // application, and a binary started from a shell inherits no
                // such request. Harmless when the window is already frontmost.
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }
}
