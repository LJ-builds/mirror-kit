import AppKit

enum MirrorState {
    case mirroring       // scrcpy is up
    case ready           // device reachable over adb, not mirroring
    case unreachable     // can't see the device

    /// Candidates in preference order — SF Symbol availability varies by macOS
    /// version, and a nil image would leave the menu bar blank.
    func symbolNames(for device: Device) -> [String] {
        switch self {
        case .mirroring:   return device.mirroringSymbols
        case .ready:       return device.readySymbols
        case .unreachable: return ["display.trianglebadge.exclamationmark", "exclamationmark.triangle"]
        }
    }

    func label(for device: Device) -> String {
        let noun = device.supportsForceLandscape ? "Tablet" : "Phone"
        switch self {
        case .mirroring:   return "Mirroring"
        case .ready:       return "\(noun) ready"
        case .unreachable: return "\(noun) unreachable"
        }
    }
}
