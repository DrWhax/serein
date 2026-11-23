// VP9 inverse transforms, adapted from go-vp9 (BSD-2-Clause).
// Fixed-point butterfly stages follow the VP9 decoding specification, section 8.7.
enum VP9Transform {
    typealias Line = InlineArray<32, Int>
    static func wrap(_ v: Int) -> Int { Int(Int16(truncatingIfNeeded: v)) }
    static func round(_ v: Int) -> Int { wrap((v + 8192) >> 14) }
    static let cp1 = 16364
    static let cp2 = 16305
    static let cp3 = 16207
    static let cp4 = 16069
    static let cp5 = 15893
    static let cp6 = 15679
    static let cp7 = 15426
    static let cp8 = 15137
    static let cp9 = 14811
    static let cp10 = 14449
    static let cp11 = 14053
    static let cp12 = 13623
    static let cp13 = 13160
    static let cp14 = 12665
    static let cp15 = 12140
    static let cp16 = 11585
    static let cp17 = 11003
    static let cp18 = 10394
    static let cp19 = 9760
    static let cp20 = 9102
    static let cp21 = 8423
    static let cp22 = 7723
    static let cp23 = 7005
    static let cp24 = 6270
    static let cp25 = 5520
    static let cp26 = 4756
    static let cp27 = 3981
    static let cp28 = 3196
    static let cp29 = 2404
    static let cp30 = 1606
    static let cp31 = 804
    static let sp1 = 5283
    static let sp2 = 9929
    static let sp3 = 13377
    static let sp4 = 15212
    static func idct4(_ io: inout Line) {
        let s0 = (round(((io[0]) + (io[2])) * cp16))
        let s1 = (round(((io[0]) - (io[2])) * cp16))
        let s2 = (round((io[1])*cp24 - (io[3])*cp8))
        let s3 = (round((io[1])*cp8 + (io[3])*cp24))
        io[0] = wrap(wrap(s0 + s3))
        io[1] = wrap(wrap(s1 + s2))
        io[2] = wrap(wrap(s1 - s2))
        io[3] = wrap(wrap(s0 - s3))
    }

    // ---- 4-point inverse ADST (spec §8.7.1.2) ----

    static func iadst4(_ io: inout Line) {
        let s0 = sp1 * (io[0])
        let s1 = sp2 * (io[0])
        let s2 = sp3 * (io[1])
        let s3 = sp4 * (io[2])
        let s4 = sp1 * (io[2])
        let s5 = sp2 * (io[3])
        let s6 = sp4 * (io[3])
        let s7 = (io[0]) - (io[2]) + (io[3])
        let x0 = s0 + s3 + s5
        let x1 = s1 - s4 - s6
        let x2 = sp3 * s7
        let x3 = s2
        io[0] = round(x0 + x3)
        io[1] = round(x1 + x3)
        io[2] = round(x2)
        io[3] = round(x0 + x1 - x3)
    }

    // ---- 8-point inverse DCT (spec §8.7.1.3 / libvpx vp9_idct8_c) ----

    static func idct8(_ io: inout Line) {
        // stage 1: butterflies on the 4 odd positions
        let s4 = round((io[1])*cp28 - (io[7])*cp4)
        let s7 = round((io[1])*cp4 + (io[7])*cp28)
        let s5 = round((io[5])*cp12 - (io[3])*cp20)
        let s6 = round((io[5])*cp20 + (io[3])*cp12)

        // stage 2: even half via cospi16 / cospi8,24
        let e0 = round(((io[0]) + (io[4])) * cp16)
        let e1 = round(((io[0]) - (io[4])) * cp16)
        let e2 = round((io[2])*cp24 - (io[6])*cp8)
        let e3 = round((io[2])*cp8 + (io[6])*cp24)
        // combine odds
        let o4 = wrap((s4) + (s5))
        let o5 = wrap((s4) - (s5))
        let o6 = wrap(-(s6) + (s7))
        let o7 = wrap((s6) + (s7))

        // stage 3: even butterfly + cospi16 cross
        let f0 = wrap((e0) + (e3))
        let f1 = wrap((e1) + (e2))
        let f2 = wrap((e1) - (e2))
        let f3 = wrap((e0) - (e3))
        let f5 = round(((o6) - (o5)) * cp16)
        let f6 = round(((o6) + (o5)) * cp16)

        // stage 4: output
        io[0] = wrap((f0) + (o7))
        io[1] = wrap((f1) + (f6))
        io[2] = wrap((f2) + (f5))
        io[3] = wrap((f3) + (o4))
        io[4] = wrap((f3) - (o4))
        io[5] = wrap((f2) - (f5))
        io[6] = wrap((f1) - (f6))
        io[7] = wrap((f0) - (o7))
    }

    // ---- 8-point inverse ADST (spec §8.7.1.4 / libvpx vp9_iadst8_c) ----

