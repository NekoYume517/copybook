// 记录编码 —— 类型化值 → EBCDIC 字节
//
// ## 目标：decode 的严格逆运算
//
// 验收标准是 `decode → encode` **逐字节还原**。这意味着编码不能"按最自然的
// 方式写"，而必须精确复现解码所接受的每一种字节形态。下面几处是必须刻意对齐的：
//
// 1. **zoned 数字的区号**：解码接受 0xF（未符号化）、0xC、0xD 三种高半字节。
//    编码一律写 **0xF**（正）或 **0xD**（负）—— 这是 IBM 的标准形态，
//    也是绝大多数真实数据的形态。因此「0xC 开头的正数」解码后编码会变成 0xF，
//    这类输入在往返测试里必须排除（它不是标准形态）。
//
// 2. **packed 的填位**：total_digits 为偶数时末字节高半字节是填充。
//    解码接受 0x0 与 0xF，编码一律写 0x0。
//
// 3. **文本的尾部填充**：编码到固定宽度，不足补 0x40（EBCDIC 空格）。
//    解码时 trim 掉的就是这些 0x40，所以往返成立。
//
// 4. **负数零**：`Decimal{coefficient: 0, negative: true}` 编码成 `-0`，
//    解码回 `negative: true` —— 符号位必须保留，否则往返不一致。

///|
/// 一条记录的可写字节缓冲。
///
/// 用 `Array[Byte]` 而不是在 `Bytes` 上原地写：MoonBit 的 `Bytes` 不可变，
/// 且这里需要按偏移随机写（REDEFINES 会让不同字段写同一区间）。
priv struct Writer {
  buf : Array[Byte]
}

///|
fn Writer::new(size : Int32) -> Writer {
  let buf : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    // 初始填充 EBCDIC 空格 0x40：FILLER 等不参与编解码的字节区域
    // 按 COBOL「未赋值工作存储区 = 空格」的惯例落盘，而不是 0x00。
    buf.push(b'\x40')
  }
  { buf, }
}

///|
fn Writer::set(self : Writer, offset : Int32, value : Int32) -> Unit {
  self.buf[offset] = value.to_byte()
}

///|
fn Writer::to_bytes(self : Writer) -> Bytes {
  Bytes::from_array(self.buf)
}

///|
/// 把 `Decimal` 拆成"数字串 + 符号"。
///
/// 数字串是 `coefficient` 的十进制表示（不含符号），长度可能**短于**
/// 字段需要的位数（此时左侧补 0），也可能**长于**（溢出，报错）。
///
/// Int64::MIN 的 `abs()` 回绕仍为负，直接 `.abs().to_string()` 会产出
/// 带负号的串——与调用方再拼的负号叠加成 "--..."。用同 decode 侧的
/// 先除后余方案（两函数在同一契约上，串格式必须一致）。
fn decimal_digits(d : Decimal) -> String {
  let c = d.coefficient
  if c == -9223372036854775807L - 1L {
    // 与 decode 侧 int64_abs_string 同构：MIN/10 的 abs 拼 "8"
    "\{(-9223372036854775808L / 10L).abs()}8"
  } else {
    c.abs().to_string()
  }
}

///|
/// 计算编码实际写入的**存储位数**。
///
/// 必须用 `storage_digits`，不能用 `digits + scale`：P 缩放位不占存储
/// （`PIC PP9(3)` 存储是 3 字节 zoned，不是 5 字节；`PIC 9(3)PP` 是 3 字节，
/// 不是 1 字节）。布局层 `pic_byte_length` 的宽度同源于此，编码宽度一旦
/// 与布局宽度不一致，pad 之后就会越界写 `Writer::set` panic。
/// P 的数值语义（×10^±k）由 `as_decimal` → `align_scale` 在编码前折算，
/// 不通过拉宽存储表达。
fn field_storage_digits(pic : PicClause) -> Int32 {
  pic.storage_digits
}

///|
/// 把数字串左补 0 到恰好 `width` 位。超长返回 `None`（调用方报溢出）。
///
/// 绝不截断：静默截断会把 1234567 写成 12345，是灾难性的静默数据损坏。
fn pad_digits(digits : String, width : Int32) -> String? {
  let n = digits.length()
  if n > width {
    return None
  }
  let sb = StringBuilder()
  for i = 0; i < width - n; i = i + 1 {
    sb.write_char('0')
  }
  sb.write_string(digits)
  Some(sb.to_string())
}

