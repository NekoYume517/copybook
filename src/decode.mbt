// 记录解码 —— EBCDIC 字节 → 类型化值
//
// ## 四条数字格式，四条互不相同的解码路径
//
// COBOL 的数值在存储层有四种完全不同的排布，任何一种读错都会得到
// "看起来合理但错误"的数字 —— 这正是大型机数据事故的典型形态：
//
// 1. **zoned decimal**（DISPLAY 数值）
//    每字节"一个完整数字"：低半字节是数字 0..9，高半字节是区号。
//    非末字节高半字节应为 0xF（`0xF1..0xF9` = 1..9）；
//    **末字节**高半字节是**符号**：0xC/0xF 正，0xD 负。
//    例：`S9(3)` 的 -123 是 `F1 F2 D3`。
//
// 2. **packed decimal**（COMP-3）
//    一字节两个数字；**末字节低半字节**是符号，高半字节是最后一个数字。
//    例：`S9(3)` 的 -123 是 `12 3D`（2 字节）。
//
// 3. **binary**（COMP / COMP-4 / BINARY）
//    大端定长整数（1/2/4 字节），有符号用补码。隐含小数由 scale 表达。
//
// 4. **浮点**（COMP-1 / COMP-2）
//    4 / 8 字节 IEEE 754 大端。
//
// ## 绝不静默修正
//
// 每个失败路径都返回带**绝对偏移**的 `DecodeError`：
//   - 记录短于 layout.byte_length → RecordTooShort
//   - zoned/packed 出现非 0..9 的半字节 → InvalidNumeric
//   - 文本字段出现非可打印 EBCDIC 字节 → InvalidEbcdic
//   - 字段区间越界（理论上不该发生，防御性检查）→ FieldOutOfBounds
//
// 不"猜"一个值、不跳过坏字段、不把非法字节当空格。

///|
/// 定点小数。
///
/// COBOL 数值的语义是 `coefficient × 10^-scale`，`negative` 单独存符号 ——
/// 不用 Double 承接，因为金额必须精确到分、且要能表示 -0（COBOL 区分 0 与 -0
/// 在某些比较场景下有意义）。
///
/// ## 为什么需要 `sign_nibble` / `pad_nibble`（字节保真）
///
/// 同一个数值在 COBOL 的 packed / zoned 存储里有**多种合法字节写法**：
///
/// | 值 | 合法字节（COMP-3, S9(4)） | 说明 |
/// |---|---|---|
/// | 1234 | `01 23 4C` | 正号 C（最常见） |
/// | 1234 | `01 23 4F` | 正号 F（IBM 对无符号字段写的，也被接受） |
/// | 1234 | `01 23 4D`？ | 否 —— D 是负号 |
/// | -1234 | `01 23 4D` | 负号 D（唯一写法） |
/// | 1234 | `12 34 0C` / `12 34 0F` | 4 位数字 + 填充 0 |
///
/// 若 decode 只留下"值是 1234、符号为正"，encode 就只能按**自己的偏好**
/// 写一个字节——原始记录里的 `F` 会被改成 `C`。数值对了，**字节不对**，
/// 于是 `decode → encode` 不再逐字节还原，「无损往返」就退化成「数值往返」。
///
/// 所以 decode 把**实际读到的**符号半字节与填充半字节一并带出来，
/// encode 优先沿用它们；调用方自己构造 `Decimal` 时才回落到默认写法。
/// `None` 表示"没有原始字节信息"（新建值 / 非十进制来源）。
pub(all) struct Decimal {
  coefficient : Int64
  scale : Int32
  negative : Bool
  /// decode 读到的符号半字节（packed 的低半字节 / zoned 的高半字节）。
  /// 取值 C/D/F；`None` 表示没有原始信息，encode 用默认写法。
  sign_nibble : Int32?
  /// decode 读到的末字节填充半字节（仅 packed，0 或 F）。
  pad_nibble : Int32?
}

///|
/// 构造 Decimal（无原始字节信息；encode 会用默认符号写法 C / F）。
pub fn Decimal::from_parts(coef : Int64, scale : Int32, neg : Bool) -> Decimal {
  {
    coefficient: coef,
    scale,
    negative: neg,
    sign_nibble: None,
    pad_nibble: None,
  }
}

