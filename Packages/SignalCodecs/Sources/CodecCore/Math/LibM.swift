// The only libm entry points SignalCodecs uses. Scoped function imports keep the
// rest of Darwin (pointers, I/O, memory) out of the codec modules; the lint allows
// `import func Darwin.*` in this file only.

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

public enum LibM {
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
}
