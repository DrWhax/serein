import Foundation

do {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    let store = SecretServiceDatabaseKeyStore(service: "org.signalsafe.key-store-check", account: CommandLine.arguments[2])
    switch CommandLine.arguments[1] {
    case "read": try FileHandle.standardOutput.write(contentsOf: store.loadOrCreateKey())
    case "delete": try store.deleteKey()
    default: exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