///|
/// 编码 zoned decimal（DISPLAY 数值）。
///
/// 布局：每位一个字节，`0xF0 | digit`；末字节高半字节换成正/负号。
///   123  → `F1 F2 F3`
///   -123 → `F1 F2 D3`
///
/// **SIGN SEPARATE** 时另有一个独立符号字节（EBCDIC '+' = 0x4E，'-' = 0x60），
/// TRAILING（默认）在数字之后，LEADING 在数字之前。
fn encode_zoned(
  w : Writer,
  offset : Int32,
  pic : PicClause,
  d : Decimal,
) -> Result[Unit, DecodeError] {
  let width = field_storage_digits(pic)
  let digits = decimal_digits(d)
  let padded = match pad_digits(digits, width) {
    Some(s) => s
    None =>
      return Err(
        InvalidNumeric(
          offset,
          "value \{digits} has \{digits.length()} digits, field holds \{width}",
        ),
      )
  }
  let sign_nibble = if d.negative { 0xD } else { 0xF }
  if pic.sign_separate {
    let sign_byte = if d.negative { 0x60 } else { 0x4E }
    let digit_start = if pic.sign_leading { 1 } else { 0 }
    for i = 0; i < width; i = i + 1 {
      let digit = padded[i].to_int() - '0'.to_int()
      w.set(offset + digit_start + i, 0xF0 | digit)
    }
    // 独立符号字节：LEADING 在前，TRAILING 在后
    if pic.sign_leading {
      w.set(offset, sign_byte)
    } else {
      w.set(offset + width, sign_byte)
    }
  } else if pic.sign_leading {
    // 内嵌 LEADING 符号：首字节高半字节是符号，其余字节 F 区。
    // 与 decode_zoned 的 is_sign_pos 逻辑严格对称。
    for i = 0; i < width; i = i + 1 {
      let digit = padded[i].to_int() - '0'.to_int()
      let zone = if i == 0 { sign_nibble } else { 0xF }
      w.set(offset + i, (zone << 4) | digit)
    }
  } else {
    for i = 0; i < width; i = i + 1 {
      let digit = padded[i].to_int() - '0'.to_int()
      let zone = if i == width - 1 { sign_nibble } else { 0xF }
      w.set(offset + i, (zone << 4) | digit)
    }
  }
  Ok(())
}

///|
/// 编码 packed decimal（COMP-3）。
///
/// 布局：每字节两个数字，末字节低半字节是符号。
///   123  → `12 3C`
///   -123 → `12 3D`
///   1234 → `12 34 0C`（末字节高半字节填充 0）
fn encode_packed(
  w : Writer,
  offset : Int32,
  pic : PicClause,
  d : Decimal,
) -> Result[Unit, DecodeError] {
  // 存储宽度按 storage_digits（P 不占存储，见 field_storage_digits）；
  // bytes_needed 与布局层 pic_byte_length 的 Comp3 公式同源。
  let width = field_storage_digits(pic)
  let bytes_needed = (width + 2) / 2
  let digits = decimal_digits(d)
  let padded = match pad_digits(digits, width) {
    Some(s) => s
    None =>
      return Err(
        InvalidNumeric(
          offset,
          "value \{digits} has \{digits.length()} digits, field holds \{width}",
        ),
      )
  }
  // 符号半字节：
  //   - 有符号字段（PIC 带 S）：正 0xC、负 0xD（负零在 packed 里合法，保留）
  //   - 无符号字段：一律 0xF。IBM 标准规定无符号 packed 的正号是 0xF，
  //     不是 0xC —— 用 0xC 会让标准生成的 `12 3F` 无法字节一致地往返。
  //     （decode 侧接受 C/D/F 三种正号，所以旧写法只是丢往返，不丢数据。）
  let sign_nibble = if pic.signed {
    if d.negative {
      0xD
    } else {
      0xC
    }
  } else {
    0xF
  }
  // 数字串 + 符号半字节，按半字节流写出
  let mut digit_index = 0
  for i = 0; i < bytes_needed; i = i + 1 {
    let hi = if digit_index < width {
      let v = padded[digit_index].to_int() - '0'.to_int()
      digit_index = digit_index + 1
      v
    } else {
      0
    }
    let lo = if i == bytes_needed - 1 {
      sign_nibble
    } else if digit_index < width {
      let v = padded[digit_index].to_int() - '0'.to_int()
      digit_index = digit_index + 1
      v
    } else {
      0
    }
    w.set(offset + i, (hi << 4) | lo)
  }
  Ok(())
}

