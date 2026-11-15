import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// Private but stable API used by most window managers (Rectangle, yabai, ...)
// to map an Accessibility window element to its window server id.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Log

private let logURL = FileManager.default.homeDirectoryForCurrentUser
	.appendingPathComponent("Library/Logs/YouShallNotMove.log")
private let logQueue = DispatchQueue(label: "youshallnotmove.log")

/// Appends a line to ~/Library/Logs/YouShallNotMove.log, off the event tap thread.
func writeLog(_ message: String) {
	let line = "\(Date()) \(message)\n"
	logQueue.async {
		guard let data = line.data(using: .utf8) else {
			return
		}
		if let handle = try? FileHandle(forWritingTo: logURL) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			try? data.write(to: logURL)
		}
	}
}

// MARK: - Localization

/// Translates a menu text. English is the key and the default; fr.lproj holds French.
func localized(_ english: String) -> String {
	NSLocalizedString(english, comment: "")
}

// MARK: - Settings

enum Modifier: String, CaseIterable {
	case command, option, control, shift

	var flag: CGEventFlags {
		switch self {
		case .command: return .maskCommand
		case .option: return .maskAlternate
		case .control: return .maskControl
		case .shift: return .maskShift
		}
	}

	var title: String {
		switch self {
		case .command: return localized("⌘ Command")
		case .option: return localized("⌥ Option")
		case .control: return localized("⌃ Control")
		case .shift: return localized("⇧ Shift")
		}
	}
}

final class Settings {
	private let defaults = UserDefaults.standard

	var enabled: Bool {
		get { defaults.object(forKey: "enabled") as? Bool ?? true }
		set { defaults.set(newValue, forKey: "enabled") }
	}

	/// Swallow the drag as soon as the window starts moving, instead of only snapping back on release.
	var blockDuringDrag: Bool {
		get { defaults.object(forKey: "blockDuringDrag") as? Bool ?? true }
		set { defaults.set(newValue, forKey: "blockDuringDrag") }
	}

	var modifier: Modifier {
		get { Modifier(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .command }
		set { defaults.set(newValue.rawValue, forKey: "modifier") }
	}

	/// Volume of the refusal sound, from 0 to 1.
	var soundVolume: Float {
		get { defaults.object(forKey: "soundVolume") as? Float ?? 0.5 }
		set { defaults.set(newValue, forKey: "soundVolume") }
	}

	var refusalSound: RefusalSound {
		get { RefusalSound(rawValue: defaults.string(forKey: "refusalSound") ?? "") ?? .denied }
		set { defaults.set(newValue.rawValue, forKey: "refusalSound") }
	}

	/// The system-wide shortcut that turns the lock on or off. nil when the user chose None.
	var toggleShortcut: Shortcut? {
		get {
			if defaults.bool(forKey: "toggleShortcutOff") {
				return nil
			}
			guard
				let saved = defaults.dictionary(forKey: "toggleShortcut"),
				let keyCode = saved["keyCode"] as? Int,
				let modifiers = saved["modifiers"] as? Int,
				let key = saved["key"] as? String
			else {
				return .standard
			}
			return Shortcut(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)), key: key)
		}
		set {
			defaults.set(newValue == nil, forKey: "toggleShortcutOff")
			if let shortcut = newValue {
				defaults.set([
					"keyCode": Int(shortcut.keyCode),
					"modifiers": Int(shortcut.modifiers.rawValue),
					"key": shortcut.key,
				], forKey: "toggleShortcut")
			}
		}
	}
}

// MARK: - Refusal sound

/// Played when a window move is refused. The sci-fi beeps are synthesized by Sounds/make-sounds.py.
enum RefusalSound: String, CaseIterable {
	case none, denied, bwoop, tripleBeep, forceField, funk, basso, bottle, frog, pop

	var title: String {
		switch self {
		case .none: return localized("None")
		case .denied: return localized("Access denied")
		case .bwoop: return localized("Bwoop")
		case .tripleBeep: return localized("Triple beep")
		case .forceField: return localized("Force field")
		default: return systemSoundName
		}
	}

	/// Name of a macOS system sound, in /System/Library/Sounds.
	private var systemSoundName: String {
		rawValue.prefix(1).uppercased() + rawValue.dropFirst()
	}

