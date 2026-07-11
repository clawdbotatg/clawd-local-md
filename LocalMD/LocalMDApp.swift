import SwiftUI

@main
struct LocalMDApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
        }
    }
}
