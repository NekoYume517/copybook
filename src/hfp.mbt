// ============================================================================
// hfp.mbt — IBM 十六进制浮点（HFP, Hexadecimal Floating Point）
//
// COBOL 的 COMP-1 / COMP-2 在不同实现里是**两种互不兼容的字节布局**：
//
//   · IBM z/OS 主机原生 → HFP（base-16 指数）
//   · GnuCOBOL / Micro Focus / x86 主机 → IEEE 754 binary32 / binary64
//
// 本项目以**大型机记录**为目标（EBCDIC cp037、COMP-3、定长记录），所以
// COMP-1 / COMP-2 默认按 IBM HFP 解释；需要读 GnuCOBOL 产物时用
// `--float-mode ieee`（`FloatMode::Ieee754`）。
//
// ── HFP 格式（IBM z/Architecture Principles of Operation，SA22-7832） ──
//
//   COMP-1（短）：1 位符号 | 7 位指数 | 24 位尾数  = 4 字节
//   COMP-2（长）：1 位符号 | 7 位指数 | 56 位尾数  = 8 字节
//
//   值 = (-1)^sign × (F / 2^frac_bits) × 16^(exp7 - 64)
//
//   指数是 **base-16 的 excess-64**（不是 IEEE 的 base-2 excess-1023）；
//   尾数 F 是十六进制有效数字，规格化时最高十六进制位非零，
//   即 F ∈ [2^(frac_bits-4), 2^frac_bits)。
//
//   例：1.5 → F = 0x180000, exp7 = 65(0x41) → `41 18 00 00`
//        （1.5 = (0x180000/2^24) × 16^1 = 0.09375 × 16）
//   对照：同一个 1.5 的 IEEE binary32 是 `3F C0 00 00` —— 字节完全不同。
//
// ── 与 IEEE 754 的关键差异（README「目标标准与兼容范围」逐条列出） ──
//
//   1. 指教基数是 16 而非 2 → 同一数值的指数值差 4 倍
//   2. 没有 NaN / ±Infinity / 非规格化数 / 负零的特殊语义
//      （±0 就是「尾数为 0」，符号位仍保留）
//   3. 没有渐进下溢：小于 16^-64 × 2^-4 = 2^-260 的值直接下溢
//   4. 精度：COMP-1 有 24 位尾数（≈6.02 位十进制），COMP-2 有 56 位
//      （≈16.86 位十进制）—— COMP-2 比 IEEE double（53 位）多 3 位
//
// 第 4 条对「字节保真」有直接影响，见 FIDELITY.md：
// COMP-2 可以存放 double 存不下的尾数，此时 decode 会丢低 3 位。
// ============================================================================

///|
/// 浮点表示选择。
///
/// - `Hfp`：IBM 主机十六进制浮点（默认，本项目目标平台）
/// - `Ieee754`：IEEE 754 binary32 / binary64（GnuCOBOL、Micro Focus、x86）
pub(all) enum FloatMode {
  Hfp
  Ieee754
} derive(Eq, Debug)

///|
/// HFP 指数偏置（excess-64）。
const HFP_BIAS : Int32 = 64

///|
/// COMP-1 尾数位数（6 个十六进制数字）。
const HFP_SHORT_FRAC_BITS : Int32 = 24

///|
/// COMP-2 尾数位数（14 个十六进制数字）。
const HFP_LONG_FRAC_BITS : Int32 = 56

///|
/// 判断 double 的符号位（区分 +0.0 与 -0.0）。
fn double_is_negative(v : Double) -> Bool {
  let s = (v.reinterpret_as_uint64() >> 63) & 1UL
  s == 1UL
}

///|
/// 用**逐次乘 / 除 2** 而不是 `@math.pow(2.0, k)`：乘除 2 的幂在二进制
/// 浮点里是精确运算（只动指数位），而 `pow` 在极端指数上会引入 1 ulp 误差。
/// k 的取值范围是 [-280, 228]，循环次数在两百次量级，代价可以忽略。
fn scale_pow2(v : Double, k : Int32) -> Double {
  let mut r = v
  if k > 0 {
    for i = 0; i < k; i = i + 1 {
      r = r * 2.0
    }
  } else {
    for i = 0; i < -k; i = i + 1 {
      r = r / 2.0
    }
  }
  r
}

