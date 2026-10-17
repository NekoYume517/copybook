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
fn decimal_digits(d : Decimal) -> String {
  d.coefficient.abs().to_string()
}

///|
/// 计算字段需要写的**总位数**（整数位 + 小数位）。
fn field_total_digits(pic : PicClause) -> Int32 {
  pic.digits + pic.scale
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
  let width = field_total_digits(pic)
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
  let width = field_total_digits(pic)
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
  // 无符号字段的 -0：packed 虽有独立符号半字节，但无符号字段解出负号会
  // 被 decode 拒绝（"unsigned packed decimal has negative sign"），编码
  // 出一条自己都解不回的记录是自相矛盾的输出 —— 统一按正号写 0xC。
  let sign_nibble = if d.negative && pic.signed { 0xD } else { 0xC }
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
  let total = field_total_digits(pic)
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
      InvalidNumeric(
        offset,
        "COMP supports at most 18 digits, got \{field_total_digits(pic)}",
      ),
    )
  }
  // 容量检查：n 字节有符号能表示 -2^(8n-1) .. 2^(8n-1)-1
  let bits = width * 8
  let limit : Int64 = 1L << (bits - 1)
  let coef = d.coefficient
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
      align_scale(Decimal::from_parts(i, 0, i < 0L), expected_scale, offset)
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
        w.set(offset + i * 2 + 1, 0x00)
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
      try {
        @string.parse_double(s)
      } catch {
        _ =>
          return Err(
            InvalidNumeric(offset, "cannot parse '\{s}' as a float"),
          )
      } noraise {
        x => x
      }
    Null => 0.0
    _ =>
      return Err(
        InvalidNumeric(offset, "expected a numeric value, got a non-numeric cell"),
      )
  }
  let raw : UInt64 = if double_precision {
    d.reinterpret_as_uint64()
  } else {
    let bits : UInt = d.to_float().reinterpret_as_uint()
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
pub fn roundtrip_check(
  layout : RecordLayout,
  record : BytesView,
) -> Result[Int32?, DecodeError] {
  // 用严格版解码：自检要保证每个视图都自洽
  let values = match decode_record_strict(layout, record) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
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
    return Ok(Some(if n < reencoded.length() { n } else { n }))
  }
  Ok(None)
}
