import LuxoClient

_ = ProfileInput(name: "Luxo", bio: nil)
_ = Record()

func inspectSelection(client: LuxoGeneratedClient) async throws {
    let record = try await client.getRecord(select: "profile { name }")
    _ = try record.profile.requireValue().map { profile in
        print(try profile.name.requireValue())
    }
}
