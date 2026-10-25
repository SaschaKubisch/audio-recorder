// SPDX-License-Identifier: MIT
import CoreAudio
import Foundation

/// One audio input device as CoreAudio reports it.
struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable identifier that survives unplugging and restarts. This is what the app remembers.
    let uid: String
    let name: String
    let channels: Int
    let nominalSampleRate: Double
}

/// Thin wrappers around the CoreAudio calls the app needs.
enum AudioDevices {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Listing

    /// All devices that can record, in the order CoreAudio lists them.
    static func inputDevices() -> [InputDevice] {
        allDeviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0,
                  uint32Property(id, kAudioDevicePropertyIsHidden) != 1,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            // Aggregate devices that AVAudioEngine creates for itself are not something to pick.
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return InputDevice(
                id: id,
                uid: uid,
                name: name,
                channels: channels,
                nominalSampleRate: nominalSampleRate(id) ?? 0
            )
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    // MARK: Property helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Change notifications

    /// Registers a CoreAudio property listener and removes it again on `cancel()` or deinit.
    final class Watch {
        private let objectID: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private var active = true

        fileprivate init(objectID: AudioObjectID, addr: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
            self.objectID = objectID
            self.addr = addr
            self.block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(objectID, &self.addr, DispatchQueue.main, block)
        }

        func cancel() {
            guard active else { return }
            active = false
            AudioObjectRemovePropertyListenerBlock(objectID, &addr, DispatchQueue.main, block)
        }

        deinit { cancel() }
    }

    /// The handler runs on the main queue whenever a device is added or removed.
    static func watchDeviceList(_ handler: @escaping () -> Void) -> Watch {
        Watch(objectID: systemObject, addr: address(kAudioHardwarePropertyDevices), handler: handler)
    }

    /// The handler runs on the main queue whenever the system default input changes.
    static func watchDefaultInput(_ handler: @escaping () -> Void) -> Watch {
        Watch(objectID: systemObject, addr: address(kAudioHardwarePropertyDefaultInputDevice), handler: handler)
    }

    /// The handler runs on the main queue when the device stops being alive, for example when it is unplugged.
    static func watchAlive(_ id: AudioDeviceID, _ handler: @escaping () -> Void) -> Watch {
        Watch(objectID: id, addr: address(kAudioDevicePropertyDeviceIsAlive), handler: handler)
    }
}