///|
/// 构造 Decimal 并保留原始符号 / 填充半字节（decode 内部用，保证字节往返）。
fn decimal_with_nibbles(
  coef : Int64,
  scale : Int32,
  neg : Bool,
  sign_nibble : Int32?,
  pad_nibble : Int32?,
) -> Decimal {
  { coefficient: coef, scale, negative: neg, sign_nibble, pad_nibble, }
}

///|
/// Int64 的绝对值串。
///
/// `Int64::MIN` 的 `abs()` 回绕仍为负（二进制补码没有 +2^63），
/// `.abs().to_string()` 会输出负号、调用方再拼一个负号变成 "--..."。
/// 改用**先除后余**：|MIN| = 9223372036854775808 = (MIN/10) 的 abs × 10
/// + 8，两段都在 Int64 非负范围内。
fn int64_abs_string(v : Int64) -> String {
  if v == -9223372036854775807L - 1L {
    // MIN/10 = -922337203685477580，abs 后是高 18 位；余数 8 是末位。
    // 高位 × 10 会溢出，所以两段以字符串拼接而不是数值运算。
    "\{(-9223372036854775808L / 10L).abs()}8"
  } else {
    v.abs().to_string()
  }
}

///|
/// 渲染成字符串：`-1234567.89`、`0.005`、`42`。
///
/// 规则：
///   - scale == 0 → 不带小数点
///   - 整数部分不足时补前导 0（`0.005`，不是 `.005`）
///   - 小数部分**不裁掉尾随 0**：`1.20` 的 scale=2 就输出 `1.20`，
///     因为 COBOL 里 1.20 和 1.2 的存储宽度不同，报告应当忠实反映
///   - coefficient 为 0 时符号仍按 negative 输出（`-0.00`），与存储一致
pub fn Decimal::to_string(self : Decimal) -> String {
  let sign = if self.negative { "-" } else { "" }
  // 负 scale（尾随 P 缩放位）：值 = 系数 × 10^|scale|，十进制右移补零。
  // `9(3)PP` 存 123 → scale=-2 → "12300"。
  if self.scale < 0 {
    let sb = StringBuilder()
    sb.write_string(sign)
    sb.write_string(int64_abs_string(self.coefficient))
    for i = 0; i < -self.scale; i = i + 1 {
      sb.write_char('0')
    }
    return sb.to_string()
  }
  let digits = int64_abs_string(self.coefficient)
  if self.scale == 0 {
    return "\{sign}\{digits}"
  }
  // 小数位数多于系数位数时，左侧补 0（0.005 需要 "0" + "." + "005"）
  let padded = if digits.length() <= self.scale {
    let sb = StringBuilder()
    for i = 0; i < self.scale - digits.length() + 1; i = i + 1 {
      sb.write_char('0')
    }
    sb.write_string(digits)
    sb.to_string()
  } else {
    digits
  }
  let split = padded.length() - self.scale
  let int_part = padded[:split]
  let frac_part = padded[split:]
  "\{sign}\{int_part}.\{frac_part}"
}

///|
/// 一个字段的解码结果。
///
/// `Bool` 预留给未来的条件名（88 层）求值；当前解码器不产出它。
/// `Bytes` 用于 `REDEFINES` 的原始视图（需要按字节对外暴露时）。
pub(all) enum CellValue {
  Null
  Text(String)
  Int(Int64)
  Decimal(Decimal)
  Bool(Bool)
  Bytes(Bytes)
  /// IEEE 754 浮点（COMP-1 / COMP-2 专用；定点路径不产出它）
  Float(Double)
}

///|
/// 解码错误。每个变体都带**绝对字节偏移**（相对记录起点），
/// 便于在十六进制编辑器里直接定位。
///
/// 只 `derive(Debug)`：`derive(Eq)` 会刷 deprecation 警告，而测试里
/// 需要比较时用 `match` 更清晰（见 CONTRACT-FIX.md 修正 2）。
pub(all) suberror DecodeError {
  /// 记录字节数不足，无法按 layout 解码
  RecordTooShort(Int32, Int32)
  /// 数字字段出现非法半字节 / 符号位
  InvalidNumeric(Int32, String)
  /// 文本字段出现不可打印的 EBCDIC 字节
  InvalidEbcdic(Int32, Int32)
  /// 字段区间越界（防御性检查，正常 layout 不会触发）
  FieldOutOfBounds(String, Int32, Int32)
} derive(Debug)

