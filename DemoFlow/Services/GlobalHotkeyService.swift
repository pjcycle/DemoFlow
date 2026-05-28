//
//  GlobalHotkeyService.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/8.
//

import AppKit
import Carbon
import Foundation

struct GlobalHotkeyDescriptor: Equatable {
    let id: Int
    let keyCode: Int16
    let modifiers: UInt32
    let registerGlobally: Bool

    init(
        id: Int,
        keyCode: Int16,
        modifiers: UInt32,
        registerGlobally: Bool = true
    ) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.registerGlobally = registerGlobally
    }
}

@MainActor
final class GlobalHotkeyService {
    typealias ActionResolver = (Int) -> Any?

    var shouldHandleID: ((Int) -> Bool)?
    var onHotkeyID: ((Int) -> Void)?
    var onRegistrationStatusChanged: ((Bool, String) -> Void)?

    private let signature: OSType
    private let descriptors: [GlobalHotkeyDescriptor]

    private var globalHotKeyRefs: [EventHotKeyRef?] = []
    private var registeredHotkeyIDs: Set<Int> = []
    private var globalHotKeyEnabled = false
    private var localMonitor: Any?
    private var globalFallbackMonitor: Any?
    private var hotKeyEventHandlerRef: EventHandlerRef?
    private var hotKeyEventHandlerUPP: EventHandlerUPP?
    private var lastDispatchedActionAt: CFAbsoluteTime = 0
    private var lastDispatchedActionID: Int?

    init(signature: OSType, descriptors: [GlobalHotkeyDescriptor]) {
        self.signature = signature
        self.descriptors = descriptors
    }

    @discardableResult
    func start() -> Bool {
        stop()

        let handlerReady = installHotKeyEventHandler()
        if handlerReady {
            globalHotKeyEnabled = registerGlobalHotkeys()
        } else {
            globalHotKeyEnabled = false
        }
        installMonitors(includeGlobalFallback: true)
        reportRegistrationStatus()
        return globalHotKeyEnabled
    }

    func stop() {
        unregisterGlobalHotkeys()
        removeMonitors()
        removeHotKeyEventHandler()
        globalHotKeyEnabled = false
        registeredHotkeyIDs.removeAll()
    }

    private func registerGlobalHotkeys() -> Bool {
        var refs: [EventHotKeyRef?] = []
        registeredHotkeyIDs.removeAll()

        for descriptor in descriptors {
            guard descriptor.registerGlobally else { continue }
            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: signature, id: UInt32(descriptor.id))
            let status = RegisterEventHotKey(
                UInt32(descriptor.keyCode),
                descriptor.modifiers,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr {
                refs.append(ref)
                registeredHotkeyIDs.insert(descriptor.id)
            } else {
                print("[GlobalHotkey] register failed id=\(descriptor.id) keyCode=\(descriptor.keyCode) modifiers=\(descriptor.modifiers) status=\(status)")
            }
        }

        globalHotKeyRefs = refs
        return !registeredHotkeyIDs.isEmpty
    }

    private func installHotKeyEventHandler() -> Bool {
        guard hotKeyEventHandlerRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
            return service.handleCarbonHotKeyPressed(eventRef)
        }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            userData,
            &hotKeyEventHandlerRef
        )

        if status == noErr {
            hotKeyEventHandlerUPP = handler
            return true
        }
        hotKeyEventHandlerRef = nil
        hotKeyEventHandlerUPP = nil
        return false
    }

    private func removeHotKeyEventHandler() {
        if let hotKeyEventHandlerRef {
            RemoveEventHandler(hotKeyEventHandlerRef)
            self.hotKeyEventHandlerRef = nil
        }
        hotKeyEventHandlerUPP = nil
    }

    private func unregisterGlobalHotkeys() {
        for ref in globalHotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        globalHotKeyRefs = []
    }

    private func installMonitors(includeGlobalFallback: Bool) {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if let descriptor = self.descriptor(for: event, skipRegisteredHotkeys: false),
               self.shouldProcess(descriptor.id) {
                self.dispatch(descriptor.id)
                return nil
            }
            return event
        }

        if includeGlobalFallback {
            globalFallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard
                    let self,
                    let descriptor = self.descriptor(for: event, skipRegisteredHotkeys: true),
                    self.shouldProcess(descriptor.id)
                else { return }
                self.dispatch(descriptor.id)
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalFallbackMonitor {
            NSEvent.removeMonitor(globalFallbackMonitor)
            self.globalFallbackMonitor = nil
        }
    }

    func handleEvent(_ event: NSEvent) {
        guard event.type == .systemDefined, event.subtype.rawValue == 6 else { return }

        let data = event.data1
        let hotkeyID = Int((data & 0xFFFF0000) >> 16)
        guard descriptors.contains(where: { $0.id == hotkeyID }) else {
            return
        }
        guard shouldProcess(hotkeyID) else { return }
        if isLikelyDuplicateDispatch(for: hotkeyID) {
            return
        }
        dispatch(hotkeyID)
    }

    private func descriptor(for event: NSEvent, skipRegisteredHotkeys: Bool) -> GlobalHotkeyDescriptor? {
        guard event.type == .keyDown else { return nil }

        let keyCode = Int16(event.keyCode)
        let modifiers = sanitizedModifiers(event.modifierFlags)

        guard let descriptor = descriptors.first(where: { descriptor in
            guard descriptor.keyCode == keyCode else { return false }
            let required = requiredFlags(for: descriptor.modifiers)
            return isMatch(modifiers, required: required)
        }) else {
            return nil
        }

        if skipRegisteredHotkeys,
           (!descriptor.registerGlobally || registeredHotkeyIDs.contains(descriptor.id)) {
            return nil
        }
        return descriptor
    }

    private func isMatch(_ modifiers: NSEvent.ModifierFlags, required: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control]
        return modifiers.intersection(relevant) == required.intersection(relevant)
    }

    private func sanitizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift, .capsLock])
    }

    private func requiredFlags(for carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var required: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 {
            required.insert(.command)
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            required.insert(.control)
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            required.insert(.option)
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            required.insert(.shift)
        }
        return required
    }

    private func handleCarbonHotKeyPressed(_ eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return OSStatus(eventNotHandledErr) }

        guard hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        let id = Int(hotKeyID.id)
        guard descriptors.contains(where: { $0.id == id }) else { return OSStatus(eventNotHandledErr) }
        guard shouldProcess(id) else { return OSStatus(eventNotHandledErr) }
        if isLikelyDuplicateDispatch(for: id) {
            return noErr
        }
        dispatch(id)
        return noErr
    }

    private func shouldProcess(_ id: Int) -> Bool {
        shouldHandleID?(id) ?? true
    }

    private func dispatch(_ id: Int) {
        onHotkeyID?(id)
    }

    private func reportRegistrationStatus() {
        if globalHotKeyEnabled {
            onRegistrationStatusChanged?(true, "global hotkeys registered: \(registeredHotkeyIDs.sorted())")
        } else {
            onRegistrationStatusChanged?(false, "global hotkeys unavailable, fallback to foreground key handling")
        }
    }

    private func isLikelyDuplicateDispatch(for id: Int) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            lastDispatchedActionAt = now
            lastDispatchedActionID = id
        }
        guard lastDispatchedActionID == id else { return false }
        return now - lastDispatchedActionAt < 0.08
    }
}