///|
/// 编码二进制整数（COMP）：大端、有符号用补码。
fn encode_binary(
  w : Writer,
  offset : Int32,
  pic : PicClause,
  d : Decimal,
) -> Result[Unit, DecodeError] {
  // 与布局层 pic_byte_length 的 Comp 分支同源：容量按 storage_digits
  // （P 缩放位不占存储，binary 里存的是缩放前的系数）。
  let total = field_storage_digits(pic)
  let width = if total <= 4 {
    1
  } else if total <= 9 {
    2
  } else if total <= 18 {
    4
  } else {
    0
  }
  if width == 0 {
    return Err(
      InvalidNumeric(offset, "COMP supports at most 18 digits, got \{total}"),
    )
  }
  // 容量检查：n 字节有符号能表示 -2^(8n-1) .. 2^(8n-1)-1。
  // **十进制位数也必须校验**（C8）：`PIC S9(2) COMP` 只占 1 字节，二进制
  // 容量 -128..127 足够装 100，但 COBOL 的字段语义是「最多 2 位十进制数」
  // —— 写 100 会静默改变字段的数值含义（MOVE 99 与 MOVE 100 走不同的
  // 显示路径）。zoned/packed 都按位数拒绝，COMP 不能例外。
  let bits = width * 8
  let limit : Int64 = 1L << (bits - 1)
  let coef = d.coefficient
  let dec_limit : Int64 = match field_storage_digits(pic) {
    n => {
      let mut v : Int64 = 1
      let mut i = 0
      while i < n {
        if v > 92233720368547758L {
          // 位数 > 18 已在解析期拒绝；这里只是防御
          v = 9223372036854775807L
          break
        }
        v = v * 10L
        i = i + 1
      }
      v
    }
  }
  if coef >= dec_limit || coef <= -dec_limit {
    return Err(
      InvalidNumeric(
        offset,
        "value \{coef} exceeds \{field_storage_digits(pic)} decimal digits (field holds at most \{dec_limit - 1})",
      ),
    )
  }
  if pic.signed {
    if d.negative && coef > limit {
      return Err(
        InvalidNumeric(
          offset,
          "value \{coef} overflows signed \{width}-byte COMP",
        ),
      )
    }
    if !d.negative && coef >= limit {
      return Err(
        InvalidNumeric(
          offset,
          "value \{coef} overflows signed \{width}-byte COMP",
        ),
      )
    }
  } else {
    if d.negative && coef != 0L {
      return Err(
        InvalidNumeric(offset, "negative value \{coef} in unsigned COMP field"),
      )
    }
    let ulimit : Int64 = 1L << bits
    if coef >= ulimit {
      return Err(
        InvalidNumeric(
          offset,
          "value \{coef} overflows unsigned \{width}-byte COMP",
        ),
      )
    }
  }
  // 转成补码的无符号位模式。
  //
  // **负零在 COMP 里不存在**：二进制补码没有 -0 的表示，`-0` 与 `0` 是
  // 同一串字节。因此 `Decimal{coefficient:0, negative:true}` 编码成全 0 字节，
  // 解码回来是 `negative:false`。这不是 bug，是 COMP 与 zoned/packed 的
  // 本质差异（后两者有独立的符号半字节，能表示 -0）。
  let raw = if d.negative && coef != 0L {
    // -coef 的补码：~coef + 1，在 width 字节内
    let mask : Int64 = if width == 8 { -1L } else { (1L << bits) - 1L }
    (((coef ^ mask) & mask) + 1L) & mask
  } else {
    coef
  }
  for i = 0; i < width; i = i + 1 {
    let shift = (width - 1 - i) * 8
    let byte_val = ((raw >> shift) & 0xFFL).to_int()
    w.set(offset + i, byte_val)
  }
  Ok(())
}

