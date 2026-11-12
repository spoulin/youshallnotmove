// Draws the app icon as a 1024 px PNG.
// Usage: swift Icon/make-icon.swift <output.png> [pinned|staff|seal]
//   pinned: a gnarled staff nails the window by its title bar (the app icon)
//   staff:  a wizard staff planted in front of a window
//   seal:   a glowing protection rune sealed on the window
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
	data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
	space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Draw with a top-left origin.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
	CGColor(
		srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
		green: CGFloat((hex >> 8) & 0xFF) / 255,
		blue: CGFloat(hex & 0xFF) / 255,
		alpha: alpha
	)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
	CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
	CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func glow(at center: CGPoint, radius: CGFloat, strength: CGFloat = 0.55) {
	ctx.drawRadialGradient(
		gradient([color(0x9FE8FF, strength), color(0x6C8CFF, strength / 3), color(0x6C8CFF, 0)], [0, 0.45, 1]),
		startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
	)
}

func sparkle(_ c: CGPoint, _ r: CGFloat, alpha: CGFloat = 0.95) {
	let path = CGMutablePath()
	path.move(to: CGPoint(x: c.x, y: c.y - r))
	path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
	ctx.addPath(path)
	ctx.setFillColor(color(0xFFFFFF, alpha))
	ctx.fillPath()
}

// MARK: - Shared pieces

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = roundedRect(tile, 185)

/// macOS icon grid squircle with a night sky. Leaves the tile clipped: call `ctx.restoreGState()` at the end.
func drawBackground(stars: [(CGFloat, CGFloat, CGFloat)]) {
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
	ctx.addPath(tilePath)
	ctx.setFillColor(color(0x1A1033))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(tilePath)
	ctx.clip()
	ctx.drawLinearGradient(
		gradient([color(0x3B2A7A), color(0x1B1240), color(0x0E0A22)], [0, 0.55, 1]),
		start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
	)
	for (x, y, r) in stars {
		ctx.setFillColor(color(0xFFFFFF, 0.75))
		ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
	}
}

/// A light macOS window with traffic lights and content lines.
func drawWindow(_ window: CGRect, titleHeight: CGFloat, radius: CGFloat, lines: [CGFloat]) {
	let path = roundedRect(window, radius)
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: color(0x000000, 0.45))
	ctx.addPath(path)
	ctx.setFillColor(color(0xE9E6F5))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(path)
	ctx.clip()
	ctx.setFillColor(color(0xCFC9E6))
	ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: titleHeight))
	ctx.restoreGState()

	let dot = titleHeight * 0.4
	for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
		let cx = window.minX + titleHeight * 0.7 + CGFloat(i) * dot * 1.55
		ctx.setFillColor(color(hex))
		ctx.fillEllipse(in: CGRect(x: cx - dot / 2, y: window.minY + titleHeight / 2 - dot / 2, width: dot, height: dot))
	}

	ctx.setFillColor(color(0xB9B2D6))
	for (i, width) in lines.enumerated() {
		let line = CGRect(x: window.minX + 44, y: window.minY + titleHeight + 46 + CGFloat(i) * 46, width: width, height: 20)
		ctx.addPath(roundedRect(line, 10))
		ctx.fillPath()
	}
}

