import Foundation

/// Apps whose split panes we try to focus. Everything else gets window focus only.
/// `com.jetbrains.` prefix. `com.spotify.xirp` is a Focus addition (spike: its panes accept AX focus).
public enum PaneApps {
    public static let bundleIDs: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium", "dev.zed.Zed", "com.sublimetext.4",
        "com.apple.dt.Xcode", "com.google.android.studio",
        "com.spotify.xirp",
    ]

    public static func isAllowed(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }
}
