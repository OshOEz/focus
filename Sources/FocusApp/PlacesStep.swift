import Combine
import SwiftUI
import FocusMac

/// Optional onboarding step: lets Focus read the Wi-Fi name, which macOS only reveals to apps allowed to use
/// Location. The only place in Focus that can show the Location prompt.
struct PlacesStep: View {
    var next: () -> Void
    @State private var status = Permissions.location
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recognise your places").font(.title2.bold())
            Text("Focus keeps a separate calibration for each place you work: your desk, the office, a friend's flat. It recognises a place by its screens and camera and loads the right calibration by itself.")
            Text("If you use the same screens in two places, the Wi-Fi network name tells them apart. macOS only shares that name with apps allowed to use Location. Focus reads the network name and nothing else. It never asks for your position, and nothing leaves your Mac.")
                .foregroundStyle(.secondary)
            switch status {
            case .granted:
                Label("Focus can read the Wi-Fi name", systemImage: "checkmark.circle.fill")
            case .denied:
                HStack {
                    Text("Location is off for Focus.")
                    Button("Open System Settings") { Permissions.openSettings(.location) }
                }
            case .notDetermined:
                Button("Allow Wi-Fi Name") { Permissions.requestLocation() }
            }
            HStack {
                Spacer()
                Button(status == .granted ? "Continue" : "Skip") { next() }.keyboardShortcut(.defaultAction)
            }
        }
        .onReceive(poll) { _ in status = Permissions.location }
    }
}