/// A tapered wooden shaft from `foot` to `head`.
func drawShaft(foot: CGPoint, head: CGPoint, footHalf: CGFloat, headHalf: CGFloat) {
	let dx = head.x - foot.x
	let dy = head.y - foot.y
	let length = hypot(dx, dy)
	let nx = -dy / length
	let ny = dx / length
	let shaft = CGMutablePath()
	shaft.move(to: CGPoint(x: foot.x + nx * footHalf, y: foot.y + ny * footHalf))
	shaft.addLine(to: CGPoint(x: head.x + nx * headHalf, y: head.y + ny * headHalf))
	shaft.addLine(to: CGPoint(x: head.x - nx * headHalf, y: head.y - ny * headHalf))
	shaft.addLine(to: CGPoint(x: foot.x - nx * footHalf, y: foot.y - ny * footHalf))
	shaft.closeSubpath()

	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 10, height: 14), blur: 18, color: color(0x000000, 0.5))
	ctx.addPath(shaft)
	ctx.setFillColor(color(0x6B4226))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(shaft)
	ctx.clip()
	ctx.drawLinearGradient(
		gradient([color(0xA8743F), color(0x7A4A26), color(0x4A2B14)], [0, 0.5, 1]),
		start: CGPoint(x: foot.x + nx * 30, y: foot.y + ny * 30),
		end: CGPoint(x: foot.x - nx * 30, y: foot.y - ny * 30),
		options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
	)
	for t in [CGFloat(0.3), 0.62] {
		let p = CGPoint(x: foot.x + dx * t, y: foot.y + dy * t)
		ctx.setFillColor(color(0x3E2410, 0.85))
		ctx.fillEllipse(in: CGRect(x: p.x - 11, y: p.y - 7, width: 22, height: 14))
	}
	ctx.restoreGState()
}

/// The glowing crystal held by two claws on top of the shaft.
func drawOrb(_ orb: CGPoint, radius: CGFloat, head: CGPoint) {
	let rect = CGRect(x: orb.x - radius, y: orb.y - radius, width: radius * 2, height: radius * 2)
	ctx.saveGState()
	ctx.addEllipse(in: rect)
	ctx.clip()
	ctx.drawRadialGradient(
		gradient([color(0xFFFFFF), color(0xA6F0FF), color(0x4D7BFF)], [0, 0.35, 1]),
		startCenter: CGPoint(x: orb.x - radius * 0.3, y: orb.y - radius * 0.35), startRadius: 0,
		endCenter: orb, endRadius: radius, options: [.drawsAfterEndLocation]
	)
	ctx.restoreGState()

	ctx.setLineCap(.round)
	let k = radius / 58
	for side: CGFloat in [-1, 1] {
		let claw = CGMutablePath()
		claw.move(to: CGPoint(x: head.x + side * 16 * k, y: head.y + 4 * k))
		claw.addCurve(
			to: CGPoint(x: orb.x + side * 26 * k, y: orb.y - 50 * k),
			control1: CGPoint(x: orb.x + side * 74 * k, y: orb.y + 40 * k),
			control2: CGPoint(x: orb.x + side * 70 * k, y: orb.y - 30 * k)
		)
		ctx.addPath(claw)
		ctx.setStrokeColor(color(0x3E2410))
		ctx.setLineWidth(17 * k)
		ctx.strokePath()
		ctx.addPath(claw)
		ctx.setStrokeColor(color(0x8A5A30))
		ctx.setLineWidth(8 * k)
		ctx.strokePath()
	}
}

