import SwiftUI

@main
struct KinoPubDLApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
    }
}