///|
/// 渲染错误为一行人类可读文本（CLI 与测试用）。
pub fn DecodeError::to_display(self : DecodeError) -> String {
  match self {
    RecordTooShort(expected, actual) =>
      "record too short: expected \{expected} bytes, got \{actual}"
    InvalidNumeric(offset, detail) =>
      "invalid numeric at offset \{offset}: \{detail}"
    InvalidEbcdic(offset, byte) =>
      "invalid EBCDIC byte 0x\{hex2(byte)} at offset \{offset}"
    FieldOutOfBounds(field, offset, length) =>
      "field '\{field}' out of bounds: offset \{offset}, length \{length}"
  }
}

///|
/// 两位数十六进制（大写、补零）—— 错误消息用。
fn hex2(v : Int32) -> String {
  let sb = StringBuilder()
  let hi = (v >> 4) & 0xF
  let lo = v & 0xF
  sb.write_string(hex_digit(hi))
  sb.write_string(hex_digit(lo))
  sb.to_string()
}

///|
fn hex_digit(v : Int32) -> String {
  if v < 10 {
    v.to_string()
  } else {
    match v {
      10 => "A"
      11 => "B"
      12 => "C"
      13 => "D"
      14 => "E"
      _ => "F"
    }
  }
}

///|
/// 从 `BytesView` 里取一段，越界返回 `None`（调用方转 FieldOutOfBounds）。
fn slice_at(record : BytesView, offset : Int32, length : Int32) -> BytesView? {
  if offset < 0 || length < 0 {
    return None
  }
  if offset + length > record.length() {
    return None
  }
  Some(record[offset:offset + length])
}

