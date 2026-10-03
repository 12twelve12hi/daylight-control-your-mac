import DaylightKit
import XCTest
@testable import Daylight

/// SPEC B5 (the `clients.json` part): records carry `seenOverUSB`, survive a reload, and Forget removes them.
final class ClientRegistryTests: XCTestCase {
    private var url: URL!
    private let queue = DispatchQueue(label: "registry-test.io")

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)/Daylight/clients.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        super.tearDown()
    }

    func testLoopbackRecordsSeenOverUSBAndPersists() throws {
        let registry = ClientRegistry(fileURL: url, ioQueue: queue)
        var changes = 0
        registry.onChange = { _ in changes += 1 }
        registry.recordLoopback(id: "abc", label: "Mike's DC-1", role: "web")
        registry.flush()
        XCTAssertEqual(changes, 1)
        let record = registry.lookup(id: "abc")
        XCTAssertEqual(record?.allowed, true)
        XCTAssertEqual(record?.seenOverUSB, true)
        XCTAssertEqual(record?.lastAddress, "127.0.0.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("\"seenOverUSB\" : true"))
        let reloaded = ClientRegistry(fileURL: url, ioQueue: queue)
        XCTAssertEqual(reloaded.lookup(id: "abc"), record)
        XCTAssertTrue(reloaded.isAllowed(id: "abc"))
        reloaded.allow(id: "abc", label: "Mike's DC-1", role: "overlay", address: "192.168.1.40")
        XCTAssertEqual(reloaded.lookup(id: "abc")?.roles, ["web", "overlay"])
        XCTAssertEqual(reloaded.lookup(id: "abc")?.lastAddress, "192.168.1.40")
        XCTAssertEqual(reloaded.lookup(id: "abc")?.seenOverUSB, true, "the USB flag is never lost")
    }

    func testDenyIsSessionOnlyAndForgetRemoves() {
        let registry = ClientRegistry(fileURL: url, ioQueue: queue)
        registry.deny(id: "xyz")
        XCTAssertTrue(registry.isDeniedThisSession(id: "xyz"))
        XCTAssertNil(registry.lookup(id: "xyz"), "Not now writes nothing")
        registry.allow(id: "xyz", label: "Tablet", role: "ink", address: "10.0.0.5")
        XCTAssertFalse(registry.isDeniedThisSession(id: "xyz"))
        XCTAssertEqual(registry.all.count, 1)
        registry.forget(id: "xyz")
        registry.flush()
        XCTAssertNil(registry.lookup(id: "xyz"))
        XCTAssertTrue(registry.all.isEmpty)
        let reloaded = ClientRegistry(fileURL: url, ioQueue: queue)
        XCTAssertTrue(reloaded.all.isEmpty)
    }

    func testDefaultLocationIsApplicationSupportDaylight() {
        let path = ClientRegistry.defaultFileURL().path
        XCTAssertTrue(path.hasSuffix("/Daylight/clients.json"))
        XCTAssertTrue(path.contains("Application Support"))
    }
}
