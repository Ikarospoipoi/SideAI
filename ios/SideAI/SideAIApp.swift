import SwiftUI

@main struct SideAIPhoneApp: App {
  @StateObject private var store = RemoteStore()
  @Environment(\.scenePhase) private var phase
  @State private var invitation: String?
  var body: some Scene {
    WindowGroup {
      RemoteHome(store: store).preferredColorScheme(.dark).tint(Color(red: 0.51, green: 0.78, blue: 0.70))
        .onAppear { store.connect() }
        .onChange(of: phase) { _, value in if value == .active { store.connect() } else if value == .background { store.suspend() } }
        .onOpenURL { invitation = $0.absoluteString }
        .sheet(isPresented: Binding(get: { invitation != nil }, set: { if !$0 { invitation = nil } })) {
          PairingView(store: store, initialURL: invitation ?? "")
        }
    }
  }
}