    // iadst8 is the 8-point inverse ADST, a line-for-line port of libvpx
    // iadst8_c (vpx_dsp/inv_txfm.c): 3 butterfly stages with WRAPLOW (wl) and
    // dct_const_round_shift (drs), then the signed output permutation.
    static func iadst8(_ io: inout Line) {
        var x0 = (io[7])
        var x1 = (io[0])
        var x2 = (io[5])
        var x3 = (io[2])
        var x4 = (io[3])
        var x5 = (io[4])
        var x6 = (io[1])
        var x7 = (io[6])

        if x0|x1|x2|x3|x4|x5|x6|x7 == 0 {
            for i in 0..<8 {
                io[i] = 0
            }
            return
        }

        // stage 1
        var s0 = cp2*x0 + cp30*x1
        var s1 = cp30*x0 - cp2*x1
        var s2 = cp10*x2 + cp22*x3
        var s3 = cp22*x2 - cp10*x3
        var s4 = cp18*x4 + cp14*x5
        var s5 = cp14*x4 - cp18*x5
        var s6 = cp26*x6 + cp6*x7
        var s7 = cp6*x6 - cp26*x7

        x0 = (round(s0 + s4))
        x1 = (round(s1 + s5))
        x2 = (round(s2 + s6))
        x3 = (round(s3 + s7))
        x4 = (round(s0 - s4))
        x5 = (round(s1 - s5))
        x6 = (round(s2 - s6))
        x7 = (round(s3 - s7))

        // stage 2
        s0 = x0
        s1 = x1
        s2 = x2
        s3 = x3
        s4 = cp8*x4 + cp24*x5
        s5 = cp24*x4 - cp8*x5
        s6 = -cp24*x6 + cp8*x7
        s7 = cp8*x6 + cp24*x7

        x0 = wrap(s0 + s2)
        x1 = wrap(s1 + s3)
        x2 = wrap(s0 - s2)
        x3 = wrap(s1 - s3)
        x4 = (round(s4 + s6))
        x5 = (round(s5 + s7))
        x6 = (round(s4 - s6))
        x7 = (round(s5 - s7))

        // stage 3
        s2 = cp16 * (x2 + x3)
        s3 = cp16 * (x2 - x3)
        s6 = cp16 * (x6 + x7)
        s7 = cp16 * (x6 - x7)

        x2 = (round(s2))
        x3 = (round(s3))
        x6 = (round(s6))
        x7 = (round(s7))

        io[0] = wrap(x0)
        io[1] = wrap(-x4)
        io[2] = wrap(x6)
        io[3] = wrap(-x2)
        io[4] = wrap(x3)
        io[5] = wrap(-x7)
        io[6] = wrap(x5)
        io[7] = wrap(-x1)
    }

    // ---- 16-point inverse DCT (spec §8.7.1.5 / libvpx vp9_idct16_c) ----