///|
/// 编码文本字段：EBCDIC 编码后右侧补 0x40 到固定宽度。
///
/// 超长**报错**（不截断）—— 截断会静默丢数据。
fn encode_text(
  w : Writer,
  offset : Int32,
  width : Int32,
  s : StringView,
) -> Result[Unit, DecodeError] {
  let strict = ebcdic_encode_strict(s)
  let codes = match strict {
    Some(v) => v
    None =>
      return Err(
        InvalidNumeric(
          offset, "text contains characters not representable in cp037 EBCDIC",
        ),
      )
  }
  let n = codes.length()
  if n > width {
    return Err(
      InvalidNumeric(offset, "text length \{n} exceeds field width \{width}"),
    )
  }
  for i = 0; i < n; i = i + 1 {
    w.set(offset + i, codes[i])
  }
  // 尾部填充 EBCDIC 空格 0x40
  for i = n; i < width; i = i + 1 {
    w.set(offset + i, 0x40)
  }
  Ok(())
}

///|
/// 把 `Decimal` 的 scale 对齐到字段期望的 scale。
///
/// **这是 JSON 往返保真的关键。** JSON 没有定点小数类型：`5.00` 序列化成
/// `5` 再读回来，`parse_decimal_text("5")` 给出的是 `scale=0, coef=5`，
/// 而字段需要 `scale=2`（即 500 分）。若不在这里对齐，就会把 `5.00` 写成
/// 分币值 `0.05` —— 100 倍的数据损坏，而且**不会报错**。
///
/// 规则：
///   - 实际 scale 小于期望 → 系数乘以 10 的幂（`5` → `500`）
///   - 实际 scale 大于期望 → 多出来的低位必须全为零，否则报精度损失
///   - 相等 → 原样返回
pub fn align_scale(
  d : Decimal,
  expected : Int32,
  offset : Int32,
) -> Result[Decimal, DecodeError] {
  if d.scale == expected {
    return Ok(d)
  }
  if d.scale < expected {
    let mut coef = d.coefficient
    let mut k = d.scale
    while k < expected {
      // Int64 上限约 9.2e18，留一位余量防乘法溢出
      if coef > 922337203685477580L || coef < -922337203685477580L {
        return Err(
          InvalidNumeric(
            offset, "decimal overflows Int64 after scale alignment",
          ),
        )
      }
      coef = coef * 10L
      k = k + 1
    }
    Ok(Decimal::from_parts(coef, expected, d.negative))
  } else {
    let mut coef = d.coefficient
    let mut k = d.scale
    while k > expected {
      if coef % 10L != 0L {
        return Err(
          InvalidNumeric(
            offset, "value has more fractional digits than the field allows",
          ),
        )
      }
      coef = coef / 10L
      k = k - 1
    }
    Ok(Decimal::from_parts(coef, expected, d.negative))
  }
}

///|
/// 把 `CellValue` 归一化为 `Decimal`（数值字段用）。
///
/// 接受三种输入：
///   - `Decimal` 直接用，scale 对齐到字段
///   - `Int` 视为 scale=0 的整数，再对齐到字段
///   - `Text` 解析成十进制串（便于从 JSONL 读回来），再对齐到字段
///
/// 三者最后都经过 `align_scale`，保证「值」而不是「文本形状」决定编码结果。
/// 其余类型报错 —— 不猜。
fn as_decimal(
  v : CellValue,
  offset : Int32,
  expected_scale : Int32,
) -> Result[Decimal, DecodeError] {
  match v {
    Decimal(d) => align_scale(d, expected_scale, offset)
    Int(i) =>
      // C12 修复：负系数必须与 negative 标志**不重复表达**。
      // 旧写法 from_parts(-42, 0, true) 造出 coefficient=-42 且
      // negative=true 的双负号；encode_binary 只看 negative，对 -42
      // 再取一次补码得到 +42 —— 符号翻转。CLI 的 JSON 路径走 Text
      // 掩盖了它，但库 API 的 Int 输入会写错字节。
      // 规范化：系数恒为绝对值，符号只由 negative 表达。
      align_scale(
        Decimal::from_parts(if i < 0L { -i } else { i }, 0, i < 0L),
        expected_scale,
        offset,
      )
    Text(s) =>
      match parse_decimal_text(s) {
        Some(d) => align_scale(d, expected_scale, offset)
        None =>
          Err(InvalidNumeric(offset, "cannot parse '\{s}' as a decimal number"))
      }
    Null =>
      // 空值写 0（COBOL 字段没有 NULL，未赋值的数值就是 0）
      Ok(Decimal::from_parts(0L, expected_scale, false))
    _ =>
      Err(
        InvalidNumeric(
          offset, "expected a numeric value, got a non-numeric cell",
        ),
      )
  }
}

