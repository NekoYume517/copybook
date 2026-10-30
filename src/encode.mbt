// 记录编码 —— 类型化值 → EBCDIC 字节
//
// ## 目标：decode 的严格逆运算
//
// 验收标准是 `decode → encode` **逐字节还原**。这意味着编码不能"按最自然的
// 方式写"，而必须精确复现解码所接受的每一种字节形态。下面几处是必须刻意对齐的：
//
// 1. **zoned 数字的区号**：仅符号位置接受 0xF（正）、0xC（正）、0xD（负）。
//    其余数字字节必须是 0xF。编码保留解码得到的 sign_nibble，
//    所以 0xC 与 0xF 的正号也能逐字节往返。
//
// 2. **packed 的填位**：total_digits 为偶数时最左半字节填充 0。
//    解码拒绝非零填充，编码固定写 0。
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
  // zoned 的正号半字节也有两种合法写法：0xC（最常见）与 0xF（未符号化）。
  // decode 记下实际读到的那个，encode 原样写回，保证 `F1 F2 F3` 与 `C1 F2 F3`
  // 各自往返后字节不变。调用方新建的值（sign_nibble = None）用默认 0xF/C。
  let sign_nibble = match d.sign_nibble {
    Some(nib) =>
      if (nib == 0xC || nib == 0xF) && !d.negative {
        nib
      } else if nib == 0xD && d.negative {
        0xD
      } else if d.negative {
        0xD
      } else {
        0xF
      }
    None => if d.negative { 0xD } else { 0xF }
  }
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
///   1234 → `01 23 4C`（最左半字节填充 0）
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
  //
  // **字节保真**：若这个值是从字节解码来的，`sign_nibble` 带着原始半字节
  // （0xC 或 0xF 都可能是正号），优先原样写回。否则 `01 23 4F` 会被改写成
  // `01 23 4C` —— 数值相同但字节不同，往返就不再逐字节一致。
  let default_sign = if pic.signed {
    if d.negative {
      0xD
    } else {
      0xC
    }
  } else {
    0xF
  }
  let sign_nibble = match d.sign_nibble {
    // 原始符号半字节只在"符号语义一致"时沿用：解码得到的 negative
    // 与当前值一致才安全（值被调用方改过符号时用默认写法）。
    // 注意：**不因为字段无符号就把 0xC 改写成 0xF** —— decode 读到的
    // 就是记录里的真实字节，保真的定义是"原样写回"，不是"改成我喜欢的写法"。
    // 默认写法（无原始信息时）才区分有符号 / 无符号。
    Some(nib) => {
      let nib_is_neg = nib == 0xD
      if nib_is_neg == d.negative && (nib == 0xC || nib == 0xD || nib == 0xF) {
        nib
      } else {
        default_sign
      }
    }
    None => default_sign
  }
  // IBM packed decimal is right-aligned: optional leading zero, digits, sign.
  match d.pad_nibble {
    Some(n) =>
      if n != 0 {
        return Err(
          InvalidNumeric(offset, "packed leading pad nibble must be zero"),
        )
      }
    None => ()
  }
  let has_pad = width % 2 == 0
  for i = 0; i < bytes_needed; i = i + 1 {
    let hi_index = i * 2 - (if has_pad { 1 } else { 0 })
    let hi = if hi_index < 0 {
      0
    } else {
      padded[hi_index].to_int() - '0'.to_int()
    }
    let lo_index = hi_index + 1
    let lo = if i == bytes_needed - 1 {
      sign_nibble
    } else {
      padded[lo_index].to_int() - '0'.to_int()
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
  let width = comp_byte_width(total)
  if width == 0 {
    return Err(
      InvalidNumeric(offset, "COMP supports at most 18 digits, got \{total}"),
    )
  }
  // 容量检查：n 字节有符号能表示 -2^(8n-1) .. 2^(8n-1)-1。
  // **十进制位数也必须校验**（C8）：`PIC S9(2) COMP` 占 2 字节，二进制
  // 容量 -32768..32767 足够装 100，但 COBOL 的字段语义是「最多 2 位十进制数」
  // —— 写 100 会静默改变字段的数值含义（MOVE 99 与 MOVE 100 走不同的
  // 显示路径）。zoned/packed 都按位数拒绝，COMP 不能例外。
  let bits = width * 8
  let limit : Int64 = if width < 8 { 1L << (bits - 1) } else { 0L }
  let coef = d.coefficient
  // comp_byte_width 已验证 total 在 1..18 内，10^18 仍可由 Int64 精确表示。
  // 十进制容量独立于二进制容器宽度：8 字节能容纳 19 位，不代表 PIC 允许。
  let mut dec_limit : Int64 = 1L
  for i = 0; i < total; i = i + 1 {
    dec_limit = dec_limit * 10L
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
    if width < 8 && d.negative && coef > limit {
      return Err(
        InvalidNumeric(
          offset,
          "value \{coef} overflows signed \{width}-byte COMP",
        ),
      )
    }
    if width < 8 && !d.negative && coef >= limit {
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
    let ulimit : Int64 = if width < 8 { 1L << bits } else { 0L }
    if width < 8 && coef >= ulimit {
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
    Ok(Decimal::{
      coefficient: coef,
      scale: expected,
      negative: d.negative,
      sign_nibble: d.sign_nibble,
      pad_nibble: d.pad_nibble,
    })
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
    Ok(Decimal::{
      coefficient: coef,
      scale: expected,
      negative: d.negative,
      sign_nibble: d.sign_nibble,
      pad_nibble: d.pad_nibble,
    })
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
      let digit = (c.to_int() - '0'.to_int()).to_int64()
      // Check before multiplication: a wrapped coefficient may fit a small PIC.
      if coef > (9223372036854775807L - digit) / 10L {
        return None
      }
      coef = coef * 10L + digit
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
    FloatRaw(f, _) => f.to_string()
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
  float_mode : FloatMode,
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
  // 重定义视图只是同一段字节的另一种读法。缺值/Null 必须保留主视图字节，
  // 不能写零或空格；在单字段入口统一处理，也覆盖手工 OCCURS 的逐元素编码。
  // 判定用 is_redefining（自身声明了 REDEFINES）：目标字段虽然与视图共享
  // 非零 redefine_group，但它是字节的原主，缺值时必须写默认值（P1-1）。
  if field.is_redefining && v is Null {
    return Ok(())
  }
  match pic.category {
    National => {
      // NATIONAL is UTF-16BE; PIC N counts UTF-16 code units, not scalar values.
      let text = as_text(v)
      if text.length() > pic.digits {
        return Err(
          InvalidNumeric(offset, "text exceeds NATIONAL code-unit capacity"),
        )
      }
      let mut i = 0
      while i < text.length() {
        let unit = text[i].to_int()
        if unit >= 0xD800 && unit <= 0xDBFF {
          if i + 1 >= text.length() {
            return Err(
              InvalidNumeric(offset + i * 2, "unpaired UTF-16 high surrogate"),
            )
          }
          let low = text[i + 1].to_int()
          if low < 0xDC00 || low > 0xDFFF {
            return Err(
              InvalidNumeric(offset + i * 2, "invalid UTF-16 surrogate pair"),
            )
          }
          i = i + 2
        } else if unit >= 0xDC00 && unit <= 0xDFFF {
          return Err(
            InvalidNumeric(offset + i * 2, "unpaired UTF-16 low surrogate"),
          )
        } else {
          i = i + 1
        }
      }
      for i = 0; i < pic.digits; i = i + 1 {
        let unit = if i < text.length() { text[i].to_int() } else { 0x20 }
        w.set(offset + i * 2, unit >> 8)
        w.set(offset + i * 2 + 1, unit & 0xFF)
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
        Comp1 => encode_float_bytes(w, offset, length, v, false, float_mode)
        Comp2 => encode_float_bytes(w, offset, length, v, true, float_mode)
      }
  }
}

///|
/// 编码 COMP-1 / COMP-2。
///
/// `mode` 决定字节解释方式（与 `decode_float_bytes` 严格对称）：
///   - `Hfp`：IBM 主机十六进制浮点
///   - `Ieee754`：IEEE 754 binary32 / binary64
///
/// 接受 `Float` 直接写入，也接受数值文本（便于从 JSONL 往返）。
/// `width` 是布局层算出的字段字节数，用于越界防御。
///
/// HFP 没有 NaN / ±Infinity：这些值会返回显式错误，而不是写出一串
/// 主机读不懂的字节（「绝不静默修正」）。
fn encode_float_bytes(
  w : Writer,
  offset : Int32,
  width : Int32,
  v : CellValue,
  double_precision : Bool,
  mode : FloatMode,
) -> Result[Unit, DecodeError] {
  let want = if double_precision { 8 } else { 4 }
  if width != want {
    return Err(
      InvalidNumeric(offset, "float field must be \{want} bytes, got \{width}"),
    )
  }
  // **原字节优先**（CB-21）：decode 在 HFP `COMP-2` 尾数超出 `Double`
  // 精度时挂了原始字节。这里直接写回，往返才是字节恒等的——否则
  // `41 80 00 00 00 00 00 01` 会被舍入后重写成 `...00`。
  // 只在 HFP 下认这个旁路：`FloatRaw` 只能由 HFP 解码产生，换成 IEEE
  // 解释时原始字节不再是同一语义，必须按数值重新编码。
  match v {
    FloatRaw(_, raw) if mode == Hfp && raw.length() == want => {
      for i = 0; i < want; i = i + 1 {
        w.set(offset + i, raw[i].to_int())
      }
      return Ok(())
    }
    _ => ()
  }
  let d : Double = match v {
    Float(f) => f
    FloatRaw(f, _) => f
    Int(i) => i.to_double()
    Decimal(dd) => {
      // The coefficient is a magnitude; negative is the authoritative sign.
      // Negating zero explicitly retains its floating-point sign bit.
      let magnitude = dd.coefficient.to_double().abs() / pow10(dd.scale)
      if dd.negative {
        -magnitude
      } else {
        magnitude
      }
    }
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
  match mode {
    Hfp => {
      let bytes = if double_precision {
        hfp_encode_long(d, offset)
      } else {
        hfp_encode_short(d, offset)
      }
      match bytes {
        Ok(bs) => {
          for i, b in bs {
            w.set(offset + i, b)
          }
          Ok(())
        }
        Err(e) => Err(e)
      }
    }
    Ieee754 => {
      let raw : UInt64 = if double_precision {
        d.reinterpret_as_uint64()
      } else {
        let bits : UInt32 = Float::from_double(d).reinterpret_as_uint()
        bits.to_uint64()
      }
      for i = 0; i < want; i = i + 1 {
        let shift = (want - 1 - i) * 8
        let byte_val = ((raw >> shift) & 0xFFUL).to_int()
        w.set(offset + i, byte_val)
      }
      Ok(())
    }
  }
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
/// 是否主视图字段：自身未声明 REDEFINES。目标字段虽然也拿到非零
/// `redefine_group`（与视图共享 id），但它是字节的原主，仍是主视图。
fn field_is_primary(field : FieldLayout) -> Bool {
  !field.is_redefining
}

///|
/// 主视图字段覆盖区间的上界（最后一个主视图字段的结束偏移）。
///
/// 这是「中部空洞」与「尾部空洞」的分界线：`[0, primary_end)` 里未被主视图
/// 覆盖的字节是中部空洞，`[primary_end, byte_length)` 是尾部空洞。两个集合
/// 必须**互不重叠**——否则同一段字节会被两条旁路各回填一次（CB-15）。
fn primary_end_offset(layout : RecordLayout) -> Int32 {
  let mut end = 0
  for field in layout.fields {
    if field_is_primary(field) {
      let e = field.offset + field.total_length
      if e > end {
        end = e
      }
    }
  }
  end
}

///|
/// 该字段在这次编码中**是否真的会写入字节**（CB-16）。
///
/// 主视图字段总是写（缺值时写默认值 0 / 空格）；重定义视图只有在 `values`
/// 里给了**非 Null** 的值时才写 —— `encode_field` 对
/// `is_redefining && v is Null` 直接 `return Ok(())`，什么都不写。
///
/// 空洞判定必须用这个函数，而不能只看「有没有字段覆盖这段字节」：
/// 「名义覆盖、实际不写」的视图若算作已覆盖，它独占的那段字节既不进空洞
/// （不发旁路键）、也不会被任何字段写入，静默变成 Writer 初始的 `0x40`；
/// 反之若把「确实会写」的视图算作空洞，回填的原始字节会覆盖它刚写好的值，
/// `decode → 编辑视图 → encode` 的编辑被静默丢弃。
///
/// `values == None` 表示「还不知道视图会不会解出」：按最宽口径假设**不写**，
/// 这样算出的空洞是超集，供 decode 决定是否附带原始字节（多附加无害）。
fn field_will_write(
  field : FieldLayout,
  values : Map[String, CellValue]?,
) -> Bool {
  if !field.is_redefining {
    return true
  }
  let v = match values {
    None => return false
    Some(m) =>
      match m.get(field.path) {
        Some(x) => x
        None =>
          match m.get(field.name) {
            Some(x) => x
            None => return false
          }
      }
  }
  match v {
    Null => false
    _ => true
  }
}

///|
/// 收集「会真正写入」的字段区间，按起点升序。
fn written_intervals(
  layout : RecordLayout,
  values : Map[String, CellValue]?,
) -> Array[(Int32, Int32)] {
  let ivs : Array[(Int32, Int32)] = []
  for f in layout.fields {
    if field_will_write(f, values) {
      ivs.push((f.offset, f.offset + f.total_length))
    }
  }
  ivs.sort_by(fn(x, y) { x.0 - y.0 })
  ivs
}

///|
/// 在 `[from, to)` 中求未被 `ivs` 覆盖的区间（即空洞）。
///
/// `ivs` 必须按起点升序；区间可以互相重叠或包含，合并时取最大右端。
fn complement_gaps(
  ivs : Array[(Int32, Int32)],
  from : Int32,
  to : Int32,
) -> Array[(Int32, Int32)] {
  let gaps : Array[(Int32, Int32)] = []
  let mut cur = from
  for (s, e) in ivs {
    let s0 = if s < from { from } else { s }
    let e0 = if e > to { to } else { e }
    // 与 [from,to) 无交集
    if e0 <= from || s0 >= to {
      continue
    }
    if s0 > cur {
      gaps.push((cur, s0))
    }
    if e0 > cur {
      cur = e0
    }
  }
  if cur < to {
    gaps.push((cur, to))
  }
  gaps
}

///|
/// 计算布局的「尾部空洞」：`[主视图结束偏移, byte_length)` 中**没有字段
/// 写入**的字节 —— 典型形态是重定义视图比主视图长、且该视图解不出。
///
/// 与 `layout_tail_gap_bytes`（output 层）同一套区间逻辑。
fn primary_tail_gaps(
  layout : RecordLayout,
  values : Map[String, CellValue]?,
) -> Array[(Int32, Int32)] {
  let mut primary_end = 0
  let mut has_primary = false
  for field in layout.fields {
    if field_is_primary(field) {
      let e = field.offset + field.total_length
      if !has_primary || e > primary_end {
        primary_end = e
      }
      has_primary = true
    }
  }
  if !has_primary || primary_end >= layout.byte_length {
    return []
  }
  complement_gaps(
    written_intervals(layout, values),
    primary_end,
    layout.byte_length,
  )
}

///|
/// 计算布局的「中部空洞」：`[0, 主视图结束偏移)` 中**没有字段写入**的字节
/// —— 典型形态是 `01 R. 05 A PIC X(2). 05 FILLER PIC X(2). 05 B PIC X(2).`
/// 里 FILLER 占据的 2..4。FILLER 不进 layout.fields（布局层契约），这段
/// 字节在 decode 结果里没有任何字段承载，encode 只能落 Writer 初始的 0x40，
/// 原始字节被静默替换（P1-2）。
///
/// 三条约束（每条都对应一次实测缺陷）：
///
/// 1. **值为 Null 的视图不算「覆盖」**（CB-16，见 `field_will_write`）。
///    它什么都不写，若算作覆盖，视图独占的那段字节既不发旁路键、也不回填，
///    静默变成 `0x40`，而 verify 报 byte mismatch —— 两条路径结论矛盾。
/// 2. **值为非 Null 的视图必须算「覆盖」**，否则回填会把视图刚写好的值
///    覆盖回原始字节，`decode → 编辑视图 → encode` 的编辑被静默丢弃。
/// 3. **上界是主视图结束偏移，不是 `byte_length`**（CB-15）。超出主视图的
///    部分属于尾部空洞，两条旁路各自按顺序游标取字节，重叠会让同一段字节
///    被消费两次。
fn filler_gaps(
  layout : RecordLayout,
  values : Map[String, CellValue]?,
) -> Array[(Int32, Int32)] {
  complement_gaps(
    written_intervals(layout, values),
    0,
    primary_end_offset(layout),
  )
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
    // compile_layout 已展开 OCCURS；此分支兼容公开结构体手工构造的未展开布局。
    // OCCURS n>1：按元素逐个写回，键为 `PATH(i)`（1 起始），与 decode 的
    // 展开规则互为镜像。某个元素在 map 里缺失时按「未赋值存储」处理
    // （数值 0 / 字符空格），与单字段路径的 Null 语义一致 —— 这是 JSONL
    // 只给部分字段时能跑通的前提，但**给出的值超长仍然报错**。
    if field.occurs > 1 {
      let mut k = 1
      while k <= field.occurs {
        let key = "\{field.path}(\{k})"
        let elem : FieldLayout = {
          ..field,
          path: key,
          offset: field.offset + (k - 1) * field.byte_length,
        }
        let scoped : Map[String, CellValue] = Map([])
        match values.get(key) {
          Some(v) => scoped[key] = v
          // 未给下标键但给了裸名/主路径：只有第 1 个元素用它（宽容手写 JSON）
          None =>
            if k == 1 {
              match values.get(field.path) {
                Some(v) => scoped[key] = v
                None =>
                  match values.get(field.name) {
                    Some(v) => scoped[key] = v
                    None => ()
                  }
              }
            }
        }
        let r = encode_field(w, elem, scoped, layout.float_mode)
        match r {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        k = k + 1
      }
      continue
    }
    let r = encode_field(w, field, values, layout.float_mode)
    match r {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  // 空洞回填：原始字节由旁路键承载，字段全部写完后按空洞区间原样写回。
  //   - 尾部空洞（CB-9，只有重定义视图覆盖的区间）：`__tail_hex`
  //     （JSONL 路径，render_jsonl 带出、parse_jsonl_row 还原）或
  //     `__record_bytes`（内存路径，宽容解码附带）。`12 3C FF EE`
  //     不再被静默改写成 `12 3C 40 40`。
  //   - 中部空洞（P1-2，FILLER 区 / 叶子字段之间的裂缝）：`__filler_hex`
  //     （JSONL 路径）或同一份 `__record_bytes`（内存路径）。FILLER 区的
  //     `C1 C2 C3 C4 C5 C6` 不再变 `C1 C2 40 40 C5 C6`。
  //
  // **每个旁路键各用自己的游标、只回填自己那个集合**（CB-15）：
  // __tail_hex 只含尾部区间的字节，__filler_hex 只含中部区间的字节，两者
  // 内容不同。旧实现把两段字节塞进一个 `tail` 变量、两轮循环共用一个
  // 递增的 `idx`，于是先处理的区间吃掉第二段的字节、第二段从越界处取到
  // 空值 —— 合并了「中部 FILLER + REDEFINES 尾部」的布局因此静默损坏。
  // 内存路径的 `__record_bytes` 是整条记录，按绝对偏移回填。
  let restore = fn(
    gaps : Array[(Int32, Int32)],
    bs : Bytes,
    absolute : Bool,
  ) -> Unit {
    let mut idx = 0
    for (s, e) in gaps {
      let mut i = s
      while i < e {
        let src = if absolute { i } else { idx }
        if src < bs.length() {
          w.set(i, bs[src].to_int())
        }
        idx = idx + 1
        i = i + 1
      }
    }
  }
  match values.get("__record_bytes") {
    Some(Bytes(bs)) => {
      // 内存路径：整条记录，两个集合都按绝对偏移取。
      restore(primary_tail_gaps(layout, Some(values)), bs, true)
      restore(filler_gaps(layout, Some(values)), bs, true)
    }
    _ => {
      // JSONL 路径：各键独立回填（缺哪个就跳过哪个）。
      match values.get("__tail_hex") {
        Some(Bytes(bs)) =>
          restore(primary_tail_gaps(layout, Some(values)), bs, false)
        _ => ()
      }
      match values.get("__filler_hex") {
        Some(Bytes(bs)) => restore(filler_gaps(layout, Some(values)), bs, false)
        _ => ()
      }
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
    // **区分失败来源**（CB-19）：decode 已经成功，这里失败说明「数值解出来
    // 之后无法再用声明的格式写回」（例如 HFP 的 56 位尾数超出 double 精度
    // 区间、或解出的值超过 HFP 上界）。若与 decode 失败共用同一个通道，
    // CLI 会把编码失败说成 "decode failed"，把归因指错方向。
    Err(e) => return Err(EncodeFailed(e.to_display()))
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