/// A faceted quartz point set in a brass collar, on top of the shaft, along its axis.
func drawCrystal(head: CGPoint, foot: CGPoint) {
	let angle = atan2(head.y - foot.y, head.x - foot.x) + .pi / 2
	ctx.saveGState()
	ctx.translateBy(x: head.x, y: head.y)
	ctx.rotate(by: angle)

	func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
		let path = CGMutablePath()
		path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
		path.closeSubpath()
		return path
	}
	func fill(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
		ctx.saveGState()
		ctx.addPath(path)
		ctx.clip()
		ctx.drawLinearGradient(gradient(colors, [0, 1]), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
		ctx.restoreGState()
	}

	// Crystal: three visible facets of a hexagonal prism ending in a point.
	let half: CGFloat = 30
	let inner: CGFloat = 9
	let body: CGFloat = -128
	let tip: CGFloat = -182
	let left = polygon([(-half, -6), (-inner, -6), (-inner, body), (0, tip), (-half, body)])
	let middle = polygon([(-inner, -6), (inner, -6), (inner, body), (0, tip), (-inner, body)])
	let right = polygon([(inner, -6), (half, -6), (half, body), (0, tip), (inner, body)])
	let outline = polygon([(-half, -6), (half, -6), (half, body), (0, tip), (-half, body)])

	ctx.saveGState()
	ctx.setShadow(offset: .zero, blur: 40, color: color(0x7FD8FF, 0.9))
	ctx.addPath(outline)
	ctx.setFillColor(color(0x5A8CFF))
	ctx.fillPath()
	ctx.restoreGState()

	fill(left, [color(0x2F4FD8), color(0x5B86FF)], from: CGPoint(x: 0, y: -6), to: CGPoint(x: 0, y: tip))
	fill(middle, [color(0x8FD8FF), color(0xF2FDFF)], from: CGPoint(x: 0, y: -6), to: CGPoint(x: 0, y: tip))
	fill(right, [color(0x4F7DF0), color(0xA9D4FF)], from: CGPoint(x: 0, y: -6), to: CGPoint(x: 0, y: tip))

	// Facet edges and a highlight streak.
	ctx.setStrokeColor(color(0xFFFFFF, 0.55))
	ctx.setLineWidth(2)
	ctx.setLineJoin(.round)
	ctx.addPath(outline)
	ctx.strokePath()
	for x in [-inner, inner] {
		ctx.move(to: CGPoint(x: x, y: -6))
		ctx.addLine(to: CGPoint(x: x, y: body))
		ctx.addLine(to: CGPoint(x: 0, y: tip))
	}
	ctx.strokePath()
	ctx.setStrokeColor(color(0xFFFFFF, 0.9))
	ctx.setLineWidth(4)
	ctx.setLineCap(.round)
	ctx.move(to: CGPoint(x: -2, y: -30))
	ctx.addLine(to: CGPoint(x: -2, y: -100))
	ctx.strokePath()

	// Brass collar holding the crystal, with two prongs.
	let brass = [color(0xF3E2AE), color(0xB8913F), color(0x6E5222)]
	for side: CGFloat in [-1, 1] {
		let prong = CGMutablePath()
		prong.move(to: CGPoint(x: side * (half - 2), y: 8))
		prong.addQuadCurve(to: CGPoint(x: side * (half - 10), y: -62), control: CGPoint(x: side * (half + 12), y: -26))
		ctx.addPath(prong)
		ctx.setStrokeColor(color(0x6E5222))
		ctx.setLineWidth(11)
		ctx.strokePath()
		ctx.addPath(prong)
		ctx.setStrokeColor(color(0xE2C982))
		ctx.setLineWidth(5)
		ctx.strokePath()
	}
	let collar = roundedRect(CGRect(x: -half - 6, y: -10, width: (half + 6) * 2, height: 34), 9)
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 6, color: color(0x000000, 0.45))
	ctx.addPath(collar)
	ctx.setFillColor(brass[1])
	ctx.fillPath()
	ctx.restoreGState()
	fill(collar, [brass[0], brass[2]], from: CGPoint(x: -half, y: 0), to: CGPoint(x: half, y: 0))
	ctx.setStrokeColor(color(0x5A421A, 0.8))
	ctx.setLineWidth(2.5)
	ctx.move(to: CGPoint(x: -half - 6, y: 7))
	ctx.addLine(to: CGPoint(x: half + 6, y: 7))
	ctx.strokePath()

	ctx.restoreGState()
}

// MARK: - Gnarled staff

func cubicPoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
	let u = 1 - t
	let a = u * u * u
	let b = 3 * u * u * t
	let c = 3 * u * t * t
	let d = t * t * t
	return CGPoint(
		x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
		y: a * p0.y + b * c1.y + c * c2.y + d * p3.y
	)
}

