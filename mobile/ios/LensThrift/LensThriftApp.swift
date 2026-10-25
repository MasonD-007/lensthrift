import SwiftUI

@main
struct LensThriftApp: App {
    var body: some Scene {
        WindowGroup {
            CaptureView()
                .preferredColorScheme(.dark)
        }
    }
}