    // idct16 is a line-for-line port of libvpx idct16_c (vpx_dsp/inv_txfm.c).
    // All step values are kept in int16 range via wl (WRAPLOW); drs is
    // dct_const_round_shift. s1/s2 mirror libvpx step1/step2.
    static func idct16(_ io: inout Line) {
        var s1 = [Int](repeating: 0, count: 16), s2 = s1

        // stage 1
        s1[0] = (io[0])
        s1[1] = (io[8])
        s1[2] = (io[4])
        s1[3] = (io[12])
        s1[4] = (io[2])
        s1[5] = (io[10])
        s1[6] = (io[6])
        s1[7] = (io[14])
        s1[8] = (io[1])
        s1[9] = (io[9])
        s1[10] = (io[5])
        s1[11] = (io[13])
        s1[12] = (io[3])
        s1[13] = (io[11])
        s1[14] = (io[7])
        s1[15] = (io[15])

        // stage 2
        (s2[0], s2[1], s2[2], s2[3]) = (s1[0], s1[1], s1[2], s1[3])
        (s2[4], s2[5], s2[6], s2[7]) = (s1[4], s1[5], s1[6], s1[7])
        s2[8] = (round(s1[8]*cp30 - s1[15]*cp2))
        s2[15] = (round(s1[8]*cp2 + s1[15]*cp30))
        s2[9] = (round(s1[9]*cp14 - s1[14]*cp18))
        s2[14] = (round(s1[9]*cp18 + s1[14]*cp14))
        s2[10] = (round(s1[10]*cp22 - s1[13]*cp10))
        s2[13] = (round(s1[10]*cp10 + s1[13]*cp22))
        s2[11] = (round(s1[11]*cp6 - s1[12]*cp26))
        s2[12] = (round(s1[11]*cp26 + s1[12]*cp6))

        // stage 3
        (s1[0], s1[1], s1[2], s1[3]) = (s2[0], s2[1], s2[2], s2[3])
        s1[4] = (round(s2[4]*cp28 - s2[7]*cp4))
        s1[7] = (round(s2[4]*cp4 + s2[7]*cp28))
        s1[5] = (round(s2[5]*cp12 - s2[6]*cp20))
        s1[6] = (round(s2[5]*cp20 + s2[6]*cp12))
        s1[8] = wrap(s2[8] + s2[9])
        s1[9] = wrap(s2[8] - s2[9])
        s1[10] = wrap(-s2[10] + s2[11])
        s1[11] = wrap(s2[10] + s2[11])
        s1[12] = wrap(s2[12] + s2[13])
        s1[13] = wrap(s2[12] - s2[13])
        s1[14] = wrap(-s2[14] + s2[15])
        s1[15] = wrap(s2[14] + s2[15])

        // stage 4
        s2[0] = (round((s1[0] + s1[1]) * cp16))
        s2[1] = (round((s1[0] - s1[1]) * cp16))
        s2[2] = (round(s1[2]*cp24 - s1[3]*cp8))
        s2[3] = (round(s1[2]*cp8 + s1[3]*cp24))
        s2[4] = wrap(s1[4] + s1[5])
        s2[5] = wrap(s1[4] - s1[5])
        s2[6] = wrap(-s1[6] + s1[7])
        s2[7] = wrap(s1[6] + s1[7])
        (s2[8], s2[15]) = (s1[8], s1[15])
        s2[9] = (round(-s1[9]*cp8 + s1[14]*cp24))
        s2[14] = (round(s1[9]*cp24 + s1[14]*cp8))
        s2[10] = (round(-s1[10]*cp24 - s1[13]*cp8))
        s2[13] = (round(-s1[10]*cp8 + s1[13]*cp24))
        (s2[11], s2[12]) = (s1[11], s1[12])

        // stage 5
        s1[0] = wrap(s2[0] + s2[3])
        s1[1] = wrap(s2[1] + s2[2])
        s1[2] = wrap(s2[1] - s2[2])
        s1[3] = wrap(s2[0] - s2[3])
        s1[4] = s2[4]
        s1[5] = (round((s2[6] - s2[5]) * cp16))
        s1[6] = (round((s2[5] + s2[6]) * cp16))
        s1[7] = s2[7]
        s1[8] = wrap(s2[8] + s2[11])
        s1[9] = wrap(s2[9] + s2[10])
        s1[10] = wrap(s2[9] - s2[10])
        s1[11] = wrap(s2[8] - s2[11])
        s1[12] = wrap(-s2[12] + s2[15])
        s1[13] = wrap(-s2[13] + s2[14])
        s1[14] = wrap(s2[13] + s2[14])
        s1[15] = wrap(s2[12] + s2[15])

        // stage 6
        s2[0] = wrap(s1[0] + s1[7])
        s2[1] = wrap(s1[1] + s1[6])
        s2[2] = wrap(s1[2] + s1[5])
        s2[3] = wrap(s1[3] + s1[4])
        s2[4] = wrap(s1[3] - s1[4])
        s2[5] = wrap(s1[2] - s1[5])
        s2[6] = wrap(s1[1] - s1[6])
        s2[7] = wrap(s1[0] - s1[7])
        (s2[8], s2[9]) = (s1[8], s1[9])
        s2[10] = (round((-s1[10] + s1[13]) * cp16))
        s2[13] = (round((s1[10] + s1[13]) * cp16))
        s2[11] = (round((-s1[11] + s1[12]) * cp16))
        s2[12] = (round((s1[11] + s1[12]) * cp16))
        (s2[14], s2[15]) = (s1[14], s1[15])

        // stage 7
        io[0] = wrap(wrap(s2[0] + s2[15]))
        io[1] = wrap(wrap(s2[1] + s2[14]))
        io[2] = wrap(wrap(s2[2] + s2[13]))
        io[3] = wrap(wrap(s2[3] + s2[12]))
        io[4] = wrap(wrap(s2[4] + s2[11]))
        io[5] = wrap(wrap(s2[5] + s2[10]))
        io[6] = wrap(wrap(s2[6] + s2[9]))
        io[7] = wrap(wrap(s2[7] + s2[8]))
        io[8] = wrap(wrap(s2[7] - s2[8]))
        io[9] = wrap(wrap(s2[6] - s2[9]))
        io[10] = wrap(wrap(s2[5] - s2[10]))
        io[11] = wrap(wrap(s2[4] - s2[11]))
        io[12] = wrap(wrap(s2[3] - s2[12]))
        io[13] = wrap(wrap(s2[2] - s2[13]))
        io[14] = wrap(wrap(s2[1] - s2[14]))
        io[15] = wrap(wrap(s2[0] - s2[15]))
    }

    // ---- 16-point inverse ADST (spec §8.7.1.6 / libvpx vp9_iadst16_c) ----