/// A tapered organic strand along a cubic curve, `startWidth` at p0 down to `endWidth` at p3.
func strandPath(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, startWidth: CGFloat, endWidth: CGFloat) -> CGPath {
	let steps = 40
	var left: [CGPoint] = []
	var right: [CGPoint] = []
	for i in 0...steps {
		let t = CGFloat(i) / CGFloat(steps)
		let p = cubicPoint(p0, c1, c2, p3, t)
		let q = cubicPoint(p0, c1, c2, p3, min(1, t + 0.01))
		let r = cubicPoint(p0, c1, c2, p3, max(0, t - 0.01))
		let dx = q.x - r.x
		let dy = q.y - r.y
		let length = max(hypot(dx, dy), 0.0001)
		let half = (startWidth + (endWidth - startWidth) * t) / 2
		left.append(CGPoint(x: p.x - dy / length * half, y: p.y + dx / length * half))
		right.append(CGPoint(x: p.x + dy / length * half, y: p.y - dx / length * half))
	}
	let path = CGMutablePath()
	path.addLines(between: left + right.reversed())
	path.closeSubpath()
	return path
}

/// Fills a strand with weathered wood: gradient across, dark outline, light grain along it.
func drawWood(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, startWidth: CGFloat, endWidth: CGFloat, shade: CGFloat = 1) {
	let path = strandPath(p0, c1, c2, p3, startWidth: startWidth, endWidth: endWidth)
	let box = path.boundingBox
	ctx.saveGState()
	ctx.addPath(path)
	ctx.clip()
	let light = shade >= 1 ? color(0xA88C66) : color(0x7A6A55)
	let dark = shade >= 1 ? color(0x2E2219) : color(0x2C241D)
	ctx.drawLinearGradient(
		gradient([light, color(0x6A5238), dark], [0, 0.45, 1]),
		start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY),
		options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
	)
	// Grain
	ctx.setLineCap(.round)
	for (offset, alpha) in [(CGFloat(-0.22), 0.35), (0.12, 0.25), (0.3, 0.2)] {
		let grain = strandPath(
			CGPoint(x: p0.x + offset * startWidth, y: p0.y), CGPoint(x: c1.x + offset * startWidth, y: c1.y),
			CGPoint(x: c2.x + offset * endWidth, y: c2.y), CGPoint(x: p3.x + offset * endWidth, y: p3.y),
			startWidth: 3, endWidth: 1
		)
		ctx.addPath(grain)
		ctx.setFillColor(color(0xD9C9A8, alpha))
		ctx.fillPath()
	}
	ctx.restoreGState()
	ctx.addPath(path)
	ctx.setStrokeColor(color(0x241C15, 0.85))
	ctx.setLineWidth(2.5)
	ctx.setLineJoin(.round)
	ctx.strokePath()
}

