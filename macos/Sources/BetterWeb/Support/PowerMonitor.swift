import Foundation
import IOKit.ps

enum ACPower {
    static func isPluggedIn() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let raw = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        let type = raw as String
        return type == (kIOPSACPowerValue as String) || type == "UPS Power"
    }
}

/// Calls `handler` on the main run loop when the Mac plugs in or unplugs.
final class PowerMonitor {
    private var loopSource: CFRunLoopSource?
    var handler: ((Bool) -> Void)?

    func start() {
        stop()
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ptr in
            guard let ptr else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ptr).takeUnretainedValue()
            monitor.handler?(ACPower.isPluggedIn())
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, info) else { return }
        let source = created.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        loopSource = source
        handler?(ACPower.isPluggedIn())
    }

    func stop() {
        if let loopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), loopSource, .commonModes)
            self.loopSource = nil
        }
    }

    deinit { stop() }
}
