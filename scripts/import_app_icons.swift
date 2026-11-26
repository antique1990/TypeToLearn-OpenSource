// Run from the repository root after replacing the supplied AppIcons artwork:
// swift -module-cache-path /tmp/learnkeyboard-brand-cache scripts/import_app_icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("AppIcons/Assets.xcassets/AppIcon.appiconset")
let assets = root.appendingPathComponent("App/Assets.xcassets")
let image = NSImage(contentsOf: source.appendingPathComponent("1024.png"))!
let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
precondition(original.width == 1024 && original.height == 1024, "App icon must be 1024 × 1024")

// App Store icons cannot carry an alpha channel. Keep the supplied artwork,
// flattening only the export onto its matching green background.
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                        bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
context.setFillColor(CGColor(srgbRed: 0.02, green: 0.39, blue: 0.35, alpha: 1))
context.fill(bounds)
context.draw(original, in: bounds)
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!
    .write(to: assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))

// The supplied 120 px image remains unmodified and covers the header at 3×.
try Data(contentsOf: source.appendingPathComponent("120.png"))
    .write(to: assets.appendingPathComponent("TypeToLearnLogo.imageset/logo.png"))
print("Imported supplied app icon and header logo.")