///|
/// 解码 zoned decimal（DISPLAY 数值）。
///
/// **符号在最后一字节的高半字节**，这是最容易漏的一条：
///   `F1 F2 F3` → +123    `F1 F2 D3` → -123    `F1 F2 C3` → +123
///
/// **SIGN SEPARATE** 时末尾（LEADING 则开头）还有一个独立的 ASCII 符号字节：
///   EBCDIC '+' = 0x4E，EBCDIC '-' = 0x60。数字部分全是 0xF 区号。
///
/// 校验：
///   - 所有字节的低半字节必须 ≤ 9
///   - 非末字节高半字节必须是 0xF（未符号化）或 0xC/0xD（某些实现重复写符号）
///   - 末字节高半字节必须是 0xC/0xD/0xF
///
/// 无符号字段（`signed == false`）仍要接受 0xF，因为未符号化的 zoned 就是 0xF。
fn decode_zoned(
  bytes : BytesView,
  base_offset : Int32,
  signed : Bool,
  scale : Int32,
  sign_separate : Bool,
  sign_leading : Bool,
) -> Result[Decimal, DecodeError] {
  let n = bytes.length()
  if n == 0 {
    return Err(InvalidNumeric(base_offset, "empty zoned decimal field"))
  }
  // 独立符号字节：LEADING 在开头，TRAILING 在结尾。
  // LEADING 时数字是 [1..n)——首字节是符号，其余全是数字。曾经写成
  // `bytes[1:n-1]`，把最后一个数字字节也切掉了，`+123` 解出 12。
  let digit_bytes : BytesView = if sign_separate {
    if sign_leading {
      bytes[1:n]
    } else {
      bytes[:n - 1]
    }
  } else {
    bytes
  }
  let mut separate_negative = false
  if sign_separate {
    let sb = if sign_leading { bytes[0] } else { bytes[n - 1] }
    match sb.to_int() {
      0x4E => separate_negative = false // EBCDIC '+'
      0x60 => separate_negative = true // EBCDIC '-'
      other =>
        return Err(
          InvalidNumeric(
            if sign_leading {
              base_offset
            } else {
              base_offset + n - 1
            },
            "separate sign byte is 0x\{hex2(other)}, expected 0x4E (+) or 0x60 (-)",
          ),
        )
    }
  }
  let dn = digit_bytes.length()
  if dn == 0 {
    return Err(
      InvalidNumeric(base_offset, "empty zoned decimal digits (sign only)"),
    )
  }
  let mut coef : Int64 = 0
  let mut embedded_negative = false
  // 记录实际读到的符号半字节，供 encode 原样写回（0xC 与 0xF 同为正号但字节不同）
  let mut sign_nib : Int32? = None
  for i = 0; i < dn; i = i + 1 {
    let b = digit_bytes[i].to_int()
    let lo = b & 0xF
    let hi = (b >> 4) & 0xF
    if lo > 9 {
      return Err(
        InvalidNumeric(
          base_offset + i,
          "zoned digit nibble is 0x\{hex_digit(lo)}, expected 0..9 (byte 0x\{hex2(b)})",
        ),
      )
    }
    // 符号半字节的位置由 SIGN 子句决定：
    //   - TRAILING（默认）→ 末字节高半字节
    //   - LEADING（内嵌，非 SEPARATE）→ 首字节高半字节，其余字节必须 F 区
    let is_sign_pos = if sign_separate {
      false // 独立符号：数字字节全是 F 区
    } else if sign_leading {
      i == 0
    } else {
      i == dn - 1
    }
    if is_sign_pos {
      match hi {
        // 0xC / 0xF 正，0xD 负
        0xC | 0xF => embedded_negative = false
        0xD => embedded_negative = true
        _ =>
          return Err(
            InvalidNumeric(
              base_offset + i,
              "zoned sign nibble is 0x\{hex_digit(hi)}, expected C/D/F (byte 0x\{hex2(b)})",
            ),
          )
      }
      sign_nib = Some(hi)
    } else if hi != 0xF {
      return Err(
        InvalidNumeric(
          base_offset + i,
          "zoned zone nibble is 0x\{hex_digit(hi)}, expected F (byte 0x\{hex2(b)})",
        ),
      )
    }
    coef = coef * 10L + lo.to_int64()
  }
  // 无符号字段不接受负号 —— 存储说"我不带符号"，出现 0xD 就是数据错了。
  let negative = if sign_separate {
    separate_negative
  } else {
    embedded_negative
  }
  if !signed && negative {
    return Err(
      InvalidNumeric(
        base_offset + n - 1,
        "unsigned zoned decimal has negative sign (byte 0x\{hex2(digit_bytes[dn - 1].to_int())})",
      ),
    )
  }
  Ok(decimal_with_nibbles(coef, scale, negative, sign_nib, None))
}