    // iadst16 is a line-for-line port of libvpx iadst16_c (vpx_dsp/inv_txfm.c):
    // 4 butterfly stages with WRAPLOW (wl) / dct_const_round_shift (drs), then the
    // signed output permutation. Inputs are int16-range so int32 intermediates do
    // not overflow.
    static func iadst16(_ io: inout Line) {
        var x0 = (io[15])
        var x1 = (io[0])
        var x2 = (io[13])
        var x3 = (io[2])
        var x4 = (io[11])
        var x5 = (io[4])
        var x6 = (io[9])
        var x7 = (io[6])
        var x8 = (io[7])
        var x9 = (io[8])
        var x10 = (io[5])
        var x11 = (io[10])
        var x12 = (io[3])
        var x13 = (io[12])
        var x14 = (io[1])
        var x15 = (io[14])

        if x0|x1|x2|x3|x4|x5|x6|x7|x8|x9|x10|x11|x12|x13|x14|x15 == 0 {
            for i in 0..<16 {
                io[i] = 0
            }
            return
        }

        // stage 1
        var s0 = x0*cp1 + x1*cp31
        var s1 = x0*cp31 - x1*cp1
        var s2 = x2*cp5 + x3*cp27
        var s3 = x2*cp27 - x3*cp5
        var s4 = x4*cp9 + x5*cp23
        var s5 = x4*cp23 - x5*cp9
        var s6 = x6*cp13 + x7*cp19
        var s7 = x6*cp19 - x7*cp13
        var s8 = x8*cp17 + x9*cp15
        var s9 = x8*cp15 - x9*cp17
        var s10 = x10*cp21 + x11*cp11
        var s11 = x10*cp11 - x11*cp21
        var s12 = x12*cp25 + x13*cp7
        var s13 = x12*cp7 - x13*cp25
        var s14 = x14*cp29 + x15*cp3
        var s15 = x14*cp3 - x15*cp29

        x0 = (round(s0 + s8))
        x1 = (round(s1 + s9))
        x2 = (round(s2 + s10))
        x3 = (round(s3 + s11))
        x4 = (round(s4 + s12))
        x5 = (round(s5 + s13))
        x6 = (round(s6 + s14))
        x7 = (round(s7 + s15))
        x8 = (round(s0 - s8))
        x9 = (round(s1 - s9))
        x10 = (round(s2 - s10))
        x11 = (round(s3 - s11))
        x12 = (round(s4 - s12))
        x13 = (round(s5 - s13))
        x14 = (round(s6 - s14))
        x15 = (round(s7 - s15))

        // stage 2
        s0 = x0
        s1 = x1
        s2 = x2
        s3 = x3
        s4 = x4
        s5 = x5
        s6 = x6
        s7 = x7
        s8 = x8*cp4 + x9*cp28
        s9 = x8*cp28 - x9*cp4
        s10 = x10*cp20 + x11*cp12
        s11 = x10*cp12 - x11*cp20
        s12 = -x12*cp28 + x13*cp4
        s13 = x12*cp4 + x13*cp28
        s14 = -x14*cp12 + x15*cp20
        s15 = x14*cp20 + x15*cp12

        x0 = wrap(s0 + s4)
        x1 = wrap(s1 + s5)
        x2 = wrap(s2 + s6)
        x3 = wrap(s3 + s7)
        x4 = wrap(s0 - s4)
        x5 = wrap(s1 - s5)
        x6 = wrap(s2 - s6)
        x7 = wrap(s3 - s7)
        x8 = (round(s8 + s12))
        x9 = (round(s9 + s13))
        x10 = (round(s10 + s14))
        x11 = (round(s11 + s15))
        x12 = (round(s8 - s12))
        x13 = (round(s9 - s13))
        x14 = (round(s10 - s14))
        x15 = (round(s11 - s15))

        // stage 3
        s0 = x0
        s1 = x1
        s2 = x2
        s3 = x3
        s4 = x4*cp8 + x5*cp24
        s5 = x4*cp24 - x5*cp8
        s6 = -x6*cp24 + x7*cp8
        s7 = x6*cp8 + x7*cp24
        s8 = x8
        s9 = x9
        s10 = x10
        s11 = x11
        s12 = x12*cp8 + x13*cp24
        s13 = x12*cp24 - x13*cp8
        s14 = -x14*cp24 + x15*cp8
        s15 = x14*cp8 + x15*cp24

        x0 = wrap(s0 + s2)
        x1 = wrap(s1 + s3)
        x2 = wrap(s0 - s2)
        x3 = wrap(s1 - s3)
        x4 = (round(s4 + s6))
        x5 = (round(s5 + s7))
        x6 = (round(s4 - s6))
        x7 = (round(s5 - s7))
        x8 = wrap(s8 + s10)
        x9 = wrap(s9 + s11)
        x10 = wrap(s8 - s10)
        x11 = wrap(s9 - s11)
        x12 = (round(s12 + s14))
        x13 = (round(s13 + s15))
        x14 = (round(s12 - s14))
        x15 = (round(s13 - s15))

        // stage 4
        s2 = -cp16 * (x2 + x3)
        s3 = cp16 * (x2 - x3)
        s6 = cp16 * (x6 + x7)
        s7 = cp16 * (-x6 + x7)
        s10 = cp16 * (x10 + x11)
        s11 = cp16 * (-x10 + x11)
        s14 = -cp16 * (x14 + x15)
        s15 = cp16 * (x14 - x15)

        x2 = (round(s2))
        x3 = (round(s3))
        x6 = (round(s6))
        x7 = (round(s7))
        x10 = (round(s10))
        x11 = (round(s11))
        x14 = (round(s14))
        x15 = (round(s15))

        io[0] = wrap(x0)
        io[1] = wrap(-x8)
        io[2] = wrap(x12)
        io[3] = wrap(-x4)
        io[4] = wrap(x6)
        io[5] = wrap(x14)
        io[6] = wrap(x10)
        io[7] = wrap(x2)
        io[8] = wrap(x3)
        io[9] = wrap(x11)
        io[10] = wrap(x15)
        io[11] = wrap(x7)
        io[12] = wrap(x5)
        io[13] = wrap(-x13)
        io[14] = wrap(x9)
        io[15] = wrap(-x1)
    }

