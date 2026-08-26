import Combine
import Foundation

@MainActor
final class PrototypeAppIntentRouter: ObservableObject {
    static let shared = PrototypeAppIntentRouter()

    @Published private(set) var armRequestID: UUID?

    private init() {}

    func requestArm() {
        armRequestID = UUID()
    }

    func consumeArmRequest(id: UUID) {
        guard armRequestID == id else { return }
        armRequestID = nil
    }
}
