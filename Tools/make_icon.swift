// Vykreslí ikonu aplikace 1024×1024 do PNG: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let full = CommandLine.arguments.contains("--full") // iOS: plný čtverec, zaoblení dělá systém
let inset: CGFloat = full ? 0 : 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: full ? 0 : 185, yRadius: full ? 0 : 185)
NSGradient(colors: [NSColor(srgbRed: 0.53, green: 0.65, blue: 0.27, alpha: 1),
                    NSColor(srgbRed: 0.33, green: 0.44, blue: 0.15, alpha: 1)])!
    .draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: full ? 470 : 420, weight: .medium)
    .applying(.init(paletteColors: [NSColor(srgbRed: 0.97, green: 0.96, blue: 0.92, alpha: 1)]))
if let sym = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