///|
/// 解析 `-123.45` / `42` / `0.005` 这类十进制文本。
///
/// 返回的 `scale` 由**文本的小数位数**决定（调用方负责比对期望 scale）。
fn parse_decimal_text(s : StringView) -> Decimal? {
  let text = s.to_owned()
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut negative = false
  if text[0] == '-' {
    negative = true
    i = 1
  } else if text[0] == '+' {
    i = 1
  }
  let mut coef : Int64 = 0
  let mut scale = 0
  let mut seen_dot = false
  let mut seen_digit = false
  while i < n {
    let c = text[i]
    if c == '.' {
      if seen_dot {
        return None
      }
      seen_dot = true
    } else if c >= '0' && c <= '9' {
      seen_digit = true
      coef = coef * 10L + (c.to_int() - '0'.to_int()).to_int64()
      if seen_dot {
        scale = scale + 1
      }
    } else {
      return None
    }
    i = i + 1
  }
  if !seen_digit {
    return None
  }
  Some(Decimal::from_parts(coef, scale, negative))
}

///|
/// 把 `CellValue` 归一化为文本（字符字段用）。
fn as_text(v : CellValue) -> String {
  match v {
    Text(s) => s
    Int(i) => i.to_string()
    Decimal(d) => d.to_string()
    Float(f) => f.to_string()
    Bool(b) => if b { "true" } else { "false" }
    Null => ""
    Bytes(_) => ""
  }
}

///|
/// 编码单个字段到 `Writer`。
///
/// **REDEFINES 的处理**：重定义视图写同一段字节。若 map 里同时给了主视图和
/// 重定义视图的值，写入顺序决定最终字节 —— 本实现按 `layout.fields` 的顺序
/// （主视图在前、重定义视图在后）写，因此**后写的重定义视图会覆盖**。
///
/// 这与"用哪个视图产生数据"一致：想用 RAW-BYTE 就说清楚，不要两边都给。
fn encode_field(
  w : Writer,
  field : FieldLayout,
  values : Map[String, CellValue],
) -> Result[Unit, DecodeError] {
  let pic = field.pic
  let offset = field.offset
  let length = field.byte_length
  // 取值的顺序：优先完整路径，其次字段名（宽容一点，方便手写 JSON）
  let v = match values.get(field.path) {
    Some(x) => x
    None =>
      match values.get(field.name) {
        Some(x) => x
        None => Null
      }
  }
  match pic.category {
    National => {
      // 双字节：第 1 字节 EBCDIC 字符，第 2 字节 0x00
      let s = as_text(v)
      if s.length() > pic.digits {
        return Err(
          InvalidNumeric(
            offset,
            "text length \{s.length()} exceeds N(\{pic.digits})",
          ),
        )
      }
      let codes = match ebcdic_encode_strict(s) {
        Some(c) => c
        None =>
          return Err(
            InvalidNumeric(offset, "text not representable in cp037 EBCDIC"),
          )
      }
      for i = 0; i < pic.digits; i = i + 1 {
        if i < codes.length() {
          w.set(offset + i * 2, codes[i])
        } else {
          w.set(offset + i * 2, 0x40)
        }
        // 第二字节写 EBCDIC 空格 0x40（C11）：decode 接受 0x00 或 0x40，
        // 但 0x00 不是合法 EBCDIC —— 标准工具生成的 N 字段填充是空格。
        // 写 0x40 让标准数据逐字节往返；decode 的宽容接受保持不变。
        w.set(offset + i * 2 + 1, 0x40)
      }
      Ok(())
    }
    Edited | Alphanumeric | Alphabetic =>
      match encode_text(w, offset, length, as_text(v)) {
        Ok(_) => Ok(())
        Err(e) => Err(e)
      }
    Numeric =>
      match pic.usage {
        Display => {
          let d = match as_decimal(v, offset, pic.scale) {
            Ok(d) => d
            Err(e) => return Err(e)
          }
          if !pic.signed && d.negative && d.coefficient != 0L {
            return Err(
              InvalidNumeric(offset, "negative value in unsigned field"),
            )
          }
          if d.negative && !pic.signed {
            // -0 在无符号字段里也无意义：归为零
            encode_zoned(
              w,
              offset,
              pic,
              Decimal::from_parts(d.coefficient, d.scale, false),
            )
          } else {
            encode_zoned(w, offset, pic, d)
          }
        }
        Comp3 => {
          let d = match as_decimal(v, offset, pic.scale) {
            Ok(d) => d
            Err(e) => return Err(e)
          }
          if !pic.signed && d.negative && d.coefficient != 0L {
            return Err(
              InvalidNumeric(offset, "negative value in unsigned COMP-3 field"),
            )
          }
          encode_packed(w, offset, pic, d)
        }
        Comp => {
          let d = match as_decimal(v, offset, pic.scale) {
            Ok(d) => d
            Err(e) => return Err(e)
          }
          encode_binary(w, offset, pic, d)
        }
        Comp1 => encode_float_bytes(w, offset, length, v, false)
        Comp2 => encode_float_bytes(w, offset, length, v, true)
      }
  }
}

