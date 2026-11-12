// Draws the app icon (a wizard staff guarding a window) as a 1024 px PNG.
// Usage: swift Icon/make-icon.swift <output.png>
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

// MARK: Background: macOS icon grid squircle

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

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

// Stars
let stars: [(CGFloat, CGFloat, CGFloat)] = [
	(210, 230, 5), (300, 170, 3), (820, 300, 4), (760, 190, 3), (190, 420, 3),
	(860, 470, 5), (400, 250, 2.5), (640, 160, 3.5), (880, 680, 3), (170, 640, 4),
]
for (x, y, r) in stars {
	ctx.setFillColor(color(0xFFFFFF, 0.75))
	ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// MARK: The window being guarded

let window = CGRect(x: 250, y: 470, width: 470, height: 330)
let windowPath = CGPath(roundedRect: window, cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(windowPath)
ctx.setFillColor(color(0xE9E6F5))
ctx.fillPath()
ctx.restoreGState()

// Title bar
ctx.saveGState()
ctx.addPath(windowPath)
ctx.clip()
ctx.setFillColor(color(0xCFC9E6))
ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 64))
ctx.restoreGState()
for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
	let cx = window.minX + 44 + CGFloat(i) * 40
	ctx.setFillColor(color(hex))
	ctx.fillEllipse(in: CGRect(x: cx - 13, y: window.minY + 32 - 13, width: 26, height: 26))
}
// Content lines
ctx.setFillColor(color(0xB9B2D6))
for (i, width) in [CGFloat(300), 360, 250, 320].enumerated() {
	let line = CGRect(x: window.minX + 44, y: window.minY + 110 + CGFloat(i) * 46, width: width, height: 20)
	ctx.addPath(CGPath(roundedRect: line, cornerWidth: 10, cornerHeight: 10, transform: nil))
	ctx.fillPath()
}

// MARK: Glow of the crystal on the scene

let orb = CGPoint(x: 712, y: 300)
ctx.drawRadialGradient(
	gradient([color(0x9FE8FF, 0.55), color(0x6C8CFF, 0.18), color(0x6C8CFF, 0)], [0, 0.45, 1]),
	startCenter: orb, startRadius: 0, endCenter: orb, endRadius: 330, options: []
)

// MARK: The staff, planted in front of the window

let foot = CGPoint(x: 560, y: 880)

// Shockwave where the staff hits the ground
ctx.setLineWidth(5)
for (i, rx) in [CGFloat(60), 110, 165].enumerated() {
	let alpha = 0.55 - CGFloat(i) * 0.15
	ctx.setStrokeColor(color(0x9FE8FF, alpha))
	ctx.strokeEllipse(in: CGRect(x: foot.x - rx, y: foot.y - rx * 0.18, width: rx * 2, height: rx * 0.36))
}
let head = CGPoint(x: 712, y: 352)
let shaft = CGMutablePath()
// Tapered shaft: wider at the head, thinner at the foot.
let dx = head.x - foot.x
let dy = head.y - foot.y
let length = hypot(dx, dy)
let nx = -dy / length
let ny = dx / length
let headHalf: CGFloat = 24
let footHalf: CGFloat = 15
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
// Knots
for t in [CGFloat(0.3), 0.62] {
	let p = CGPoint(x: foot.x + dx * t, y: foot.y + dy * t)
	ctx.setFillColor(color(0x3E2410, 0.85))
	ctx.fillEllipse(in: CGRect(x: p.x - 11, y: p.y - 7, width: 22, height: 14))
}
ctx.restoreGState()

// Crystal orb
let orbRadius: CGFloat = 58
let orbRect = CGRect(x: orb.x - orbRadius, y: orb.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2)
ctx.saveGState()
ctx.addEllipse(in: orbRect)
ctx.clip()
ctx.drawRadialGradient(
	gradient([color(0xFFFFFF), color(0xA6F0FF), color(0x4D7BFF)], [0, 0.35, 1]),
	startCenter: CGPoint(x: orb.x - 18, y: orb.y - 20), startRadius: 0,
	endCenter: orb, endRadius: orbRadius, options: [.drawsAfterEndLocation]
)
ctx.restoreGState()

// Claws holding the crystal, drawn over it
ctx.setLineCap(.round)
for side: CGFloat in [-1, 1] {
	let claw = CGMutablePath()
	claw.move(to: CGPoint(x: head.x + side * 16, y: head.y + 4))
	claw.addCurve(
		to: CGPoint(x: orb.x + side * 26, y: orb.y - 50),
		control1: CGPoint(x: orb.x + side * 74, y: orb.y + 40),
		control2: CGPoint(x: orb.x + side * 70, y: orb.y - 30)
	)
	ctx.addPath(claw)
	ctx.setStrokeColor(color(0x3E2410))
	ctx.setLineWidth(17)
	ctx.strokePath()
	ctx.addPath(claw)
	ctx.setStrokeColor(color(0x8A5A30))
	ctx.setLineWidth(8)
	ctx.strokePath()
}

// Sparkles around the orb
func sparkle(_ c: CGPoint, _ r: CGFloat) {
	let path = CGMutablePath()
	path.move(to: CGPoint(x: c.x, y: c.y - r))
	path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
	path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
	ctx.addPath(path)
	ctx.setFillColor(color(0xFFFFFF, 0.95))
	ctx.fillPath()
}
sparkle(CGPoint(x: 800, y: 215), 30)
sparkle(CGPoint(x: 620, y: 200), 18)
sparkle(CGPoint(x: 815, y: 360), 14)

ctx.restoreGState()

// MARK: Write the PNG

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(
	URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(output)")