	/// The sci-fi beeps ship with the app; the others are macOS system sounds.
	private var isBundled: Bool {
		switch self {
		case .denied, .bwoop, .tripleBeep, .forceField: return true
		default: return false
		}
	}

	private static var cache: [RefusalSound: NSSound] = [:]

	private func load() -> NSSound? {
		if self == .none {
			return nil
		}
		if isBundled {
			guard let url = Bundle.main.url(forResource: rawValue, withExtension: "wav") else {
				return nil
			}
			return NSSound(contentsOf: url, byReference: true)
		}
		return NSSound(named: NSSound.Name(systemSoundName))
	}

	func play(volume: Float) {
		guard let sound = RefusalSound.cache[self] ?? load() else {
			return
		}
		RefusalSound.cache[self] = sound
		sound.stop()
		sound.volume = volume
		sound.play()
	}
}

// MARK: - Window tracking

struct TrackedWindow {
	let id: CGWindowID
	let pid: pid_t
	let frame: CGRect
}

/// Window server layers of app windows: normal ones (0) up to "always on top" ones (floating, 3).
/// Higher layers are the Dock, the menu bar, menus and other system windows.
private let appWindowLayers = 0...Int(CGWindowLevelForKey(.floatingWindow))

private func isAppWindow(_ info: [String: Any]) -> Bool {
	guard let layer = info[kCGWindowLayer as String] as? Int else {
		return false
	}
	return appWindowLayers.contains(layer)
}

private func windowsContaining(_ point: CGPoint) -> [TrackedWindow] {
	let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
	guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
		return []
	}
	let ownPid = ProcessInfo.processInfo.processIdentifier
	var result: [TrackedWindow] = []
	for info in list {
		guard
			isAppWindow(info),
			let pid = info[kCGWindowOwnerPID as String] as? pid_t,
			pid != ownPid,
			let id = info[kCGWindowNumber as String] as? CGWindowID,
			let bounds = info[kCGWindowBounds as String] as? NSDictionary,
			let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
			frame.contains(point)
		else {
			continue
		}
		result.append(TrackedWindow(id: id, pid: pid, frame: frame))
	}
	return result
}

private func currentFrames(of windows: [TrackedWindow]) -> [CGWindowID: CGRect] {
	var ids: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(bitPattern: UInt($0.id)) }
	guard
		let array = CFArrayCreate(nil, &ids, ids.count, nil),
		let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
	else {
		return [:]
	}
	var frames: [CGWindowID: CGRect] = [:]
	for info in list {
		guard
			let id = info[kCGWindowNumber as String] as? CGWindowID,
			let bounds = info[kCGWindowBounds as String] as? NSDictionary,
			let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
		else {
			continue
		}
		frames[id] = frame
	}
	return frames
}

private func axWindow(for window: TrackedWindow) -> AXUIElement? {
	let app = AXUIElementCreateApplication(window.pid)
	AXUIElementSetMessagingTimeout(app, 0.3)
	var value: CFTypeRef?
	guard
		AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
		let elements = value as? [AXUIElement]
	else {
		return nil
	}
	for element in elements {
		var id: CGWindowID = 0
		if _AXUIElementGetWindow(element, &id) == .success, id == window.id {
			return element
		}
	}
	return nil
}

private func setFrame(_ frame: CGRect, of element: AXUIElement, includeSize: Bool) {
	var origin = frame.origin
	if let position = AXValueCreate(.cgPoint, &origin) {
		AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
	}
	guard includeSize else {
		return
	}
	var size = frame.size
	if let sizeValue = AXValueCreate(.cgSize, &size) {
		AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
	}
	// A resize can be clamped by the screen, so set the position again.
	if let position = AXValueCreate(.cgPoint, &origin) {
		AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
	}
}

// MARK: - Drag guard

final class DragGuard {
	private let settings: Settings
	private var tap: CFMachPort?
	private let axQueue = DispatchQueue(label: "youshallnotmove.ax")

	// State of the current left-button gesture. Only touched on the main thread.
	private var candidates: [TrackedWindow] = []
	private var startPoint = CGPoint.zero
	private var lastPoint = CGPoint.zero
	private var dragged = false
	private var unlocked = false
	private var blocking = false
	private var restorePending = false
	/// Flags of a title bar mouse-down that was held back, until the button is released.
	private var heldDown: CGEventFlags?
	/// The refusal sound already played for this gesture.
	private var refusalSignaled = false