///|
/// 编码 IEEE 754 浮点（COMP-1 = 4 字节单精度，COMP-2 = 8 字节双精度），大端。
///
/// 接受 `Float` 直接写入，也接受数值文本（便于从 JSONL 往返）。
/// `width` 是布局层算出的字段字节数，用于越界防御。
fn encode_float_bytes(
  w : Writer,
  offset : Int32,
  width : Int32,
  v : CellValue,
  double_precision : Bool,
) -> Result[Unit, DecodeError] {
  let want = if double_precision { 8 } else { 4 }
  if width != want {
    return Err(
      InvalidNumeric(offset, "float field must be \{want} bytes, got \{width}"),
    )
  }
  let d : Double = match v {
    Float(f) => f
    Int(i) => i.to_double()
    Decimal(dd) => dd.coefficient.to_double() / pow10(dd.scale)
    Text(s) =>
      try @string.parse_double(s) catch {
        _ =>
          return Err(InvalidNumeric(offset, "cannot parse '\{s}' as a float"))
      } noraise {
        x => x
      }
    Null => 0.0
    _ =>
      return Err(
        InvalidNumeric(
          offset, "expected a numeric value, got a non-numeric cell",
        ),
      )
  }
  let raw : UInt64 = if double_precision {
    d.reinterpret_as_uint64()
  } else {
    let bits : UInt32 = d.to_float().reinterpret_as_uint()
    bits.to_uint64()
  }
  for i = 0; i < want; i = i + 1 {
    let shift = (want - 1 - i) * 8
    let byte_val = ((raw >> shift) & 0xFFUL).to_int()
    w.set(offset + i, byte_val)
  }
  Ok(())
}

///|
/// 10 的 scale 次幂（把 Decimal 语义值换算成 Double 用）
fn pow10(scale : Int32) -> Double {
  let mut r : Double = 1.0
  for i = 0; i < scale; i = i + 1 {
    r = r * 10.0
  }
  r
}