///|
/// 解码 packed decimal（COMP-3）。
///
/// 布局：`[d1 d2] [d3 d4] ... [dn sign]`，**末字节低半字节是符号**。
///   `12 34 5D` → -12345（6 位数字，5 字节）
///
/// 总数位 = digits + scale。奇偶决定末字节是否半空：
///   total_digits 奇数 → 末字节高半字节是最后一个数字
///   total_digits 偶数 → 末字节高半字节是**填充 0**（本实现接受 0 或 F）
fn decode_packed(
  bytes : BytesView,
  base_offset : Int32,
  signed : Bool,
  scale : Int32,
  total_digits : Int32,
) -> Result[Decimal, DecodeError] {
  let n = bytes.length()
  if n == 0 {
    return Err(InvalidNumeric(base_offset, "empty packed decimal field"))
  }
  let mut coef : Int64 = 0
  let mut digit_count = 0
  for i = 0; i < n; i = i + 1 {
    let b = bytes[i].to_int()
    let hi = (b >> 4) & 0xF
    let lo = b & 0xF
    if i == n - 1 {
      // 末字节：高半字节是最后一位数字（或填充），低半字节是符号
      if digit_count < total_digits {
        if hi > 9 {
          return Err(
            InvalidNumeric(
              base_offset + i,
              "packed high nibble is 0x\{hex_digit(hi)}, expected 0..9 (byte 0x\{hex2(b)})",
            ),
          )
        }
        coef = coef * 10L + hi.to_int64()
        digit_count = digit_count + 1
      } else if hi != 0x0 && hi != 0xF {
        // 数字已满，高半字节必须是填充
        return Err(
          InvalidNumeric(
            base_offset + i,
            "packed pad nibble is 0x\{hex_digit(hi)}, expected 0 or F (byte 0x\{hex2(b)})",
          ),
        )
      }
      let neg = match lo {
        0xC | 0xF => false
        0xD => true
        _ =>
          return Err(
            InvalidNumeric(
              base_offset + i,
              "packed sign nibble is 0x\{hex_digit(lo)}, expected C/D/F (byte 0x\{hex2(b)})",
            ),
          )
      }
      if !signed && neg {
        return Err(
          InvalidNumeric(
            base_offset + i,
            "unsigned packed decimal has negative sign (byte 0x\{hex2(b)})",
          ),
        )
      }
      // 保留实际读到的符号半字节与填充半字节：0xC 与 0xF 都表示正号，
      // 但字节不同，encode 必须原样写回才能逐字节往返（见 Decimal 文档表）。
      let pad = if digit_count < total_digits || hi == 0x0 || hi == 0xF {
        Some(hi)
      } else {
        None
      }
      return Ok(decimal_with_nibbles(coef, scale, neg, Some(lo), pad))
    }
    // 非末字节：两半都是数字
    if hi > 9 {
      return Err(
        InvalidNumeric(
          base_offset + i,
          "packed high nibble is 0x\{hex_digit(hi)}, expected 0..9 (byte 0x\{hex2(b)})",
        ),
      )
    }
    if lo > 9 {
      return Err(
        InvalidNumeric(
          base_offset + i,
          "packed low nibble is 0x\{hex_digit(lo)}, expected 0..9 (byte 0x\{hex2(b)})",
        ),
      )
    }
    coef = coef * 100L + hi.to_int64() * 10L + lo.to_int64()
    digit_count = digit_count + 2
  }
  // 循环里末字节一定 return，走到这里说明 n == 0（上面已拦）
  Err(InvalidNumeric(base_offset, "malformed packed decimal"))
}

///|
/// 解码二进制整数（COMP）：大端、有符号用补码。
fn decode_binary(
  bytes : BytesView,
  base_offset : Int32,
  signed : Bool,
  scale : Int32,
) -> Result[Decimal, DecodeError] {
  let n = bytes.length()
  if n == 0 || n > 8 {
    return Err(
      InvalidNumeric(base_offset, "COMP width must be 1..8 bytes, got \{n}"),
    )
  }
  let mut raw : Int64 = 0
  for i = 0; i < n; i = i + 1 {
    raw = (raw << 8) | bytes[i].to_int().to_int64()
  }
  let mut negative = false
  if signed {
    // 补码：最高位置 1 则为负
    let sign_bit = 1L << (n * 8 - 1)
    if (raw & sign_bit) != 0L {
      negative = true
      // 取反加一得到绝对值（在 n 字节宽度内）
      let mask = if n == 8 { -1L } else { (1L << (n * 8)) - 1L }
      raw = ((raw ^ mask) & mask) + 1L
    }
  }
  Ok(Decimal::from_parts(raw, scale, negative))
}

///|
/// 解码文本字段：EBCDIC → String，然后 `trim_end` 掉尾部空格（0x40）。
///
/// **校验**：每个字节必须可打印（`ebcdic_is_printable`）。控制字节出现在
/// 字符字段里几乎总是"字段边界算错了"的信号 —— 静默解码成字符串会让
/// 错位问题一路传到下游，所以这里直接报错。
///
/// 只 trim **尾部**空格；前导空格是有效内容（COBOL 字符字段左对齐）。
fn decode_text(
  bytes : BytesView,
  base_offset : Int32,
) -> Result[String, DecodeError] {
  let n = bytes.length()
  // 先校验字节，再解码 —— 避免把非法字节解码成 FFFD 之后无法定位
  for i = 0; i < n; i = i + 1 {
    let b = bytes[i].to_int()
    if !ebcdic_is_printable(b) {
      return Err(InvalidEbcdic(base_offset + i, b))
    }
  }
  let s = ebcdic_decode(bytes)
  // trim_end：去掉尾部 0x40（EBCDIC 空格）
  let mut end = n
  while end > 0 && bytes[end - 1].to_int() == 0x40 {
    end = end - 1
  }
  if end == n {
    Ok(s)
  } else {
    // 按字节数裁切，保持与 EBCDIC 字节一一对应（cp037 单字节映射）
    Ok(s[:end].to_owned())
  }
}

