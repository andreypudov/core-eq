import Foundation

/// The handler a `StubURLProtocol` serves requests with.
typealias StubHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

/// The handler and the requests seen so far, held behind a lock because the
/// protocol is invoked off the main actor and swift-testing may still schedule
/// tests around it.
private final class StubRegistry: @unchecked Sendable {
    let lock = NSLock()
    var handler: StubHandler?
    var requests: [URLRequest] = []
}

/// A `URLProtocol` that serves canned responses, so the AutoEQ service can be
/// exercised without touching the network.
///
/// All state is static because `URLSession` instantiates the protocol itself;
/// it is guarded by an `NSLock` and marked `@unchecked Sendable` accordingly.
final class StubURLProtocol: URLProtocol {
    private static let registry = StubRegistry()

    static func setHandler(_ handler: StubHandler?) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.handler = handler
        registry.requests = []
    }

    static var requests: [URLRequest] {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.requests
    }

    private static func record(_ request: URLRequest) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.requests.append(request)
    }

    private static func handler() -> StubHandler? {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.handler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    /// An ephemeral session whose only protocol is `StubURLProtocol`.
    static func autoEQStubbed() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