///|
/// 解码 COMP-1（4 字节 HFP，大端）。
///
/// 时间 / 空间都是常数；不使用 `pow`，结果对可表示的值**精确**
/// （24 位尾数 < double 的 53 位，`frac.to_double()` 无损）。
pub fn hfp_decode_short(bytes : BytesView) -> Double {
  let b0 = bytes[0].to_int()
  let b1 = bytes[1].to_int()
  let b2 = bytes[2].to_int()
  let b3 = bytes[3].to_int()
  let sign = (b0 >> 7) & 1
  let exp7 = b0 & 0x7F
  let frac : Int32 = (b1 << 16) | (b2 << 8) | b3
  if frac == 0 {
    // IBM HFP 的零就是「尾数为 0」；符号位保留（-0 与 +0 字节不同）
    return if sign == 1 { -0.0 } else { 0.0 }
  }
  // value = frac / 2^24 × 16^(exp7-64) = frac × 2^(4×(exp7-64) - 24)
  let mut v = frac.to_double()
  v = scale_pow2(v, 4 * (exp7 - HFP_BIAS) - HFP_SHORT_FRAC_BITS)
  if sign == 1 {
    v = -v
  }
  v
}

///|
/// 解码 COMP-2（8 字节 HFP，大端）。
///
/// 尾数 56 位 > double 的 53 位，所以当原始尾数低 3 位非零时，
/// 转成 double 会**丢 3 位**（按最近偶数舍入）。这是 double 的表达能力
/// 所限，不是实现缺陷 —— FIDELITY.md 明确列出该边界。
pub fn hfp_decode_long(bytes : BytesView) -> Double {
  let mut raw : UInt64 = 0UL
  for i = 0; i < 8; i = i + 1 {
    raw = (raw << 8) | bytes[i].to_int().to_uint64()
  }
  let sign = (raw >> 63) & 1UL
  let exp7 = ((raw >> 56) & 0x7FUL).to_int()
  let frac : UInt64 = raw & 0x00FFFFFFFFFFFFFFUL
  if frac == 0UL {
    return if sign == 1UL { -0.0 } else { 0.0 }
  }
  let mut v = frac.to_double()
  v = scale_pow2(v, 4 * (exp7 - HFP_BIAS) - HFP_LONG_FRAC_BITS)
  if sign == 1UL {
    v = -v
  }
  v
}

///|
/// 取 double 的二进制结构：符号位、53 位有效数 S（含隐藏位）、指数 k，
/// 满足 `|v| = S × 2^k`。
///
/// 返回 `Err` 的情况都不可能在 HFP 里表达，交给调用方按「绝不静默修正」
/// 报错：
///   - NaN / ±Infinity：HFP 没有这两种特殊值
///   - double 的非规格化数（|v| < 2^-1022）：HFP 的最小值是 2^-260，
///     比非规格化 double 大得多，所以这一支必然下溢
fn decompose_double(v : Double) -> Result[(UInt64, Int32), String] {
  let bits = v.reinterpret_as_uint64()
  let biased = ((bits >> 52) & 0x7FFUL).to_int()
  let mant = bits & 0xFFFFFFFFFFFFFUL
  if biased == 0x7FF {
    return Err("NaN / Infinity is not representable in IBM HFP")
  }
  if biased == 0 {
    // 尾数为 0 的零已在调用方处理；剩下的是非规格化数
    return Err("value is smaller than the smallest IBM HFP magnitude (2^-260)")
  }
  // 规格化：1.mant × 2^(biased-1023)，S = 2^52 | mant ∈ [2^52, 2^53)
  let s = mant | 0x10000000000000UL
  Ok((s, biased - 1075))
}

