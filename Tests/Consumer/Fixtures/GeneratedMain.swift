import Foundation
import LuxoClient

let profile = ProfileInput(name: "Luxo", bio: nil)
var profileEncoder = Encoder()
try profile.writeLuxo(to: &profileEncoder)
guard profileEncoder.data == Data([4, 1, 4, 76, 117, 120, 111, 2, 0, 0]) else {
    throw LuxoError(code: 0, message: "invalid generated input wire format", name: "ConsumerError")
}
_ = Record()

func inspectSelection(client: LuxoGeneratedClient) async throws {
    let record = try await client.getRecord(select: "profile { name }")
    _ = try record.profile.requireValue().map { profile in
        print(try profile.name.requireValue())
    }
}
