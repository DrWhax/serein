#if os(Linux)
import CLinuxSandbox
import Foundation

public enum ServiceSandbox {
    public static var realHome: String { NSHomeDirectory() }
    public static func isConfined(systemFiles: Bool = false) -> Bool {
        systemFiles ? serein_is_call_worker_confined() != 0 : serein_is_memory_worker_confined() != 0
    }

    public static func requireConfinement(_ service: String, systemFiles: Bool = false) {
        if systemFiles && service == "SignalCalling" && serein_confine_call_worker() != 0 { return }
        if systemFiles && service == "SignalCallingSocketBroker" && serein_confine_call_broker() != 0 { return }
        let memoryWorkers = ["SignalMediaDecoder", "SignalLinkPreviewParser", "SignalMessageParser", "SignalMessageParserChild"]
        if !systemFiles && memoryWorkers.contains(service) && serein_confine_memory_worker() != 0 { return }
        FileHandle.standardError.write(Data("\(service): required Linux confinement profile is unavailable\n".utf8))
        exit(78)
    }
}
#endif
