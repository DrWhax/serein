// The only libm entry points SignalCodecs uses. Scoped function imports keep the
// rest of Darwin (pointers, I/O, memory) out of the codec modules; the lint allows
// `import func Darwin.*` in this file only.

import func Darwin.cos
import func Darwin.cosf
import func Darwin.pow
import func Darwin.powf

public enum LibM {
    public static func cosf(_ x: Float) -> Float { Darwin.cosf(x) }
    public static func cos(_ x: Double) -> Double { Darwin.cos(x) }
    public static func powf(_ x: Float, _ y: Float) -> Float { Darwin.powf(x, y) }
    public static func pow(_ x: Double, _ y: Double) -> Double { Darwin.pow(x, y) }
}
