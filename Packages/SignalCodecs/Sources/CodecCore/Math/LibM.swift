// Keep system imports in the codecs limited to these libm functions.
#if os(Linux)
import func Glibc.cos
import func Glibc.cosf
import func Glibc.pow
import func Glibc.powf
import func Glibc.sin
import func Glibc.sinf
import func Glibc.exp
import func Glibc.tan
import func Glibc.atan
import func Glibc.log10
#else
import func Darwin.cos
import func Darwin.cosf
import func Darwin.pow
import func Darwin.powf
import func Darwin.sin
import func Darwin.sinf
import func Darwin.exp
import func Darwin.tan
import func Darwin.atan
import func Darwin.log10
#endif

public enum LibM {
#if os(Linux)
    public static func cosf(_ x: Float) -> Float { Glibc.cosf(x) }
    public static func cos(_ x: Double) -> Double { Glibc.cos(x) }
    public static func powf(_ x: Float, _ y: Float) -> Float { Glibc.powf(x, y) }
    public static func pow(_ x: Double, _ y: Double) -> Double { Glibc.pow(x, y) }
    public static func sin(_ x: Double) -> Double { Glibc.sin(x) }
    public static func sinf(_ x: Float) -> Float { Glibc.sinf(x) }
    public static func exp(_ x: Double) -> Double { Glibc.exp(x) }
    public static func tan(_ x: Double) -> Double { Glibc.tan(x) }
    public static func atan(_ x: Double) -> Double { Glibc.atan(x) }
    public static func log10(_ x: Double) -> Double { Glibc.log10(x) }
#else
    public static func cosf(_ x: Float) -> Float { Darwin.cosf(x) }
    public static func cos(_ x: Double) -> Double { Darwin.cos(x) }
    public static func powf(_ x: Float, _ y: Float) -> Float { Darwin.powf(x, y) }
    public static func pow(_ x: Double, _ y: Double) -> Double { Darwin.pow(x, y) }
    public static func sin(_ x: Double) -> Double { Darwin.sin(x) }
    public static func sinf(_ x: Float) -> Float { Darwin.sinf(x) }
    public static func exp(_ x: Double) -> Double { Darwin.exp(x) }
    public static func tan(_ x: Double) -> Double { Darwin.tan(x) }
    public static func atan(_ x: Double) -> Double { Darwin.atan(x) }
    public static func log10(_ x: Double) -> Double { Darwin.log10(x) }
#endif
}
