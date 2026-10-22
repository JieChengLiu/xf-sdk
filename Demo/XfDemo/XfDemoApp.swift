import SwiftUI

@main
struct XfDemoApp: App {
    @StateObject private var model = DemoModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