	/// Marks the clicks this app replays, so its own tap lets them through.
	private let replayMarker: Int64 = 0x574C4F43
	/// A held-back click that moved less than this is replayed; a longer move is a cancelled drag.
	private let clickTolerance: CGFloat = 4

	/// Gestures starting this close to a window edge are resizes: leave them alone.
	private let edgeMargin: CGFloat = 6
	/// A size change after a drag this long is a tile (drag to screen edge), not an app resize.
	private let tileMinDistance: CGFloat = 30
	/// Title bars and unified toolbars fit in this band at the top of a window.
	private let titleBandHeight: CGFloat = 60
	private let systemWide = AXUIElementCreateSystemWide()

	init(settings: Settings) {
		self.settings = settings
		// The hit test runs inside the event tap: never wait long for a busy app.
		AXUIElementSetMessagingTimeout(systemWide, 0.05)
	}

	var isRunning: Bool {
		tap != nil
	}

	func start() -> Bool {
		if tap != nil {
			return true
		}
		let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
		let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
		let callback: CGEventTapCallBack = { _, type, event, refcon in
			let guardian = Unmanaged<DragGuard>.fromOpaque(refcon!).takeUnretainedValue()
			return guardian.handle(type: type, event: event)
		}
		guard let port = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: mask,
			callback: callback,
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else {
			return false
		}
		let source = CFMachPortCreateRunLoopSource(nil, port, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
		CGEvent.tapEnable(tap: port, enable: true)
		tap = port
		writeLog("event tap started")
		return true
	}

	private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
		let pass = Unmanaged.passUnretained(event)
		// Clicks replayed by this app go through untouched.
		if event.getIntegerValueField(.eventSourceUserData) == replayMarker {
			return pass
		}
		switch type {
		case .tapDisabledByTimeout, .tapDisabledByUserInput:
			if let tap {
				CGEvent.tapEnable(tap: tap, enable: true)
			}
			return pass

		case .leftMouseDown:
			resetGesture()
			guard settings.enabled else {
				return pass
			}
			if event.flags.contains(settings.modifier.flag) {
				unlocked = true
				return pass
			}
			// Double-click on a title bar zooms the window: not a drag.
			if event.getIntegerValueField(.mouseEventClickState) >= 2 {
				return pass
			}
			startPoint = event.location
			lastPoint = startPoint
			candidates = windowsContaining(startPoint)
				.filter { !isNearEdge(startPoint, of: $0.frame) }
			// The window server moves a window by itself once it receives the mouse-down on a
			// title bar: swallowing the drag events is too late. Hold the mouse-down back instead,
			// and replay it as a plain click on release.
			if settings.blockDuringDrag, !candidates.isEmpty, hitsTitleBar(startPoint) {
				heldDown = event.flags
				writeLog("title bar click: mouse-down held back")
				return nil
			}
			return pass

		case .leftMouseDragged:
			if heldDown != nil {
				let distance = hypot(event.location.x - startPoint.x, event.location.y - startPoint.y)
				if distance > clickTolerance {
					signalRefusal()
				}
				return nil
			}
			guard !candidates.isEmpty, !unlocked else {
				return pass
			}
			if event.flags.contains(settings.modifier.flag) {
				unlocked = true
				blocking = false
				return pass
			}
			dragged = true
			lastPoint = event.location
			if blocking {
				restore(movedWindows(), includeSize: false)
				return nil
			}
			guard settings.blockDuringDrag else {
				return pass
			}
			let moved = movedWindows()
			if moved.isEmpty {
				return pass
			}
			blocking = true
			writeLog("window moved: drag ended early")
			// The window server keeps moving the window until it sees the button go up:
			// release it now, then swallow the rest of the gesture.
			postMouseUp(at: event.location, flags: event.flags)
			restore(moved, includeSize: false)
			signalRefusal()
			return nil

		case .leftMouseUp:
			if let flags = heldDown {
				let distance = hypot(event.location.x - startPoint.x, event.location.y - startPoint.y)
				// A tiny move is a click with a shaky hand: replay it where it started.
				// A real drag is just cancelled.
				if distance <= clickTolerance {
					replayClick(at: startPoint, flags: flags)
				}
				resetGesture()
				return nil
			}
			if dragged, !unlocked, !candidates.isEmpty {
				let snapshot = candidates
				let distance = hypot(event.location.x - startPoint.x, event.location.y - startPoint.y)
				let signaled = refusalSignaled
				// Check twice: right away, then after a possible tiling animation.
				for (index, delay) in [0.05, 0.6].enumerated() {
					DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
						self?.restoreAfterRelease(snapshot, dragDistance: distance, playSound: !signaled && index == 0)
					}
				}
			}
			// The button was already released for the app when the drag ended early.
			let alreadyReleased = blocking && !unlocked
			resetGesture()
			return alreadyReleased ? nil : pass

		default:
			return pass
		}
	}

	/// Posts a mouse-down and mouse-up at the point, so the window still gets activated.
	private func replayClick(at point: CGPoint, flags: CGEventFlags) {
		for type in [CGEventType.leftMouseDown, .leftMouseUp] {
			guard let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
				continue
			}
			click.flags = flags
			click.setIntegerValueField(.mouseEventClickState, value: 1)
			click.setIntegerValueField(.eventSourceUserData, value: replayMarker)
			click.post(tap: .cgSessionEventTap)
		}
	}

	private func postMouseUp(at point: CGPoint, flags: CGEventFlags) {
		guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
			return
		}
		up.flags = flags
		up.setIntegerValueField(.mouseEventClickState, value: 1)
		up.setIntegerValueField(.eventSourceUserData, value: replayMarker)
		up.post(tap: .cgSessionEventTap)
	}

	/// Plays the refusal sound once per gesture, outside the event tap callback.
	private func signalRefusal() {
		if refusalSignaled {
			return
		}
		refusalSignaled = true
		let sound = settings.refusalSound
		let volume = settings.soundVolume
		DispatchQueue.main.async {
			sound.play(volume: volume)
		}
	}

	private func resetGesture() {
		heldDown = nil
		refusalSignaled = false
		candidates = []
		dragged = false
		unlocked = false
		blocking = false
	}

	private func isNearEdge(_ point: CGPoint, of frame: CGRect) -> Bool {
		return point.x - frame.minX < edgeMargin
			|| frame.maxX - point.x < edgeMargin
			|| point.y - frame.minY < edgeMargin
			|| frame.maxY - point.y < edgeMargin
	}

	/// True when the point is on an empty title bar or toolbar area, where a drag moves the window.
	/// Accessibility reports the window itself for a native title bar, and the toolbar for its empty parts.
	/// Other cases (custom title bars, SwiftUI) fall back to detecting the move after the first pixel.
	private func hitsTitleBar(_ point: CGPoint) -> Bool {
		let inTopBand = candidates.contains { point.y - $0.frame.minY <= titleBandHeight }
		guard inTopBand else {
			return false
		}
		var hit: AXUIElement?
		guard
			AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
			let hit
		else {
			return false
		}
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &value) == .success else {
			return false
		}
		let role = value as? String
		return role == kAXWindowRole || role == kAXToolbarRole
	}

	/// Windows of the current gesture that moved without changing size.
	private func movedWindows() -> [TrackedWindow] {
		let frames = currentFrames(of: candidates)
		return candidates.filter { window in
			guard let now = frames[window.id] else {
				return false
			}
			return now.size == window.frame.size && now.origin != window.frame.origin
		}
	}

	private func restoreAfterRelease(_ windows: [TrackedWindow], dragDistance: CGFloat, playSound: Bool) {
		let frames = currentFrames(of: windows)
		var toRestore: [TrackedWindow] = []
		var resized = false
		for window in windows {
			guard let now = frames[window.id], now != window.frame else {
				continue
			}
			if now.size == window.frame.size {
				toRestore.append(window)
			} else if dragDistance >= tileMinDistance {
				toRestore.append(window)
				resized = true
			}
		}
		if toRestore.isEmpty {
			return
		}
		writeLog("restoring \(toRestore.count) window(s) after release")
		if playSound {
			settings.refusalSound.play(volume: settings.soundVolume)
		}
		restore(toRestore, includeSize: resized, force: true)
	}

	private func restore(_ windows: [TrackedWindow], includeSize: Bool, force: Bool = false) {
		if windows.isEmpty || (restorePending && !force) {
			return
		}
		restorePending = true
		axQueue.async {
			for window in windows {
				guard let element = axWindow(for: window) else {
					continue
				}
				setFrame(window.frame, of: element, includeSize: includeSize)
			}
			DispatchQueue.main.async {
				self.restorePending = false
			}
		}
	}
}