/// A twisted wooden staff whose head opens like a flame.
func drawGnarledStaff(foot: CGPoint, head: CGPoint) {
	// Shaft with a slight S-curve, drawn in global coordinates.
	let dx = head.x - foot.x
	let dy = head.y - foot.y
	let length = hypot(dx, dy)
	let nx = -dy / length
	let ny = dx / length
	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 10, height: 14), blur: 18, color: color(0x000000, 0.5))
	drawWood(
		foot,
		CGPoint(x: foot.x + dx * 0.33 + nx * 12, y: foot.y + dy * 0.33 + ny * 12),
		CGPoint(x: foot.x + dx * 0.66 - nx * 10, y: foot.y + dy * 0.66 - ny * 10),
		head,
		startWidth: 36, endWidth: 44
	)
	ctx.restoreGState()

	// Head, in local coordinates: origin at the top of the shaft, staff pointing to negative y.
	ctx.saveGState()
	ctx.translateBy(x: head.x, y: head.y)
	ctx.rotate(by: atan2(dy, dx) + .pi / 2)

	func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

	// Flame-shaped knot of twisted wood, as wide as the shaft at its base.
	let headPath = CGMutablePath()
	headPath.move(to: p(-22, 14))
	headPath.addCurve(to: p(-46, -95), control1: p(-24, -30), control2: p(-54, -58))
	headPath.addCurve(to: p(-44, -172), control1: p(-40, -128), control2: p(-58, -150))
	headPath.addCurve(to: p(-12, -140), control1: p(-30, -164), control2: p(-20, -152))
	headPath.addCurve(to: p(8, -222), control1: p(-16, -178), control2: p(-8, -208))
	headPath.addCurve(to: p(18, -150), control1: p(22, -204), control2: p(22, -176))
	headPath.addCurve(to: p(54, -168), control1: p(30, -154), control2: p(44, -154))
	headPath.addCurve(to: p(42, -90), control1: p(60, -140), control2: p(54, -112))
	headPath.addCurve(to: p(22, 14), control1: p(32, -60), control2: p(24, -22))

	ctx.saveGState()
	ctx.setShadow(offset: CGSize(width: 8, height: 10), blur: 16, color: color(0x000000, 0.5))
	ctx.addPath(headPath)
	ctx.setFillColor(color(0x5E4E3C))
	ctx.fillPath()
	ctx.restoreGState()

	ctx.saveGState()
	ctx.addPath(headPath)
	ctx.clip()
	ctx.drawLinearGradient(
		gradient([color(0xA88C66), color(0x6A5238), color(0x2E2219)], [0, 0.45, 1]),
		start: p(-50, -120), end: p(50, -60), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
	)

	// Carved grooves twisting up the knot: a dark cut with a light ridge beside it.
	let grooves: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
		(p(-16, 10), p(-30, -40), p(-46, -80), p(-40, -165)),
		(p(-4, 10), p(-10, -60), p(-28, -100), p(-14, -142)),
		(p(6, 10), p(24, -50), p(-14, -120), p(6, -215)),
		(p(16, 10), p(30, -40), p(46, -90), p(50, -162)),
		(p(-40, -60), p(-14, -70), p(14, -110), p(40, -130)),
	]
	ctx.setLineCap(.round)
	for (a, b, c, d) in grooves {
		ctx.move(to: a)
		ctx.addCurve(to: d, control1: b, control2: c)
		ctx.setStrokeColor(color(0x241C15, 0.7))
		ctx.setLineWidth(5)
		ctx.strokePath()
		ctx.move(to: CGPoint(x: a.x - 4, y: a.y))
		ctx.addCurve(to: CGPoint(x: d.x - 4, y: d.y), control1: CGPoint(x: b.x - 4, y: b.y), control2: CGPoint(x: c.x - 4, y: c.y))
		ctx.setStrokeColor(color(0xE2D3B2, 0.45))
		ctx.setLineWidth(2)
		ctx.strokePath()
	}

	ctx.restoreGState()

	ctx.addPath(headPath)
	ctx.setStrokeColor(color(0x1E1711, 0.9))
	ctx.setLineWidth(3)
	ctx.setLineJoin(.round)
	ctx.strokePath()
	ctx.restoreGState()
}

// MARK: - Styles

func drawStaffStyle() {
	drawBackground(stars: [
		(210, 230, 5), (300, 170, 3), (820, 300, 4), (760, 190, 3), (190, 420, 3),
		(860, 470, 5), (400, 250, 2.5), (640, 160, 3.5), (880, 680, 3), (170, 640, 4),
	])
	drawWindow(CGRect(x: 250, y: 470, width: 470, height: 330), titleHeight: 64, radius: 34, lines: [300, 360, 250, 320])

	let orb = CGPoint(x: 712, y: 300)
	glow(at: orb, radius: 330)

	let foot = CGPoint(x: 560, y: 880)
	ctx.setLineWidth(5)
	for (i, rx) in [CGFloat(60), 110, 165].enumerated() {
		ctx.setStrokeColor(color(0x9FE8FF, 0.55 - CGFloat(i) * 0.15))
		ctx.strokeEllipse(in: CGRect(x: foot.x - rx, y: foot.y - rx * 0.18, width: rx * 2, height: rx * 0.36))
	}
	let head = CGPoint(x: 712, y: 352)
	drawShaft(foot: foot, head: head, footHalf: 15, headHalf: 24)
	drawOrb(orb, radius: 58, head: head)

	sparkle(CGPoint(x: 800, y: 215), 30)
	sparkle(CGPoint(x: 620, y: 200), 18)
	sparkle(CGPoint(x: 815, y: 360), 14)
	ctx.restoreGState()
}

