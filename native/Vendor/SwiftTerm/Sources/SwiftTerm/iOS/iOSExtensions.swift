//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 6/29/21.
//
#if os(iOS) || os(visionOS)
import Foundation
import UIKit

extension UIColor {
    func getTerminalColor () -> Color {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        func clamp (_ v: CGFloat) -> CGFloat {
            return min (max (v, 0.0), 1.0)
        }
        return Color(red: UInt16 (clamp (red)*65535), green: UInt16(clamp (green)*65535), blue: UInt16(clamp (blue)*65535))
    }

    func inverseColor() -> UIColor {
        var red: CGFloat = 0.0, green: CGFloat = 0.0, blue: CGFloat = 0.0, alpha: CGFloat = 1.0
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor (red: 1.0 - red, green: 1.0 - green, blue: 1.0 - blue, alpha: alpha)
    }

    /// Returns a dimmed version of the color (SGR 2 faint/dim attribute) for
    /// `background`. The result is fully opaque so that adjacent box-drawing
    /// characters tile without visible seams.
    ///
    /// See the AppKit twin of this method (`NSColor.dimmedColor(towards:)` in
    /// `Mac/MacExtensions.swift`) for why a flat 50% blend is wrong on light
    /// backgrounds and what `Dimming.blendFraction` does instead.
    func dimmedColor (towards background: UIColor) -> UIColor {
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        self.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        background.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        let t = CGFloat(Dimming.blendFraction(fgRed: Double(fRed), fgGreen: Double(fGreen), fgBlue: Double(fBlue),
                                               bgRed: Double(bRed), bgGreen: Double(bGreen), bgBlue: Double(bBlue)))
        return UIColor (red: fRed + (bRed - fRed) * t,
                        green: fGreen + (bGreen - fGreen) * t,
                        blue: fBlue + (bBlue - fBlue) * t,
                        alpha: fAlpha)
    }

    /// See the AppKit twin (`NSColor.legibleColor(against:)` in
    /// `Mac/MacExtensions.swift`) for the full writeup (cockpit-native-fixes5).
    func legibleColor (against background: UIColor) -> UIColor {
        var fRed: CGFloat = 0.0, fGreen: CGFloat = 0.0, fBlue: CGFloat = 0.0, fAlpha: CGFloat = 1.0
        self.getRed(&fRed, green: &fGreen, blue: &fBlue, alpha: &fAlpha)
        var bRed: CGFloat = 0.0, bGreen: CGFloat = 0.0, bBlue: CGFloat = 0.0, bAlpha: CGFloat = 1.0
        background.getRed(&bRed, green: &bGreen, blue: &bBlue, alpha: &bAlpha)
        let (fraction, towardWhite) = Dimming.contrastFixBlendFraction(
            fgRed: Double(fRed), fgGreen: Double(fGreen), fgBlue: Double(fBlue),
            bgRed: Double(bRed), bgGreen: Double(bGreen), bgBlue: Double(bBlue))
        guard fraction > 0 else { return self }
        let t = CGFloat(fraction)
        let toward: CGFloat = towardWhite ? 1 : 0
        return UIColor (red: fRed + (toward - fRed) * t,
                        green: fGreen + (toward - fGreen) * t,
                        blue: fBlue + (toward - fBlue) * t,
                        alpha: fAlpha)
    }

    static func make (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> TTColor
    {

        return UIColor(red: red,
                       green: green,
                       blue: blue,
                       alpha: 1.0)
    }
  
    static func make (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) -> TTColor
    {
        return UIColor(hue: hue,
                       saturation: saturation,
                       brightness: brightness,
                       alpha: alpha)
    }
    
    static func make (color: Color) -> UIColor
    {
        UIColor (red: CGFloat (color.red) / 65535.0,
                 green: CGFloat (color.green) / 65535.0,
                 blue: CGFloat (color.blue) / 65535.0,
                 alpha: 1.0)
    }
    
    static func transparent () -> UIColor {
        return UIColor.clear
    }
}

extension UIImage {
    public convenience init (cgImage: CGImage, size: CGSize) {
        self.init (cgImage: cgImage, scale: -1, orientation: .up)
        //self.init (cgImage: cgImage)
    }
}

extension NSAttributedString {
    func fuzzyHasSelectionBackground (_ ret: Bool) -> Bool
    {
        return ret
    }
}
#endif