///|
/// 解码 COMP-1 / COMP-2。
///
/// `mode` 决定字节解释方式，两者**完全互不兼容**：
///   - `Hfp`：IBM 主机十六进制浮点（1 符号 + 7 位 excess-64 指数 + 24/56 位尾数）
///   - `Ieee754`：IEEE 754 binary32 / binary64（1 符号 + 8 位 excess-127/1023 指数）
///
/// 同一份 4 字节 `41 18 00 00` 在 HFP 下是 1.5、在 IEEE 下是 9.5 ——
/// 所以必须先由数据源确定模式，不允许猜。
fn decode_float_bytes(
  bytes : BytesView,
  base_offset : Int32,
  double_precision : Bool,
  mode : FloatMode,
) -> Result[CellValue, DecodeError] {
  let want = if double_precision { 8 } else { 4 }
  if bytes.length() != want {
    return Err(
      InvalidNumeric(
        base_offset,
        "float field must be \{want} bytes, got \{bytes.length()}",
      ),
    )
  }
  match mode {
    Hfp =>
      if double_precision {
        Ok(Float(hfp_decode_long(bytes)))
      } else {
        Ok(Float(hfp_decode_short(bytes)))
      }
    Ieee754 => {
      let mut raw : UInt64 = 0UL
      for i = 0; i < want; i = i + 1 {
        raw = (raw << 8) | bytes[i].to_int().to_uint64()
      }
      if double_precision {
        Ok(Float(raw.to_int64().reinterpret_as_double()))
      } else {
        // 单精度：低 32 位就是 binary32 位模式（raw 只有 4 字节，右移 32 恒为 0）
        let bits : Int32 = raw.to_int()
        Ok(Float(Float::reinterpret_from_int(bits).to_double()))
      }
    }
  }
}

///|
/// 解码单个字段。
///
/// 分派依据是 `pic.category` + `pic.usage`，顺序有讲究：
///   - National → 双字节 UTF-16（本子集按 EBCDIC 双字节对解码为文本）
///   - Edited / Alphanumeric / Alphabetic → 文本路径
///   - Numeric → 按 usage 分派到 zoned / packed / binary / float
fn decode_field(
  field : FieldLayout,
  record : BytesView,
  float_mode : FloatMode,
) -> Result[CellValue, DecodeError] {
  let offset = field.offset
  let length = field.byte_length
  let bytes = match slice_at(record, offset, length) {
    Some(v) => v
    None => return Err(FieldOutOfBounds(field.name, offset, length))
  }
  let pic = field.pic
  match pic.category {
    National => {
      // 国家字符：每字符 2 字节。本子集按"每个 2 字节对是一个 EBCDIC 字符 + 填充"
      // 处理 —— 取每对的第 1 字节做文本解码，第 2 字节必须是 0x00 或空格。
      let out = StringBuilder()
      let mut i = 0
      while i + 1 < length {
        let hi = bytes[i].to_int()
        let lo = bytes[i + 1].to_int()
        if !ebcdic_is_printable(hi) {
          return Err(InvalidEbcdic(offset + i, hi))
        }
        if lo != 0x00 && lo != 0x40 {
          return Err(InvalidEbcdic(offset + i + 1, lo))
        }
        out.write_char(ebcdic_char_to_unicode(hi))
        i = i + 2
      }
      let s = out.to_string()
      // trim_end 空格
      let mut end = s.length()
      while end > 0 && s[end - 1] == ' ' {
        end = end - 1
      }
      Ok(Text(s[:end].to_owned()))
    }
    // 编辑型在存储层是**显示字符**，与 X(n) 一样按文本读。
    Edited | Alphanumeric | Alphabetic =>
      match decode_text(bytes, offset) {
        Ok(s) => Ok(Text(s))
        Err(e) => Err(e)
      }
    Numeric =>
      match pic.usage {
        Display => {
          let r = decode_zoned(
            bytes,
            offset,
            pic.signed,
            pic.scale,
            pic.sign_separate,
            pic.sign_leading,
          )
          match r {
            Ok(d) =>
              // scale == 0 时用 Int 表示整数，避免下游把整数当小数处理
              if pic.scale == 0 && !pic.signed {
                Ok(Int(d.coefficient))
              } else {
                Ok(Decimal(d))
              }
            Err(e) => Err(e)
          }
        }
        Comp3 => {
          // 与布局层 pic_byte_length 同源：存储位数用 storage_digits
          // （P 缩放位不占存储）；P 的数值语义已折进 pic.scale，
          // 解出的系数配上该 scale 即还原真实值。
          let total = pic.storage_digits
          match decode_packed(bytes, offset, pic.signed, pic.scale, total) {
            Ok(d) => Ok(Decimal(d))
            Err(e) => Err(e)
          }
        }
        Comp =>
          match decode_binary(bytes, offset, pic.signed, pic.scale) {
            Ok(d) => Ok(Decimal(d))
            Err(e) => Err(e)
          }
        Comp1 => decode_float_bytes(bytes, offset, false, float_mode)
        Comp2 => decode_float_bytes(bytes, offset, true, float_mode)
      }
  }
}