func drawPinnedStyle() {
	drawBackground(stars: [
		(200, 220, 4), (300, 160, 3), (830, 260, 4), (180, 470, 3), (860, 520, 5),
		(410, 210, 2.5), (880, 760, 3), (160, 700, 4), (720, 880, 3), (300, 880, 3.5),
	])

	// Where the staff goes through the title bar.
	let nail = CGPoint(x: 530, y: 478)

	// The window hangs askew around the nail.
	let window = CGRect(x: 215, y: 443, width: 574, height: 400)
	ctx.saveGState()
	ctx.translateBy(x: nail.x, y: nail.y)
	ctx.rotate(by: -7 * .pi / 180)
	ctx.translateBy(x: -nail.x, y: -nail.y)
	drawWindow(window, titleHeight: 72, radius: 38, lines: [380, 450, 300, 410])

	// Cracks around the hole.
	ctx.setStrokeColor(color(0x4A3F6B, 0.9))
	ctx.setLineCap(.round)
	ctx.setLineJoin(.round)
	ctx.setLineWidth(4.5)
	let cracks: [[CGPoint]] = [
		[CGPoint(x: 0, y: 0), CGPoint(x: -48, y: 10), CGPoint(x: -78, y: 30), CGPoint(x: -120, y: 26)],
		[CGPoint(x: 0, y: 0), CGPoint(x: 52, y: 14), CGPoint(x: 70, y: 46), CGPoint(x: 112, y: 58)],
		[CGPoint(x: 0, y: 0), CGPoint(x: -14, y: 52), CGPoint(x: 6, y: 92), CGPoint(x: -10, y: 140)],
		[CGPoint(x: 0, y: 0), CGPoint(x: 30, y: -28)],
		[CGPoint(x: 0, y: 0), CGPoint(x: -34, y: -24)],
	]
	for crack in cracks {
		let path = CGMutablePath()
		path.addLines(between: crack.map { CGPoint(x: nail.x + $0.x, y: nail.y + $0.y) })
		ctx.addPath(path)
		ctx.strokePath()
	}
	ctx.restoreGState()

	// The staff, driven in from above.
	let head = CGPoint(x: 572, y: 330)
	// Dark hole where the shaft enters.
	ctx.setFillColor(color(0x1B1240, 0.85))
	ctx.fillEllipse(in: CGRect(x: nail.x - 28, y: nail.y - 12, width: 56, height: 24))
	drawGnarledStaff(foot: nail, head: head)

	// Impact sparks.
	sparkle(CGPoint(x: nail.x - 64, y: nail.y - 26), 20)
	sparkle(CGPoint(x: nail.x + 72, y: nail.y - 30), 26)
	sparkle(CGPoint(x: nail.x - 30, y: nail.y - 74), 12, alpha: 0.8)
	sparkle(CGPoint(x: 700, y: 170), 24)
	sparkle(CGPoint(x: 470, y: 190), 14, alpha: 0.85)
	ctx.restoreGState()
}