    // ---- 32-point inverse DCT (spec §8.7.1.7 / libvpx vp9_idct32_c) ----

    // idct32 is a line-for-line port of libvpx idct32_c (vpx_dsp/inv_txfm.c):
    // 8 stages, every step kept in int16 range via wl (WRAPLOW); drs is
    // dct_const_round_shift. s1/s2 mirror libvpx step1/step2.
    static func idct32(_ io: inout Line) {
        var s1 = [Int](repeating: 0, count: 32), s2 = s1

        // stage 1
        s1[0] = (io[0])
        s1[1] = (io[16])
        s1[2] = (io[8])
        s1[3] = (io[24])
        s1[4] = (io[4])
        s1[5] = (io[20])
        s1[6] = (io[12])
        s1[7] = (io[28])
        s1[8] = (io[2])
        s1[9] = (io[18])
        s1[10] = (io[10])
        s1[11] = (io[26])
        s1[12] = (io[6])
        s1[13] = (io[22])
        s1[14] = (io[14])
        s1[15] = (io[30])
        s1[16] = (round((io[1])*cp31 - (io[31])*cp1))
        s1[31] = (round((io[1])*cp1 + (io[31])*cp31))
        s1[17] = (round((io[17])*cp15 - (io[15])*cp17))
        s1[30] = (round((io[17])*cp17 + (io[15])*cp15))
        s1[18] = (round((io[9])*cp23 - (io[23])*cp9))
        s1[29] = (round((io[9])*cp9 + (io[23])*cp23))
        s1[19] = (round((io[25])*cp7 - (io[7])*cp25))
        s1[28] = (round((io[25])*cp25 + (io[7])*cp7))
        s1[20] = (round((io[5])*cp27 - (io[27])*cp5))
        s1[27] = (round((io[5])*cp5 + (io[27])*cp27))
        s1[21] = (round((io[21])*cp11 - (io[11])*cp21))
        s1[26] = (round((io[21])*cp21 + (io[11])*cp11))
        s1[22] = (round((io[13])*cp19 - (io[19])*cp13))
        s1[25] = (round((io[13])*cp13 + (io[19])*cp19))
        s1[23] = (round((io[29])*cp3 - (io[3])*cp29))
        s1[24] = (round((io[29])*cp29 + (io[3])*cp3))

        // stage 2
        (s2[0], s2[1], s2[2], s2[3]) = (s1[0], s1[1], s1[2], s1[3])
        (s2[4], s2[5], s2[6], s2[7]) = (s1[4], s1[5], s1[6], s1[7])
        s2[8] = (round(s1[8]*cp30 - s1[15]*cp2))
        s2[15] = (round(s1[8]*cp2 + s1[15]*cp30))
        s2[9] = (round(s1[9]*cp14 - s1[14]*cp18))
        s2[14] = (round(s1[9]*cp18 + s1[14]*cp14))
        s2[10] = (round(s1[10]*cp22 - s1[13]*cp10))
        s2[13] = (round(s1[10]*cp10 + s1[13]*cp22))
        s2[11] = (round(s1[11]*cp6 - s1[12]*cp26))
        s2[12] = (round(s1[11]*cp26 + s1[12]*cp6))
        s2[16] = wrap(s1[16] + s1[17])
        s2[17] = wrap(s1[16] - s1[17])
        s2[18] = wrap(-s1[18] + s1[19])
        s2[19] = wrap(s1[18] + s1[19])
        s2[20] = wrap(s1[20] + s1[21])
        s2[21] = wrap(s1[20] - s1[21])
        s2[22] = wrap(-s1[22] + s1[23])
        s2[23] = wrap(s1[22] + s1[23])
        s2[24] = wrap(s1[24] + s1[25])
        s2[25] = wrap(s1[24] - s1[25])
        s2[26] = wrap(-s1[26] + s1[27])
        s2[27] = wrap(s1[26] + s1[27])
        s2[28] = wrap(s1[28] + s1[29])
        s2[29] = wrap(s1[28] - s1[29])
        s2[30] = wrap(-s1[30] + s1[31])
        s2[31] = wrap(s1[30] + s1[31])

        // stage 3
        (s1[0], s1[1], s1[2], s1[3]) = (s2[0], s2[1], s2[2], s2[3])
        s1[4] = (round(s2[4]*cp28 - s2[7]*cp4))
        s1[7] = (round(s2[4]*cp4 + s2[7]*cp28))
        s1[5] = (round(s2[5]*cp12 - s2[6]*cp20))
        s1[6] = (round(s2[5]*cp20 + s2[6]*cp12))
        s1[8] = wrap(s2[8] + s2[9])
        s1[9] = wrap(s2[8] - s2[9])
        s1[10] = wrap(-s2[10] + s2[11])
        s1[11] = wrap(s2[10] + s2[11])
        s1[12] = wrap(s2[12] + s2[13])
        s1[13] = wrap(s2[12] - s2[13])
        s1[14] = wrap(-s2[14] + s2[15])
        s1[15] = wrap(s2[14] + s2[15])
        s1[16] = s2[16]
        s1[31] = s2[31]
        s1[17] = (round(-s2[17]*cp4 + s2[30]*cp28))
        s1[30] = (round(s2[17]*cp28 + s2[30]*cp4))
        s1[18] = (round(-s2[18]*cp28 - s2[29]*cp4))
        s1[29] = (round(-s2[18]*cp4 + s2[29]*cp28))
        s1[19] = s2[19]
        s1[20] = s2[20]
        s1[21] = (round(-s2[21]*cp20 + s2[26]*cp12))
        s1[26] = (round(s2[21]*cp12 + s2[26]*cp20))
        s1[22] = (round(-s2[22]*cp12 - s2[25]*cp20))
        s1[25] = (round(-s2[22]*cp20 + s2[25]*cp12))
        s1[23] = s2[23]
        s1[24] = s2[24]
        s1[27] = s2[27]
        s1[28] = s2[28]

        // stage 4
        s2[0] = (round((s1[0] + s1[1]) * cp16))
        s2[1] = (round((s1[0] - s1[1]) * cp16))
        s2[2] = (round(s1[2]*cp24 - s1[3]*cp8))
        s2[3] = (round(s1[2]*cp8 + s1[3]*cp24))
        s2[4] = wrap(s1[4] + s1[5])
        s2[5] = wrap(s1[4] - s1[5])
        s2[6] = wrap(-s1[6] + s1[7])
        s2[7] = wrap(s1[6] + s1[7])
        s2[8] = s1[8]
        s2[15] = s1[15]
        s2[9] = (round(-s1[9]*cp8 + s1[14]*cp24))
        s2[14] = (round(s1[9]*cp24 + s1[14]*cp8))
        s2[10] = (round(-s1[10]*cp24 - s1[13]*cp8))
        s2[13] = (round(-s1[10]*cp8 + s1[13]*cp24))
        s2[11] = s1[11]
        s2[12] = s1[12]
        s2[16] = wrap(s1[16] + s1[19])
        s2[17] = wrap(s1[17] + s1[18])
        s2[18] = wrap(s1[17] - s1[18])
        s2[19] = wrap(s1[16] - s1[19])
        s2[20] = wrap(-s1[20] + s1[23])
        s2[21] = wrap(-s1[21] + s1[22])
        s2[22] = wrap(s1[21] + s1[22])
        s2[23] = wrap(s1[20] + s1[23])
        s2[24] = wrap(s1[24] + s1[27])
        s2[25] = wrap(s1[25] + s1[26])
        s2[26] = wrap(s1[25] - s1[26])
        s2[27] = wrap(s1[24] - s1[27])
        s2[28] = wrap(-s1[28] + s1[31])
        s2[29] = wrap(-s1[29] + s1[30])
        s2[30] = wrap(s1[29] + s1[30])
        s2[31] = wrap(s1[28] + s1[31])

        // stage 5
        s1[0] = wrap(s2[0] + s2[3])
        s1[1] = wrap(s2[1] + s2[2])
        s1[2] = wrap(s2[1] - s2[2])
        s1[3] = wrap(s2[0] - s2[3])
        s1[4] = s2[4]
        s1[5] = (round((s2[6] - s2[5]) * cp16))
        s1[6] = (round((s2[5] + s2[6]) * cp16))
        s1[7] = s2[7]
        s1[8] = wrap(s2[8] + s2[11])
        s1[9] = wrap(s2[9] + s2[10])
        s1[10] = wrap(s2[9] - s2[10])
        s1[11] = wrap(s2[8] - s2[11])
        s1[12] = wrap(-s2[12] + s2[15])
        s1[13] = wrap(-s2[13] + s2[14])
        s1[14] = wrap(s2[13] + s2[14])
        s1[15] = wrap(s2[12] + s2[15])
        s1[16] = s2[16]
        s1[17] = s2[17]
        s1[18] = (round(-s2[18]*cp8 + s2[29]*cp24))
        s1[29] = (round(s2[18]*cp24 + s2[29]*cp8))
        s1[19] = (round(-s2[19]*cp8 + s2[28]*cp24))
        s1[28] = (round(s2[19]*cp24 + s2[28]*cp8))
        s1[20] = (round(-s2[20]*cp24 - s2[27]*cp8))
        s1[27] = (round(-s2[20]*cp8 + s2[27]*cp24))
        s1[21] = (round(-s2[21]*cp24 - s2[26]*cp8))
        s1[26] = (round(-s2[21]*cp8 + s2[26]*cp24))
        s1[22] = s2[22]
        s1[23] = s2[23]
        s1[24] = s2[24]
        s1[25] = s2[25]
        s1[30] = s2[30]
        s1[31] = s2[31]

        // stage 6
        s2[0] = wrap(s1[0] + s1[7])
        s2[1] = wrap(s1[1] + s1[6])
        s2[2] = wrap(s1[2] + s1[5])
        s2[3] = wrap(s1[3] + s1[4])
        s2[4] = wrap(s1[3] - s1[4])
        s2[5] = wrap(s1[2] - s1[5])
        s2[6] = wrap(s1[1] - s1[6])
        s2[7] = wrap(s1[0] - s1[7])
        s2[8] = s1[8]
        s2[9] = s1[9]
        s2[10] = (round((-s1[10] + s1[13]) * cp16))
        s2[13] = (round((s1[10] + s1[13]) * cp16))
        s2[11] = (round((-s1[11] + s1[12]) * cp16))
        s2[12] = (round((s1[11] + s1[12]) * cp16))
        s2[14] = s1[14]
        s2[15] = s1[15]
        s2[16] = wrap(s1[16] + s1[23])
        s2[17] = wrap(s1[17] + s1[22])
        s2[18] = wrap(s1[18] + s1[21])
        s2[19] = wrap(s1[19] + s1[20])
        s2[20] = wrap(s1[19] - s1[20])
        s2[21] = wrap(s1[18] - s1[21])
        s2[22] = wrap(s1[17] - s1[22])
        s2[23] = wrap(s1[16] - s1[23])
        s2[24] = wrap(-s1[24] + s1[31])
        s2[25] = wrap(-s1[25] + s1[30])
        s2[26] = wrap(-s1[26] + s1[29])
        s2[27] = wrap(-s1[27] + s1[28])
        s2[28] = wrap(s1[27] + s1[28])
        s2[29] = wrap(s1[26] + s1[29])
        s2[30] = wrap(s1[25] + s1[30])
        s2[31] = wrap(s1[24] + s1[31])

        // stage 7
        s1[0] = wrap(s2[0] + s2[15])
        s1[1] = wrap(s2[1] + s2[14])
        s1[2] = wrap(s2[2] + s2[13])
        s1[3] = wrap(s2[3] + s2[12])
        s1[4] = wrap(s2[4] + s2[11])
        s1[5] = wrap(s2[5] + s2[10])
        s1[6] = wrap(s2[6] + s2[9])
        s1[7] = wrap(s2[7] + s2[8])
        s1[8] = wrap(s2[7] - s2[8])
        s1[9] = wrap(s2[6] - s2[9])
        s1[10] = wrap(s2[5] - s2[10])
        s1[11] = wrap(s2[4] - s2[11])
        s1[12] = wrap(s2[3] - s2[12])
        s1[13] = wrap(s2[2] - s2[13])
        s1[14] = wrap(s2[1] - s2[14])
        s1[15] = wrap(s2[0] - s2[15])
        s1[16] = s2[16]
        s1[17] = s2[17]
        s1[18] = s2[18]
        s1[19] = s2[19]
        s1[20] = (round((-s2[20] + s2[27]) * cp16))
        s1[27] = (round((s2[20] + s2[27]) * cp16))
        s1[21] = (round((-s2[21] + s2[26]) * cp16))
        s1[26] = (round((s2[21] + s2[26]) * cp16))
        s1[22] = (round((-s2[22] + s2[25]) * cp16))
        s1[25] = (round((s2[22] + s2[25]) * cp16))
        s1[23] = (round((-s2[23] + s2[24]) * cp16))
        s1[24] = (round((s2[23] + s2[24]) * cp16))
        s1[28] = s2[28]
        s1[29] = s2[29]
        s1[30] = s2[30]
        s1[31] = s2[31]

        // final stage
        io[0] = wrap(wrap(s1[0] + s1[31]))
        io[1] = wrap(wrap(s1[1] + s1[30]))
        io[2] = wrap(wrap(s1[2] + s1[29]))
        io[3] = wrap(wrap(s1[3] + s1[28]))
        io[4] = wrap(wrap(s1[4] + s1[27]))
        io[5] = wrap(wrap(s1[5] + s1[26]))
        io[6] = wrap(wrap(s1[6] + s1[25]))
        io[7] = wrap(wrap(s1[7] + s1[24]))
        io[8] = wrap(wrap(s1[8] + s1[23]))
        io[9] = wrap(wrap(s1[9] + s1[22]))
        io[10] = wrap(wrap(s1[10] + s1[21]))
        io[11] = wrap(wrap(s1[11] + s1[20]))
        io[12] = wrap(wrap(s1[12] + s1[19]))
        io[13] = wrap(wrap(s1[13] + s1[18]))
        io[14] = wrap(wrap(s1[14] + s1[17]))
        io[15] = wrap(wrap(s1[15] + s1[16]))
        io[16] = wrap(wrap(s1[15] - s1[16]))
        io[17] = wrap(wrap(s1[14] - s1[17]))
        io[18] = wrap(wrap(s1[13] - s1[18]))
        io[19] = wrap(wrap(s1[12] - s1[19]))
        io[20] = wrap(wrap(s1[11] - s1[20]))
        io[21] = wrap(wrap(s1[10] - s1[21]))
        io[22] = wrap(wrap(s1[9] - s1[22]))
        io[23] = wrap(wrap(s1[8] - s1[23]))
        io[24] = wrap(wrap(s1[7] - s1[24]))
        io[25] = wrap(wrap(s1[6] - s1[25]))
        io[26] = wrap(wrap(s1[5] - s1[26]))
        io[27] = wrap(wrap(s1[4] - s1[27]))
        io[28] = wrap(wrap(s1[3] - s1[28]))
        io[29] = wrap(wrap(s1[2] - s1[29]))
        io[30] = wrap(wrap(s1[1] - s1[30]))
        io[31] = wrap(wrap(s1[0] - s1[31]))
    }

