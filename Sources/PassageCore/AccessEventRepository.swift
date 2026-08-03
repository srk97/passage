public protocol AccessEventRepository: Sendable {
    func recordAccessEvent(_ event: AccessEvent) async throws
    func accessEvents(limit: Int) async throws -> [AccessEvent]

    @discardableResult
    func clearAccessEvents() async throws -> Int
}
