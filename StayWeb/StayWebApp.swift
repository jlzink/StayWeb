import SwiftUI

@main
struct StayWebApp: App {
    @StateObject private var admin: AdminCodeAuthenticator
    @StateObject private var kiosk: KioskController

    init() {
        let authentication = AdminCodeAuthenticator(codes: AdminCodeStore())
        _admin = StateObject(wrappedValue: authentication)
        _kiosk = StateObject(wrappedValue: KioskController(admin: authentication))
    }

    var body: some Scene {
        WindowGroup { KioskRootView(kiosk: kiosk, admin: admin) }
    }
}