    /// The residual of a DCT block whose only nonzero coefficient is DC: the same value at every
    /// position (libvpx vpx_idct{4,8,16,32}_1_add; equal to apply(...) for every Int16 DC,
    /// checked exhaustively by a test).
    static func dcOnly(_ dc: Int, size: Int) -> Int {
        let shift = size == 4 ? 4 : (size == 8 ? 5 : 6)
        return (round(round(dc * cp16) * cp16) + (1 << (shift-1))) >> shift
    }

    /// In place: rows, then columns. An all-zero row transforms to zeros, so it is skipped.
    static func apply(_ coefficients: inout [Int], size: Int, type: Int, lossless: Bool) {
        func transform(_ input: inout Line, sine: Bool, firstPass: Bool) {
            if lossless {
                let shift = firstPass ? 2 : 0
                var a = input[0] >> shift, b = input[3] >> shift
                var c = input[1] >> shift, d = input[2] >> shift
                a += c
                d -= b
                let e = (a - d) >> 1
                b = e - b
                c = e - c
                a -= b
                d += c
                input[0] = a; input[1] = b; input[2] = c; input[3] = d
                return
            }
            switch (size,sine) {
            case (4,false): idct4(&input)
            case (4,true): iadst4(&input)
            case (8,false): idct8(&input)
            case (8,true): iadst8(&input)
            case (16,false): idct16(&input)
            case (16,true): iadst16(&input)
            default: idct32(&input)
            }
        }
        let shift = size == 4 ? 4 : (size == 8 ? 5 : 6)
        var line = Line(repeating: 0)
        for row in 0..<size {
            let base = row*size
            var any = false
            for column in 0..<size { line[column] = coefficients[base+column]; any = any || line[column] != 0 }
            guard any else { continue }
            transform(&line,sine: type == 2 || type == 3,firstPass: true)
            for column in 0..<size { coefficients[base+column] = line[column] }
        }
        for column in 0..<size {
            for row in 0..<size { line[row] = coefficients[row*size+column] }
            transform(&line,sine: type == 1 || type == 3,firstPass: false)
            for row in 0..<size { coefficients[row*size+column] = lossless ? line[row] : (line[row] + (1 << (shift-1))) >> shift }
        }
    }
}