// MARK: - Toggle shortcut

/// A key with modifiers, recorded by the user to turn the lock on or off.
struct Shortcut: Equatable {
	let keyCode: UInt32
	/// Only command, option, control and shift.
	let modifiers: NSEvent.ModifierFlags
	/// The key as shown in the menu, such as "L" or "F5".
	let key: String

	static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [.control, .option, .command], key: "L")

	private static let functionKeys: [Int] = [
		kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
		kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
	]

	private static let namedKeys: [Int: String] = [
		kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
		kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
		kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
	]

	/// The shortcut typed in the recorder. nil when it has no ⌘, ⌥ or ⌃ and isn't a function key:
	/// a plain key would fire while typing.
	static func recorded(from event: NSEvent) -> Shortcut? {
		let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
		let code = Int(event.keyCode)
		let key: String
		if let index = functionKeys.firstIndex(of: code) {
			key = "F\(index + 1)"
		} else if let name = namedKeys[code] {
			key = name
		} else if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty {
			key = characters
		} else {
			return nil
		}
		let isFunctionKey = key.hasPrefix("F") && key.count > 1 && Int(key.dropFirst()) != nil
		guard isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty else {
			return nil
		}
		return Shortcut(keyCode: UInt32(code), modifiers: modifiers, key: key)
	}

	/// "⌃⌥⇧⌘L", in the order macOS shows them.
	var title: String {
		var text = ""
		if modifiers.contains(.control) { text += "⌃" }
		if modifiers.contains(.option) { text += "⌥" }
		if modifiers.contains(.shift) { text += "⇧" }
		if modifiers.contains(.command) { text += "⌘" }
		return text + key
	}

	/// The menu item's key equivalent, so the menu shows the shortcut next to the toggle.
	/// Empty for keys a menu can't show, like the arrows: the submenu still names them.
	var keyEquivalent: String {
		if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...20).contains(number) {
			return String(Character(UnicodeScalar(NSF1FunctionKey + number - 1)!))
		}
		return key.count == 1 ? key.lowercased() : ""
	}

	fileprivate var carbonModifiers: UInt32 {
		var flags = 0
		if modifiers.contains(.command) { flags |= cmdKey }
		if modifiers.contains(.option) { flags |= optionKey }
		if modifiers.contains(.control) { flags |= controlKey }
		if modifiers.contains(.shift) { flags |= shiftKey }
		return UInt32(flags)
	}
}

