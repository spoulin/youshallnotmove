import AppKit
import ApplicationServices
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
		case .command: return "⌘ Commande"
		case .option: return "⌥ Option"
		case .control: return "⌃ Contrôle"
		case .shift: return "⇧ Majuscule"
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
}

// MARK: - Window tracking

struct TrackedWindow {
	let id: CGWindowID
	let pid: pid_t
	let frame: CGRect
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
			(info[kCGWindowLayer as String] as? Int) == 0,
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
				// Check twice: right away, then after a possible tiling animation.
				for delay in [0.05, 0.6] {
					DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
						self?.restoreAfterRelease(snapshot, dragDistance: distance)
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

	private func resetGesture() {
		heldDown = nil
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

	private func restoreAfterRelease(_ windows: [TrackedWindow], dragDistance: CGFloat) {
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

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
	private let settings = Settings()
	private lazy var dragGuard = DragGuard(settings: settings)
	private var statusItem: NSStatusItem!
	private var permissionTimer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		rebuildMenu()
		startWhenTrusted(prompt: true)
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
			menu.addItem(NSMenuItem(title: "En attente de l’accès Accessibilité…", action: nil, keyEquivalent: ""))
			menu.addItem(item("Ouvrir Réglages › Accessibilité", #selector(openAccessibility)))
			menu.addItem(.separator())
		}

		menu.addItem(item("You shall not move!", #selector(toggleEnabled), checked: settings.enabled))
		menu.addItem(item("Bloquer pendant le glisser", #selector(toggleBlockDuringDrag), checked: settings.blockDuringDrag))

		let modifierItem = NSMenuItem(title: "Touche pour déplacer", action: nil, keyEquivalent: "")
		let modifierMenu = NSMenu()
		for modifier in Modifier.allCases {
			let entry = item(modifier.title, #selector(chooseModifier(_:)), checked: settings.modifier == modifier)
			entry.representedObject = modifier.rawValue
			modifierMenu.addItem(entry)
		}
		modifierItem.submenu = modifierMenu
		menu.addItem(modifierItem)

		menu.addItem(.separator())
		let loginEnabled = SMAppService.mainApp.status == .enabled
		menu.addItem(item("Ouvrir au démarrage", #selector(toggleLaunchAtLogin), checked: loginEnabled))
		menu.addItem(item("Quitter YouShallNotMove", #selector(quit), key: "q"))

		statusItem.menu = menu
	}

	private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
		let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
		entry.target = self
		entry.state = checked ? .on : .off
		return entry
	}

	@objc private func toggleEnabled() {
		settings.enabled.toggle()
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
			(info[kCGWindowLayer as String] as? Int) == 0,
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