///|
/// 解码一条记录为 `Map[字段路径, 值]`。
///
/// 键是 `FieldLayout.path`（如 `CUSTOMER-RECORD.FLAGS.ACTIVE`），
/// 因为 COBOL 允许不同组下有同名字段，裸名会撞。
///
/// **REDEFINES 的每个视图都会出现在 map 里**（同一段字节解两次），
/// 这是刻意的：调用方可能想同时看数值视图和原始字节视图。
/// ## REDEFINES 视图解码失败不报错
///
/// 这是关键设计决定。`REDEFINES` 的语义是"同一段字节的另一种解释"，而
/// **不同解释未必都自洽**：`redefines.cpy` 里 `LIMIT-AMT` 是 packed 数值，
/// `ALT-VIEW.RAW-BYTE` 是 `X(6)` 文本 —— 同一段字节读成 packed 是正确的
/// 数字，读成文本却会撞上 `0x12` 这种不可打印字节。
///
/// 若对重定义视图也强校验，任何 `REDEFINES` 都会让整条记录解码失败，
/// 这与 COBOL 的实际用法（"这份数据有两种读法，我只看其中一种"）矛盾。
///
/// 因此：
///   - **主视图**（`redefine_group == 0`）失败 → 整条报错，绝不静默修正
///   - **重定义视图**（`redefine_group != 0`）失败 → 该键置为 `Null`，
///     map 里仍保留键本身（调用方能看出"有这个视图但没解出来"）
///
/// 需要区分"真值"与"解不出"时用 `decode_record_strict`：它对所有视图
/// 一律报错，供 `verify` 这类自检命令使用。
pub fn decode_record(
  layout : RecordLayout,
  record : BytesView,
) -> Result[Map[String, CellValue], DecodeError] {
  decode_record_impl(layout, record, false)
}

///|
/// 严格版 `decode_record`：**任何**视图解码失败都报错。
///
/// 供 `copybook verify` 与单元测试使用 —— 想证明"整条记录每个字节都自洽"
/// 时应当用这个，而不是宽容版。
pub fn decode_record_strict(
  layout : RecordLayout,
  record : BytesView,
) -> Result[Map[String, CellValue], DecodeError] {
  decode_record_impl(layout, record, true)
}