func drawSealStyle() {
	drawBackground(stars: [
		(200, 210, 3.5), (320, 165, 2.5), (830, 230, 3.5), (880, 520, 3), (160, 560, 3),
		(720, 870, 2.5), (290, 860, 3),
	])
	let window = CGRect(x: 196, y: 250, width: 632, height: 520)
	drawWindow(window, titleHeight: 78, radius: 44, lines: [])

	let center = CGPoint(x: 512, y: 540)
	// Soft glow on the window.
	ctx.saveGState()
	ctx.addPath(roundedRect(window, 44))
	ctx.clip()
	ctx.drawRadialGradient(
		gradient([color(0x6C8CFF, 0.35), color(0x6C8CFF, 0)], [0, 1]),
		startCenter: center, startRadius: 0, endCenter: center, endRadius: 260, options: []
	)
	ctx.restoreGState()

	let ink = color(0x4D5BFF)
	let inkLight = color(0x8FB4FF)
	func circle(_ r: CGFloat, width: CGFloat, stroke: CGColor) {
		ctx.setStrokeColor(stroke)
		ctx.setLineWidth(width)
		ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
	}

	ctx.saveGState()
	ctx.setShadow(offset: .zero, blur: 24, color: color(0x6C8CFF, 0.9))
	circle(190, width: 10, stroke: ink)
	circle(160, width: 4, stroke: inkLight)
	circle(108, width: 6, stroke: ink)

	// Rune marks between the two outer rings.
	ctx.setStrokeColor(ink)
	ctx.setLineWidth(6)
	ctx.setLineCap(.round)
	ctx.setLineJoin(.round)
	let marks = 16
	for i in 0..<marks {
		let a = CGFloat(i) / CGFloat(marks) * 2 * .pi - .pi / 2
		ctx.saveGState()
		ctx.translateBy(x: center.x + cos(a) * 134, y: center.y + sin(a) * 134)
		ctx.rotate(by: a + .pi / 2)
		let rune = CGMutablePath()
		switch i % 4 {
		case 0:
			rune.move(to: CGPoint(x: 0, y: -12)); rune.addLine(to: CGPoint(x: 0, y: 12))
			rune.move(to: CGPoint(x: 0, y: -4)); rune.addLine(to: CGPoint(x: 9, y: -12))
		case 1:
			rune.move(to: CGPoint(x: -7, y: 12)); rune.addLine(to: CGPoint(x: 0, y: -12)); rune.addLine(to: CGPoint(x: 7, y: 12))
		case 2:
			rune.move(to: CGPoint(x: 0, y: -12)); rune.addLine(to: CGPoint(x: 0, y: 12))
			rune.move(to: CGPoint(x: -8, y: -6)); rune.addLine(to: CGPoint(x: 8, y: 6))
		default:
			rune.move(to: CGPoint(x: -8, y: -10)); rune.addLine(to: CGPoint(x: 8, y: 0)); rune.addLine(to: CGPoint(x: -8, y: 10))
		}
		ctx.addPath(rune)
		ctx.strokePath()
		ctx.restoreGState()
	}

	// Algiz, the protection rune, in the middle.
	ctx.setLineWidth(16)
	let algiz = CGMutablePath()
	algiz.move(to: CGPoint(x: center.x, y: center.y + 70))
	algiz.addLine(to: CGPoint(x: center.x, y: center.y - 70))
	algiz.move(to: CGPoint(x: center.x, y: center.y - 4))
	algiz.addLine(to: CGPoint(x: center.x - 52, y: center.y - 62))
	algiz.move(to: CGPoint(x: center.x, y: center.y - 4))
	algiz.addLine(to: CGPoint(x: center.x + 52, y: center.y - 62))
	ctx.addPath(algiz)
	ctx.strokePath()
	ctx.restoreGState()

	sparkle(CGPoint(x: 720, y: 360), 22, alpha: 0.9)
	sparkle(CGPoint(x: 312, y: 700), 14, alpha: 0.8)
	ctx.restoreGState()
}

// MARK: - Main

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "pinned"
switch style {
case "staff":
	drawStaffStyle()
case "seal":
	drawSealStyle()
default:
	drawPinnedStyle()
}

let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(
	URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(output)")
