//
//  MacExtensions.swift
//
//
//  Created by Miguel de Icaza on 6/29/21.
//

#if os(macOS)
import Foundation
import AppKit

extension NSColor {
    private static let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func getTerminalColor () -> Color {
        guard let color = self.usingColorSpace(.sRGB) else {
            return Color.defaultForeground
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: UInt16(red*65535), green: UInt16(green*65535), blue: UInt16(blue*65535))
    }
    func inverseColor() -> NSColor {
        guard let color = self.usingColorSpace(.sRGB) else {
            return self
        }

        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let cg = CGColor(colorSpace: Self.srgbColorSpace, components: [1.0 - red, 1.0 - green, 1.0 - blue, alpha])!
        return NSColor(cgColor: cg)!
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) for
    /// `background`. The result is fully opaque so that adjacent box-drawing
    /// characters tile without visible seams.
    ///
    /// This used to be a flat 50% blend toward `background`, which reads fine on a
    /// dark background (a light foreground blended halfway toward near-black still
    /// lands far from the background) but collapses well under a 2:1 contrast ratio
    /// on a light background (a dark foreground blended halfway toward near-white
    /// lands most of the way to invisible) - WCAG contrast is not symmetric under
    /// swapping which side is dark. Instead this targets a fixed contrast ratio
    /// against `background` (`Dimming.targetContrastRatio`), found by bisecting the
    /// blend fraction along the straight sRGB line from the foreground to the
    /// background, capped at the original 50% so dim text never becomes *less*
    /// dimmed than before. See `Dimming.blendFraction` for the shared algorithm
    /// (also used by the iOS/UIKit variant of this method).
    func dimmedColor (towards background: NSColor) -> NSColor {
        guard let fg = self.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else {
            return self
        }
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        fg.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        bg.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        let t = CGFloat(Dimming.blendFraction(fgRed: Double(fRed), fgGreen: Double(fGreen), fgBlue: Double(fBlue),
                                               bgRed: Double(bRed), bgGreen: Double(bGreen), bgBlue: Double(bBlue)))
        let cg = CGColor(colorSpace: Self.srgbColorSpace,
                         components: [fRed + (bRed - fRed) * t,
                                       fGreen + (bGreen - fGreen) * t,
                                       fBlue + (bBlue - fBlue) * t,
                                       fAlpha])!
        return NSColor(cgColor: cg)!
    }

    /// Returns `self` (a literal 24-bit truecolor foreground) remapped, if
    /// needed, to keep at least `Dimming.targetContrastRatio` against
    /// `background`. See `Dimming.contrastFixBlendFraction`'s doc comment for
    /// the full writeup (cockpit-native-fixes5) - unlike `dimmedColor(towards:)`
    /// above, this blends *away* from `background` and is a no-op whenever the
    /// color already has enough contrast.
    func legibleColor (against background: NSColor) -> NSColor {
        guard let fg = self.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else {
            return self
        }
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        fg.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        bg.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        let (fraction, towardWhite) = Dimming.contrastFixBlendFraction(
            fgRed: Double(fRed), fgGreen: Double(fGreen), fgBlue: Double(fBlue),
            bgRed: Double(bRed), bgGreen: Double(bGreen), bgBlue: Double(bBlue))
        guard fraction > 0 else { return self }
        let t = CGFloat(fraction)
        let toward: CGFloat = towardWhite ? 1 : 0
        let cg = CGColor(colorSpace: Self.srgbColorSpace,
                         components: [fRed + (toward - fRed) * t,
                                       fGreen + (toward - fGreen) * t,
                                       fBlue + (toward - fBlue) * t,
                                       fAlpha])!
        return NSColor(cgColor: cg)!
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor
    {
        let cg = CGColor(colorSpace: srgbColorSpace, components: [red, green, blue, alpha])!
        return NSColor(cgColor: cg)!
    }

    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return NSColor (
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha)
    }

    static func make (color: Color) -> NSColor
    {
        let r = CGFloat(color.red) / 65535.0
        let g = CGFloat(color.green) / 65535.0
        let b = CGFloat(color.blue) / 65535.0
        let cg = CGColor(colorSpace: srgbColorSpace, components: [r, g, b, 1.0])!
        return NSColor(cgColor: cg)!
    }

    static func transparent () -> NSColor {
        return NSColor (calibratedWhite: 0, alpha: 0)
    }
}

extension NSBezierPath {
    func addLine(to: CGPoint)
    {
        self.line (to: to)
    }
}

extension NSView {
    func rectsBeingDrawn() -> [CGRect] {
       var rectsPtr: UnsafePointer<CGRect>? = nil
       var count: Int = 0
       self.getRectsBeingDrawn(&rectsPtr, count: &count)

       return Array(UnsafeBufferPointer(start: rectsPtr, count: count))
     }

    public func pending(_ msg: String = "PENDING RECTS") {
        print (msg)
        for x in rectsBeingDrawn() {
            print ("   -> \(x)")
        }
    }
}
extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ignored: Bool) -> Bool
    {
        return attributeKeys.contains(NSAttributedString.Key.selectionBackgroundColor.rawValue)
    }
}
#endif