///|
fn decode_record_impl(
  layout : RecordLayout,
  record : BytesView,
  strict : Bool,
) -> Result[Map[String, CellValue], DecodeError] {
  if record.length() < layout.byte_length {
    return Err(RecordTooShort(layout.byte_length, record.length()))
  }
  let out : Map[String, CellValue] = Map([])
  for field in layout.fields {
    // OCCURS n>1：数据面按元素逐个展开，键带 1 起始下标 `PATH(i)`。
    // 布局层的 `byte_length` 是单元素长度，`total_length` 才是全部存储；
    // 曾经只解第 0 个元素，`OCCURS 5` 的记录有 4/5 的数据被静默丢掉。
    if field.occurs > 1 {
      let mut k = 1
      while k <= field.occurs {
        let elem : FieldLayout = {
          ..field,
          offset: field.offset + (k - 1) * field.byte_length,
        }
        let key = "\{field.path}(\{k})"
        match decode_field(elem, record, layout.float_mode) {
          Ok(v) => out[key] = v
          Err(e) =>
            if strict || field.redefine_group == 0 {
              return Err(e)
            } else {
              out[key] = Null
            }
        }
        k = k + 1
      }
      continue
    }
    let r = decode_field(field, record, layout.float_mode)
    match r {
      Ok(v) => out[field.path] = v
      Err(e) =>
        if strict || field.redefine_group == 0 {
          return Err(e)
        } else {
          // 重定义视图解不出：保留键，值为 Null
          out[field.path] = Null
        }
    }
  }
  Ok(out)
}

///|
/// 解码为有序数组，顺序与 `layout.fields` 一致。
///
/// 适合 `render_table` 这类需要稳定列序的场合 —— `Map` 的迭代序是插入序，
/// 但显式数组更不容易被后续改动破坏。
pub fn decode_record_ordered(
  layout : RecordLayout,
  record : BytesView,
) -> Result[Array[CellValue], DecodeError] {
  if record.length() < layout.byte_length {
    return Err(RecordTooShort(layout.byte_length, record.length()))
  }
  let out : Array[CellValue] = []
  for field in layout.fields {
    // 与 decode_record_impl 的 OCCURS 展开保持一致：每个元素各占一列
    if field.occurs > 1 {
      let mut k = 1
      while k <= field.occurs {
        let elem : FieldLayout = {
          ..field,
          offset: field.offset + (k - 1) * field.byte_length,
        }
        match decode_field(elem, record, layout.float_mode) {
          Ok(v) => out.push(v)
          Err(e) => return Err(e)
        }
        k = k + 1
      }
      continue
    }
    match decode_field(field, record, layout.float_mode) {
      Ok(v) => out.push(v)
      Err(e) => return Err(e)
    }
  }
  Ok(out)
}

///|
/// 批量解码定长记录流。
///
/// `record_length` 由调用方给出（因为真实文件里记录之间可能有 RDW/BDW 头、
/// 或记录长度由文件头声明，不一定等于 layout 的字节数）。
///
/// 规则：
///   - `record_length < layout.byte_length` → RecordTooShort（无法解码）
///   - `data.length() % record_length != 0` → RecordTooShort（残缺尾记录，
///     **不**静默丢弃）
///   - 记录之间**不**做任何对齐填充跳过
pub fn decode_records(
  layout : RecordLayout,
  data : BytesView,
  record_length : Int32,
) -> Result[Array[Map[String, CellValue]], DecodeError] {
  if record_length <= 0 {
    return Err(RecordTooShort(layout.byte_length, 0))
  }
  if record_length < layout.byte_length {
    return Err(RecordTooShort(layout.byte_length, record_length))
  }
  let total = data.length()
  if total % record_length != 0 {
    return Err(RecordTooShort(record_length, total % record_length))
  }
  let out : Array[Map[String, CellValue]] = []
  let mut pos = 0
  while pos < total {
    let rec = data[pos:pos + record_length]
    match decode_record(layout, rec) {
      Ok(m) => out.push(m)
      Err(e) => return Err(e)
    }
    pos = pos + record_length
  }
  Ok(out)
}

///|
/// 单元格的字符串形式（表格 / JSONL 共用）。
///
/// `Null` 渲染成空串（表格里显示为空白；JSONL 里由 output 层转 `null`）。
pub fn CellValue::to_display(self : CellValue) -> String {
  match self {
    Null => ""
    Text(s) => s
    Int(i) => i.to_string()
    Decimal(d) => d.to_string()
    Float(f) => f.to_string()
    Bool(b) => if b { "true" } else { "false" }
    Bytes(bs) => {
      let sb = StringBuilder()
      for i = 0; i < bs.length(); i = i + 1 {
        if i > 0 {
          sb.write_char(' ')
        }
        sb.write_string(hex2(bs[i].to_int()))
      }
      sb.to_string()
    }
  }
}