/// A system-wide shortcut through Carbon hot keys, which need no extra permission.
final class HotKey {
	private let action: () -> Void
	private var hotKey: EventHotKeyRef?
	private var handler: EventHandlerRef?

	init(action: @escaping () -> Void) {
		self.action = action
		var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
			guard let userData else {
				return OSStatus(eventNotHandledErr)
			}
			Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
			return noErr
		}, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
	}

	/// Replaces the shortcut. Returns false when macOS refuses it, usually because another app has it.
	@discardableResult
	func register(_ shortcut: Shortcut?) -> Bool {
		unregister()
		guard let shortcut else {
			return true
		}
		let id = EventHotKeyID(signature: OSType(0x5953_4E4D), id: 1) // "YSNM"
		let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
		guard status == noErr else {
			hotKey = nil
			writeLog("shortcut \(shortcut.title) refused: \(status)")
			return false
		}
		return true
	}

	func unregister() {
		if let hotKey {
			UnregisterEventHotKey(hotKey)
		}
		hotKey = nil
	}
}

/// A small window that waits for the new shortcut. Esc, closing it or clicking elsewhere cancels.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
	private var panel: NSPanel?
	private var monitor: Any?
	private let hint = NSTextField(wrappingLabelWithString: "")
	/// Tries the shortcut; false keeps the window open with a message.
	private var accept: ((Shortcut) -> Bool)?
	private var finished: (() -> Void)?

	func start(accept: @escaping (Shortcut) -> Bool, finished: @escaping () -> Void) {
		if let panel {
			NSApp.activate(ignoringOtherApps: true)
			panel.makeKeyAndOrderFront(nil)
			return
		}
		self.accept = accept
		self.finished = finished

		let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
		                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
		panel.title = localized("Toggle shortcut")
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		panel.level = .floating
		panel.delegate = self

		let prompt = NSTextField(labelWithString: localized("Press the new shortcut."))
		prompt.font = .systemFont(ofSize: 15, weight: .semibold)
		hint.stringValue = localized("Use ⌘, ⌥ or ⌃ with a key, or a function key. Esc cancels.")
		hint.textColor = .secondaryLabelColor
		hint.alignment = .center
		hint.preferredMaxLayoutWidth = 320
		let stack = NSStackView(views: [prompt, hint])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
		panel.contentView = stack

		monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			self?.handle(event)
			return nil
		}
		self.panel = panel
		panel.center()
		NSApp.activate(ignoringOtherApps: true)
		panel.makeKeyAndOrderFront(nil)
	}

	private func handle(_ event: NSEvent) {
		let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
		if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
			panel?.close()
			return
		}
		guard let shortcut = Shortcut.recorded(from: event) else {
			hint.stringValue = localized("Add ⌘, ⌥ or ⌃, or use a function key.")
			NSSound.beep()
			return
		}
		if accept?(shortcut) == true {
			panel?.close()
		} else {
			hint.stringValue = String(format: localized("%@ is already used by another app. Try another one."), shortcut.title)
			NSSound.beep()
		}
	}

	func windowDidResignKey(_ notification: Notification) {
		panel?.close()
	}

	func windowWillClose(_ notification: Notification) {
		if let monitor {
			NSEvent.removeMonitor(monitor)
		}
		monitor = nil
		panel = nil
		accept = nil
		let done = finished
		finished = nil
		done?()
	}
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
	private let settings = Settings()
	private lazy var dragGuard = DragGuard(settings: settings)
	private var statusItem: NSStatusItem!
	private var permissionTimer: Timer?
	private lazy var hotKey = HotKey { [weak self] in
		self?.toggle(fromShortcut: true)
	}
	private let recorder = ShortcutRecorder()
	/// False when macOS refused the saved shortcut, usually because another app has it.
	private var shortcutActive = true
	/// The menu's key equivalent and the hot key can both fire while the menu is open.
	private var lastToggle = Date.distantPast

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		registerShortcut()
		rebuildMenu()
		startWhenTrusted(prompt: true)
	}

	private func registerShortcut() {
		shortcutActive = hotKey.register(settings.toggleShortcut)
	}

	private func startWhenTrusted(prompt: Bool) {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
		if AXIsProcessTrustedWithOptions(options), dragGuard.start() {
			permissionTimer?.invalidate()
			permissionTimer = nil
			rebuildMenu()
			return
		}
		guard permissionTimer == nil else {
			return
		}
		permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
			guard let self else {
				return
			}
			if AXIsProcessTrusted(), self.dragGuard.start() {
				self.permissionTimer?.invalidate()
				self.permissionTimer = nil
				self.rebuildMenu()
			}
		}
	}

	private func rebuildMenu() {
		let locked = settings.enabled && dragGuard.isRunning
		let symbol = locked ? "lock.fill" : "lock.open"
		let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "YouShallNotMove")
		image?.isTemplate = true
		statusItem.button?.image = image
		statusItem.button?.appearsDisabled = !dragGuard.isRunning

		let menu = NSMenu()

		if !dragGuard.isRunning {
			menu.addItem(NSMenuItem(title: localized("Waiting for Accessibility access…"), action: nil, keyEquivalent: ""))
			menu.addItem(item(localized("Open Settings › Accessibility"), #selector(openAccessibility)))
			menu.addItem(.separator())
		}

		let toggleItem = item(localized("You shall not move!"), #selector(toggleEnabled), checked: settings.enabled)
		if let shortcut = settings.toggleShortcut, shortcutActive, !shortcut.keyEquivalent.isEmpty {
			toggleItem.keyEquivalent = shortcut.keyEquivalent
			toggleItem.keyEquivalentModifierMask = shortcut.modifiers
		}
		menu.addItem(toggleItem)
		menu.addItem(item(localized("Block during the drag"), #selector(toggleBlockDuringDrag), checked: settings.blockDuringDrag))

		let modifierItem = NSMenuItem(title: localized("Move key"), action: nil, keyEquivalent: "")
		let modifierMenu = NSMenu()
		for modifier in Modifier.allCases {
			let entry = item(modifier.title, #selector(chooseModifier(_:)), checked: settings.modifier == modifier)
			entry.representedObject = modifier.rawValue
			modifierMenu.addItem(entry)
		}
		modifierItem.submenu = modifierMenu
		menu.addItem(modifierItem)

		let shortcutItem = NSMenuItem(title: localized("Toggle shortcut"), action: nil, keyEquivalent: "")
		let shortcutMenu = NSMenu()
		shortcutMenu.autoenablesItems = false
		let current: String
		if let shortcut = settings.toggleShortcut {
			current = shortcutActive ? shortcut.title : String(format: localized("%@ (used by another app)"), shortcut.title)
		} else {
			current = localized("None")
		}
		let currentItem = NSMenuItem(title: String(format: localized("Current: %@"), current), action: nil, keyEquivalent: "")
		currentItem.isEnabled = false
		shortcutMenu.addItem(currentItem)
		shortcutMenu.addItem(.separator())
		shortcutMenu.addItem(item(localized("Change…"), #selector(changeShortcut)))
		let resetItem = item(String(format: localized("Reset to %@"), Shortcut.standard.title), #selector(resetShortcut))
		resetItem.isEnabled = settings.toggleShortcut != .standard
		shortcutMenu.addItem(resetItem)
		shortcutMenu.addItem(item(localized("None"), #selector(clearShortcut), checked: settings.toggleShortcut == nil))
		shortcutItem.submenu = shortcutMenu
		menu.addItem(shortcutItem)

		let soundItem = NSMenuItem(title: localized("Refusal sound"), action: nil, keyEquivalent: "")
		let soundMenu = NSMenu()
		for sound in RefusalSound.allCases {
			let entry = item(sound.title, #selector(chooseSound(_:)), checked: settings.refusalSound == sound)
			entry.representedObject = sound.rawValue
			soundMenu.addItem(entry)
			if sound == .none || sound == .forceField {
				soundMenu.addItem(.separator())
			}
		}
		soundMenu.addItem(.separator())
		let volumeItem = NSMenuItem(title: localized("Volume"), action: nil, keyEquivalent: "")
		let volumeMenu = NSMenu()
		for volume: Float in [0.25, 0.5, 0.75, 1] {
			let title = String(format: localized("%d%%"), Int(volume * 100))
			let entry = item(title, #selector(chooseVolume(_:)), checked: abs(settings.soundVolume - volume) < 0.01)
			entry.representedObject = volume
			volumeMenu.addItem(entry)
		}
		volumeItem.submenu = volumeMenu
		soundMenu.addItem(volumeItem)
		soundItem.submenu = soundMenu
		menu.addItem(soundItem)

		menu.addItem(.separator())
		let loginEnabled = SMAppService.mainApp.status == .enabled
		menu.addItem(item(localized("Open at login"), #selector(toggleLaunchAtLogin), checked: loginEnabled))
		menu.addItem(.separator())
		// The version, and where to get a newer one: releases are on GitHub, made by the Release
		// workflow from a version tag. The app isn't notarized, so it doesn't update itself.
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
		menu.addItem(NSMenuItem(title: "YouShallNotMove \(version)", action: nil, keyEquivalent: ""))
		menu.addItem(item(localized("Check for Updates…"), #selector(checkForUpdates)))
		menu.addItem(item(localized("Quit YouShallNotMove"), #selector(quit), key: "q"))

		statusItem.menu = menu
	}

	private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
		entry.target = self
		entry.state = checked ? .on : .off
		return entry
	}

	@objc private func toggleEnabled() {
		toggle(fromShortcut: false)
	}

	/// From the shortcut, the menu isn't on screen: a sound tells whether the lock is now on or off.
	private func toggle(fromShortcut: Bool) {
		guard Date().timeIntervalSince(lastToggle) > 0.3 else {
			return
		}
		lastToggle = Date()
		settings.enabled.toggle()
		if fromShortcut, let sound = NSSound(named: settings.enabled ? "Tink" : "Pop") {
			sound.volume = settings.soundVolume
			sound.play()
		}
		writeLog("lock turned \(settings.enabled ? "on" : "off")\(fromShortcut ? " by the shortcut" : "")")
		rebuildMenu()
	}

	@objc private func changeShortcut() {
		hotKey.unregister()
		recorder.start(accept: { [weak self] shortcut in
			guard let self, self.hotKey.register(shortcut) else {
				return false
			}
			self.settings.toggleShortcut = shortcut
			return true
		}, finished: { [weak self] in
			self?.registerShortcut()
			self?.rebuildMenu()
		})
	}

	@objc private func resetShortcut() {
		settings.toggleShortcut = .standard
		registerShortcut()
		rebuildMenu()
	}

	@objc private func clearShortcut() {
		settings.toggleShortcut = nil
		registerShortcut()
		rebuildMenu()
	}

	@objc private func toggleBlockDuringDrag() {
		settings.blockDuringDrag.toggle()
		rebuildMenu()
	}

	@objc private func chooseModifier(_ sender: NSMenuItem) {
		if let raw = sender.representedObject as? String, let modifier = Modifier(rawValue: raw) {
			settings.modifier = modifier
		}
		rebuildMenu()
	}

	/// Selects the sound and plays it as a preview.
	/// Sets the volume and plays the current sound as a preview.
	@objc private func chooseVolume(_ sender: NSMenuItem) {
		if let volume = sender.representedObject as? Float {
			settings.soundVolume = volume
			settings.refusalSound.play(volume: volume)
		}
		rebuildMenu()
	}

	@objc private func chooseSound(_ sender: NSMenuItem) {
		if let raw = sender.representedObject as? String, let sound = RefusalSound(rawValue: raw) {
			settings.refusalSound = sound
			sound.play(volume: settings.soundVolume)
		}
		rebuildMenu()
	}

	@objc private func toggleLaunchAtLogin() {
		do {
			if SMAppService.mainApp.status == .enabled {
				try SMAppService.mainApp.unregister()
			} else {
				try SMAppService.mainApp.register()
			}
		} catch {
			writeLog("launch at login failed: \(error.localizedDescription)")
		}
		rebuildMenu()
	}

	@objc private func openAccessibility() {
		let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
		NSWorkspace.shared.open(url)
	}

	@objc private func checkForUpdates() {
		NSWorkspace.shared.open(URL(string: "https://github.com/spoulin/youshallnotmove/releases/latest")!)
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}
}

// MARK: - Probe (diagnostic)

private func axString(_ element: AXUIElement, _ attribute: String) -> String {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
		return "-"
	}
	return (value as? String) ?? "\(value)"
}

private func axParent(_ element: AXUIElement) -> AXUIElement? {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success else {
		return nil
	}
	return (value as! AXUIElement)
}

/// Writes, for each visible window, what Accessibility reports at a few points of its top area.
private func runProbe(output: String) {
	let systemWide = AXUIElementCreateSystemWide()
	var lines: [String] = ["trusted=\(AXIsProcessTrusted())"]
	let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
	let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
	for info in list {
		guard
			isAppWindow(info),
			let id = info[kCGWindowNumber as String] as? CGWindowID,
			let owner = info[kCGWindowOwnerName as String] as? String,
			let bounds = info[kCGWindowBounds as String] as? NSDictionary,
			let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
			frame.width > 200, frame.height > 150
		else {
			continue
		}
		for (label, dy) in [("y+8", 8.0), ("y+20", 20.0), ("y+35", 35.0), ("y+50", 50.0), ("y+70", 70.0), ("mid", frame.height / 2)] {
			for (xl, x) in [("x30%", frame.minX + frame.width * 0.3), ("x60%", frame.minX + frame.width * 0.6)] {
				var hit: AXUIElement?
				let err = AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(frame.minY + dy), &hit)
				guard err == .success, let hit else {
					lines.append("\(owner)#\(id) \(label) \(xl): err \(err.rawValue)")
					continue
				}
				var chain: [String] = []
				var current: AXUIElement? = hit
				var hitWindow: CGWindowID = 0
				var depth = 0
				while let element = current, depth < 40 {
					let role = axString(element, kAXRoleAttribute)
					chain.append("\(role)/\(axString(element, kAXSubroleAttribute))")
					if role == kAXWindowRole {
						_AXUIElementGetWindow(element, &hitWindow)
						break
					}
					current = axParent(element)
					depth += 1
				}
				let mark = hitWindow == id ? "" : " (covered by #\(hitWindow))"
				lines.append("\(owner)#\(id) \(label) \(xl): \(chain.joined(separator: " < "))\(mark)")
			}
		}
	}
	try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe"), index + 1 < CommandLine.arguments.count {
	runProbe(output: CommandLine.arguments[index + 1])
	exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