///|
/// 编码 COMP-1（4 字节 HFP，大端）。
///
/// 舍入为**最近偶数**。尾数溢出到 2^24 时重新规格化（尾数回到 2^20、
/// 指数 +1）。指数越界（含下溢）一律报错，不静默截断。
pub fn hfp_encode_short(
  v : Double,
  offset : Int32,
) -> Result[Array[Int32], DecodeError] {
  // ±0：HFP 用「尾数全 0」表示，符号位保留以便 -0.0 字节往返一致
  if v == 0.0 {
    let neg = double_is_negative(v)
    return Ok([if neg { 0x80 } else { 0x00 }, 0x00, 0x00, 0x00])
  }
  let (s, k) = match decompose_double(v) {
    Ok(p) => p
    Err(msg) => return Err(InvalidNumeric(offset, msg))
  }
  let neg = v < 0.0
  // 解 value = F × 2^(4×(exp7-64) - 24)，F ∈ [2^20, 2^24)：
  //   F = S × 2^w，w ∈ [-32, -29]，且 w ≡ (k+24) (mod 4)
  //   exp7 = 64 + (k + 24 - w) / 4
  let u = k + HFP_SHORT_FRAC_BITS
  let r = (u % 4 + 4) % 4
  let w = r - 32
  let e7 = HFP_BIAS + (u - w) / 4
  // F = round(S / 2^-w)，最近偶数
  let sh = -w
  let mut f = s >> sh
  let rem = s & ((1UL << sh) - 1UL)
  let half = 1UL << (sh - 1)
  if rem > half || (rem == half && (f & 1UL) == 1UL) {
    f = f + 1UL
  }
  let mut exp7 = e7
  // 舍入进位：尾数达到 2^24 说明尾数是 1.0，回退成 2^20 并进一位指数
  if f == 1UL << HFP_SHORT_FRAC_BITS {
    f = 1UL << (HFP_SHORT_FRAC_BITS - 4)
    exp7 = exp7 + 1
  }
  if exp7 < 0 {
    return Err(
      InvalidNumeric(
        offset, "value underflows COMP-1 (|v| < 2^-260 is not representable in IBM HFP)",
      ),
    )
  }
  if exp7 > 127 {
    return Err(
      InvalidNumeric(
        offset, "value overflows COMP-1 (|v| >= 16^63 is not representable in IBM HFP)",
      ),
    )
  }
  let b0 = (if neg { 0x80 } else { 0x00 }) | exp7
  Ok([
    b0,
    (f >> 16).to_int() & 0xFF,
    (f >> 8).to_int() & 0xFF,
    f.to_int() & 0xFF,
  ])
}

///|
/// 编码 COMP-2（8 字节 HFP，大端）。
///
/// COMP-2 的尾数是 56 位，比 double 的 53 位多 3 位，所以从 double 编码
/// **不需要舍入**（`F = S << w` 是精确左移）。反方向（HFP → double）
/// 才会丢位，见 `hfp_decode_long`。
pub fn hfp_encode_long(
  v : Double,
  offset : Int32,
) -> Result[Array[Int32], DecodeError] {
  if v == 0.0 {
    let neg = double_is_negative(v)
    return Ok([
      if neg {
        0x80
      } else {
        0x00
      },
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ])
  }
  let (s, k) = match decompose_double(v) {
    Ok(p) => p
    Err(msg) => return Err(InvalidNumeric(offset, msg))
  }
  let neg = v < 0.0
  // value = F × 2^(4×(exp7-64) - 56)，F ∈ [2^52, 2^56)：
  //   F = S × 2^w，w ∈ [0, 3]，且 w ≡ (k+56) (mod 4)
  let u = k + HFP_LONG_FRAC_BITS
  let w = (u % 4 + 4) % 4
  let exp7 = HFP_BIAS + (u - w) / 4
  let f = s << w
  if exp7 < 0 {
    return Err(
      InvalidNumeric(
        offset, "value underflows COMP-2 (|v| < 2^-260 is not representable in IBM HFP)",
      ),
    )
  }
  if exp7 > 127 {
    return Err(
      InvalidNumeric(
        offset, "value overflows COMP-2 (|v| >= 16^63 is not representable in IBM HFP)",
      ),
    )
  }
  let b0 = (if neg { 0x80 } else { 0x00 }) | exp7
  let out : Array[Int32] = [b0]
  for i = 1; i < 8; i = i + 1 {
    let shift = (8 - i) * 8 - 8
    let byte_val : Int32 = ((f >> shift) & 0xFFUL).to_int()
    out.push(byte_val)
  }
  Ok(out)
}