///|
/// 编码一条记录。
///
/// 缺失的字段按 `Null` 处理：
///   - 文本 → 全 0x40
///   - 数值 → 0（符号正）
///
/// 这是 COBOL 的实际语义（未赋值的工作存储区就是零/空格），也是从 JSONL
/// 只给部分字段时能跑通的前提。**但尺寸超限一律报错**，绝不截断。
///
/// 输出字节数恒等于 `layout.byte_length`。
pub fn encode_record(
  layout : RecordLayout,
  values : Map[String, CellValue],
) -> Result[Bytes, DecodeError] {
  let w = Writer::new(layout.byte_length)
  for field in layout.fields {
    // OCCURS n>1：按元素逐个写回，键为 `PATH(i)`（1 起始），与 decode 的
    // 展开规则互为镜像。某个元素在 map 里缺失时按「未赋值存储」处理
    // （数值 0 / 字符空格），与单字段路径的 Null 语义一致 —— 这是 JSONL
    // 只给部分字段时能跑通的前提，但**给出的值超长仍然报错**。
    if field.occurs > 1 {
      let mut k = 1
      while k <= field.occurs {
        let elem : FieldLayout = {
          ..field,
          offset: field.offset + (k - 1) * field.byte_length,
        }
        let key = "\{field.path}(\{k})"
        let scoped : Map[String, CellValue] = Map([])
        match values.get(key) {
          Some(v) => scoped[key] = v
          None => ()
        }
        // 未给下标键但给了裸名/主路径：只有第 1 个元素用它（宽容手写 JSON）
        if k == 1 {
          match values.get(field.path) {
            Some(v) => scoped[field.path] = v
            None => ()
          }
          match values.get(field.name) {
            Some(v) => scoped[field.name] = v
            None => ()
          }
        }
        let r = encode_field(w, elem, scoped)
        match r {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        k = k + 1
      }
      continue
    }
    // REDEFINES 语义修正（C2）：重定义视图只是**同一段字节的另一种读法**。
    // 若调用方没有为重定义视图提供值（decode 宽容路径把它解成 Null），
    // 编码端**绝不能写默认值** —— 那会把主视图已写好的字节覆盖成
    // 0x40/0x00（真实踩过：redefines.cpy 的合法记录被写成 6 个 0x40）。
    // 主视图必须先写：fields 按 offset 排序、主视图在前，所以这里只需
    // 跳过「没有显式值」的重定义视图。
    if field.redefine_group != 0 {
      let has_value = match values.get(field.path) {
        Some(Null) => false
        Some(_) => true
        None =>
          match values.get(field.name) {
            Some(Null) => false
            Some(_) => true
            None => false
          }
      }
      if !has_value {
        continue
      }
    }
    let r = encode_field(w, field, values)
    match r {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(w.to_bytes())
}

///|
/// 批量编码：按 `layout` 依次编码每一行，直接拼接。
pub fn encode_records(
  layout : RecordLayout,
  rows : Array[Map[String, CellValue]],
) -> Result[Bytes, DecodeError] {
  let out : Array[Byte] = []
  for row in rows {
    let r = encode_record(layout, row)
    match r {
      Ok(bytes) =>
        for i = 0; i < bytes.length(); i = i + 1 {
          out.push(bytes[i])
        }
      Err(e) => return Err(e)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
/// 往返自检：`decode → encode`，逐字节比对。
///
/// 返回 `None` 表示完全一致；`Some(offset)` 是**第一个不同字节的偏移**。
///
/// 这是 `copybook verify` 的核心：它比"值相等"严格得多 —— 值相等但
/// 字节不同意味着编码器写出了另一种合法形态（例如把 0xC 正号写成 0xF），
/// 对下游做二进制比对或重发报文时会出问题。
///
/// **REDEFINES 视图的处理**：自检比对的是「主视图读回、重定义视图原样
/// 保留」后的再编码。重定义视图与主视图共享字节，但两种解释未必都能
/// 通过各自的严格校验（`redefines.cpy` 里 `RAW-BYTE X(6)` 的字节是
/// packed 数字，按文本读永远不是可打印 EBCDIC）——这不是数据错，是
/// "同一字节的另一种读法"本身不成立。因此：
///   - 主视图解码失败 → 报错（数据真坏了）
///   - 重定义视图解码失败 → 从 map 里删掉该键再编码，**主视图的值
///     仍逐字节写回原位**
///   - 比对时跳过「本记录中只有重定义视图覆盖」的字节没有意义——
///     主视图覆盖了全部字节，逐字节比对照常进行
pub fn roundtrip_check(
  layout : RecordLayout,
  record : BytesView,
) -> Result[Int32?, DecodeError] {
  // 宽容版解码：主视图失败照样报错，重定义视图失败置 Null
  let values = match decode_record(layout, record) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // encode_record 对 Null 的重定义视图不再写默认值（C2），主视图字节
  // 会被原样写回 —— 无需手工删除键。
  let reencoded = match encode_record(layout, values) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let n = record.length()
  for i = 0; i < n && i < reencoded.length(); i = i + 1 {
    if record[i].to_int() != reencoded[i].to_int() {
      return Ok(Some(i))
    }
  }
  if reencoded.length() != n {
    // 两分支原写成相同表达式（审查发现的死分支）：无论谁长，第一个
    // 不一致的位置都是 n（两者公共前缀已逐字节比对过且无差异）。
    return Ok(Some(n))
  }
  Ok(None)
}
