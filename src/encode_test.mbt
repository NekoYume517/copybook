// encode 单元测试 + 往返属性测试（500 条随机记录，固定种子 LCG）

///|
/// 确定性伪随机数发生器（线性同余）。固定种子 → 可复现。
///
/// 用 LCG 而不是 `@random`：测试必须**逐位可复现**，否则失败时无法重放。
priv struct Lcg {
  mut state : UInt64
}

///|
fn Lcg::new(seed : UInt64) -> Lcg {
  { state: seed, }
}

///|
/// Numerical Recipes 的 LCG 常数（周期 2^64）
fn Lcg::next(self : Lcg) -> UInt64 {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  self.state
}

///|
fn Lcg::below(self : Lcg, n : Int32) -> Int32 {
  let v = self.next()
  (v % n.to_uint64()).to_int()
}

///|
/// 字节数组 helper
fn bsv(values : Array[Int32]) -> Bytes {
  let arr : Array[Byte] = []
  for v in values {
    arr.push(v.to_byte())
  }
  Bytes::from_array(arr)
}

///|
/// 构造单字段 layout 的 helper（与 decode_test 里同名函数会冲突，故加 e_ 前缀）
fn e_one(
  category : PicCategory,
  digits : Int32,
  scale : Int32,
  signed : Bool,
  usage : Usage,
  sign_separate : Bool,
) -> RecordLayout raise ParseError {
  let pic : PicClause = {
    category,
    digits,
    scale,
    storage_digits: digits + scale,
    signed,
    usage,
    sign_separate,
    sign_leading: false,
    pic_text: "",
  }
  let spec : FieldSpec = {
    level: 5,
    name: "V",
    pic: Some(pic),
    redefines: None,
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children: [],
    line: 1,
    group_usage: None,
  }
  let root : FieldSpec = {
    level: 1,
    name: "R",
    pic: None,
    redefines: None,
    occurs: 1,
    occurs_min: 1,
    occurs_depending_on: None,
    value_literal: None,
    children: [spec],
    line: 1,
    group_usage: None,
  }
  compile_layout([root])
}

///|
fn e_num(
  digits : Int32,
  scale : Int32,
  signed : Bool,
  usage : Usage,
) -> RecordLayout raise ParseError {
  e_one(Numeric, digits, scale, signed, usage, false)
}

///|
fn e_text(n : Int32) -> RecordLayout raise ParseError {
  e_one(Alphanumeric, n, 0, false, Display, false)
}

///|
/// 编码后与期望字节比对
fn expect_bytes(
  layout : RecordLayout,
  value : CellValue,
  expected : Array[Int32],
) -> Unit {
  let m : Map[String, CellValue] = Map([])
  m["V"] = value
  let actual = match encode_record(layout, m) {
    Ok(v) => v
    Err(e) => abort("encode failed: " + e.to_display())
  }
  if actual.length() != expected.length() {
    abort("length mismatch: got \{actual.length()}, want \{expected.length()}")
  }
  for i = 0; i < expected.length(); i = i + 1 {
    if actual[i].to_int() != expected[i] {
      abort(
        "byte \{i} mismatch: got 0x\{actual[i].to_int().to_string(radix=16)}, want 0x\{expected[i].to_string(radix=16)}",
      )
    }
  }
}

///|
test "encode zoned 正数 123 → F1 F2 F3" {
  let layout = e_num(3, 0, true, Display)
  expect_bytes(layout, Decimal(Decimal::from_parts(123L, 0, false)), [
    0xF1, 0xF2, 0xF3,
  ])
}

///|
test "encode zoned 负数 -123 → F1 F2 D3" {
  let layout = e_num(3, 0, true, Display)
  expect_bytes(layout, Decimal(Decimal::from_parts(123L, 0, true)), [
    0xF1, 0xF2, 0xD3,
  ])
}

///|
test "encode zoned 左补 0" {
  let layout = e_num(5, 0, true, Display)
  expect_bytes(layout, Decimal(Decimal::from_parts(42L, 0, false)), [
    0xF0, 0xF0, 0xF0, 0xF4, 0xF2,
  ])
}

///|
test "encode zoned 带小数 S9(3)V99 123.45" {
  let layout = e_num(3, 2, true, Display)
  expect_bytes(layout, Decimal(Decimal::from_parts(12345L, 2, false)), [
    0xF1, 0xF2, 0xF3, 0xF4, 0xF5,
  ])
}

///|
test "encode packed 123 → 12 3C" {
  let layout = e_num(3, 0, true, Comp3)
  expect_bytes(layout, Decimal(Decimal::from_parts(123L, 0, false)), [
    0x12, 0x3C,
  ])
}

///|
test "encode packed -123 → 12 3D" {
  let layout = e_num(3, 0, true, Comp3)
  expect_bytes(layout, Decimal(Decimal::from_parts(123L, 0, true)), [0x12, 0x3D])
}

///|
test "encode packed 偶数位填充 0" {
  // 4 位 + 符号 = 5 半字节 → 3 字节，末字节高半字节 0
  let layout = e_num(4, 0, true, Comp3)
  expect_bytes(layout, Decimal(Decimal::from_parts(1234L, 0, false)), [
    0x12, 0x34, 0x0C,
  ])
}

///|
test "encode packed S9(7)V99 → 5 字节" {
  let layout = e_num(7, 2, true, Comp3)
  inspect(layout.byte_length, content="5")
  expect_bytes(layout, Decimal(Decimal::from_parts(123456789L, 2, true)), [
    0x12, 0x34, 0x56, 0x78, 0x9D,
  ])
}

///|
test "encode COMP 2 字节" {
  let layout = e_num(3, 0, false, Comp)
  expect_bytes(layout, Decimal(Decimal::from_parts(123L, 0, false)), [
    0x00, 0x7B,
  ])
}

///|
test "encode COMP 4 字节正数" {
  let layout = e_num(5, 0, true, Comp)
  expect_bytes(layout, Decimal(Decimal::from_parts(1234L, 0, false)), [
    0x00, 0x00, 0x04, 0xD2,
  ])
}

///|
test "encode COMP 4 字节负数补码" {
  let layout = e_num(5, 0, true, Comp)
  expect_bytes(layout, Decimal(Decimal::from_parts(1234L, 0, true)), [
    0xFF, 0xFF, 0xFB, 0x2E,
  ])
}

///|
test "encode COMP 8 字节负数 -1234567" {
  let layout = e_num(8, 2, true, Comp)
  inspect(layout.byte_length, content="8")
  expect_bytes(layout, Decimal(Decimal::from_parts(1234567L, 2, true)), [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xED, 0x29, 0x79,
  ])
}

///|
test "encode 文本补 0x40" {
  expect_bytes(e_text(6), Text("HI"), [0xC8, 0xC9, 0x40, 0x40, 0x40, 0x40])
}

///|
test "encode 文本全空格" {
  expect_bytes(e_text(3), Text(""), [0x40, 0x40, 0x40])
}

///|
test "encode 文本超长报错不截断" {
  let layout = e_text(3)
  let m : Map[String, CellValue] = Map([])
  m["V"] = Text("TOOLONG")
  match encode_record(layout, m) {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(_, detail)) => assert_true(detail.contains("exceeds"))
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "encode 数值溢出报错不截断" {
  let layout = e_num(3, 0, false, Display)
  let m : Map[String, CellValue] = Map([])
  m["V"] = Decimal(Decimal::from_parts(1234L, 0, false))
  match encode_record(layout, m) {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(_, detail)) => assert_true(detail.contains("digits"))
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "encode 缺失字段按 0 与空格补齐" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(2).\n  05 B PIC 9(2).\n"),
  )
  let m : Map[String, CellValue] = Map([])
  let b = match encode_record(layout, m) {
    Ok(v) => v
    Err(e) => abort(e.to_display())
  }
  inspect(b.length(), content="4")
  inspect(b[0].to_int(), content="64")
  inspect(b[1].to_int(), content="64")
  inspect(b[2].to_int(), content="240")
  inspect(b[3].to_int(), content="240")
}

///|
test "encode 无符号字段拒绝负数" {
  let layout = e_num(3, 0, false, Display)
  let m : Map[String, CellValue] = Map([])
  m["V"] = Decimal(Decimal::from_parts(5L, 0, true))
  match encode_record(layout, m) {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(_, _)) => ()
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "encode 接受 Text 形式的数字" {
  let layout = e_num(3, 0, true, Display)
  let m : Map[String, CellValue] = Map([])
  m["V"] = Text("-123")
  let b = match encode_record(layout, m) {
    Ok(v) => v
    Err(e) => abort(e.to_display())
  }
  inspect(b[2].to_int().to_string(radix=16), content="d3")
}

///|
test "encode 接受 Int" {
  let layout = e_num(3, 0, false, Display)
  let m : Map[String, CellValue] = Map([])
  m["V"] = Int(42L)
  let b = match encode_record(layout, m) {
    Ok(v) => v
    Err(e) => abort(e.to_display())
  }
  inspect(b[2].to_int().to_string(radix=16), content="f2")
}

///|
test "encode_records 拼接多条" {
  let layout = e_num(2, 0, false, Display)
  let rows : Array[Map[String, CellValue]] = []
  for i = 0; i < 3; i = i + 1 {
    let m : Map[String, CellValue] = Map([])
    m["V"] = Int((i + 1).to_int64())
    rows.push(m)
  }
  let b = match encode_records(layout, rows) {
    Ok(v) => v
    Err(e) => abort(e.to_display())
  }
  inspect(b.length(), content="6")
}

///|
test "roundtrip: zoned 各符号形态" {
  let layout = e_num(5, 2, true, Display)
  for neg in [false, true] {
    for coef in [0L, 1L, 12L, 99999L] {
      let d = Decimal::from_parts(coef, 2, neg)
      let m : Map[String, CellValue] = Map([])
      m["V"] = Decimal(d)
      let bytes = match encode_record(layout, m) {
        Ok(v) => v
        Err(e) => abort(e.to_display())
      }
      let back = match decode_record_ordered(layout, bytes) {
        Ok(v) => v
        Err(e) => abort(e.to_display())
      }
      match back[0] {
        Decimal(d2) => {
          assert_true(d2.coefficient == coef)
          assert_true(d2.negative == neg)
          assert_true(d2.scale == 2)
        }
        _ => fail("expected Decimal")
      }
    }
  }
}

///|
test "roundtrip: packed 各符号形态" {
  let layout = e_num(7, 2, true, Comp3)
  for neg in [false, true] {
    for coef in [0L, 1L, 123456789L] {
      let d = Decimal::from_parts(coef, 2, neg)
      let m : Map[String, CellValue] = Map([])
      m["V"] = Decimal(d)
      let bytes = match encode_record(layout, m) {
        Ok(v) => v
        Err(e) => abort(e.to_display())
      }
      let back = match decode_record_ordered(layout, bytes) {
        Ok(v) => v
        Err(e) => abort(e.to_display())
      }
      match back[0] {
        Decimal(d2) => {
          assert_true(d2.coefficient == coef)
          assert_true(d2.negative == neg)
        }
        _ => fail("expected Decimal")
      }
    }
  }
}

///|
test "roundtrip: COMP 各宽度" {
  for digits in [3, 5, 9, 12, 18] {
    for signed in [true] {
      let layout = e_num(digits, 0, signed, Comp)
      let width = layout.byte_length
      // 取该宽度下安全的正负值
      let maxv : Int64 = if digits == 3 {
        999L
      } else if digits == 5 {
        99999L
      } else if digits == 9 {
        999999999L
      } else {
        999999999999L
      }
      ignore(width)
      for coef in [0L, 1L, maxv, maxv / 2L] {
        for neg in [false, true] {
          // COMP 是二进制补码，没有 -0：跳过这个组合（见 encode_binary 注释）
          if coef == 0L && neg {
            continue
          }
          let m : Map[String, CellValue] = Map([])
          m["V"] = Decimal(Decimal::from_parts(coef, 0, neg))
          let bytes = match encode_record(layout, m) {
            Ok(v) => v
            Err(e) => abort(e.to_display())
          }
          let back = match decode_record_ordered(layout, bytes) {
            Ok(v) => v
            Err(e) => abort(e.to_display())
          }
          match back[0] {
            Decimal(d2) => {
              assert_true(d2.coefficient == coef)
              assert_true(d2.negative == neg)
            }
            _ => fail("expected Decimal")
          }
        }
      }
    }
  }
}

///|
test "roundtrip: 文本" {
  let layout = e_text(10)
  for s in ["", "A", "HELLO", "ABCDEFGHIJ", " leading", "a b c  "] {
    let m : Map[String, CellValue] = Map([])
    m["V"] = Text(s)
    let bytes = match encode_record(layout, m) {
      Ok(v) => v
      Err(e) => abort(e.to_display())
    }
    let back = match decode_record_ordered(layout, bytes) {
      Ok(v) => v
      Err(e) => abort(e.to_display())
    }
    match back[0] {
      // 解码会 trim 尾部空格，所以纯尾部空格差异不算错
      Text(s2) => inspect(s2, content=s.trim_end(chars=" ").to_owned())
      _ => fail("expected Text")
    }
  }
}

///|
/// 500 条随机记录的完整往返：decode → encode → 逐字节比对
///
/// 这是项目验收的硬指标。用 customer.cpy 的完整结构（含组、多种 usage）
/// 让覆盖面尽可能广。
test "roundtrip: 500 条随机记录（customer.cpy 结构）" {
  let layout = compile_layout(
    parse_copybook(
      "01 CUSTOMER-RECORD.\n  05 CUST-ID PIC 9(8).\n  05 CUST-NAME PIC X(30).\n  05 BALANCE PIC S9(7)V99 COMP-3.\n  05 OPEN-DATE PIC 9(8).\n  05 FLAGS.\n    10 ACTIVE PIC X(1).\n    10 TIER PIC 9(2).\n",
    ),
  )
  inspect(layout.byte_length, content="54")
  let rng = Lcg::new(20260930UL)
  let mut mismatches = 0
  let mut first_bad = -1
  for iter = 0; iter < 500; iter = iter + 1 {
    // CUST-ID: 8 位数字，首位不强制非零（COBOL 数字字段可以是 0 开头）
    let cust_id = rng.below(100000000).to_int64()
    // CUST-NAME: 长度 0..30 的字母数字串
    let name_len = rng.below(31)
    let name_chars : Array[String] = []
    for i = 0; i < name_len; i = i + 1 {
      let pick = rng.below(36)
      let ch = if pick < 10 {
        ('0'.to_int() + pick).unsafe_to_char().to_string()
      } else {
        ('A'.to_int() + pick - 10).unsafe_to_char().to_string()
      }
      name_chars.push(ch)
    }
    let name = name_chars.join("")
    // BALANCE: 9 位整数 coefficient (0..999999999), scale 2
    let bal_coef = rng.next() % 1000000000UL
    let bal_neg = rng.below(2) == 1
    // OPEN-DATE: 8 位
    let open_date = rng.below(100000000).to_int64()
    // ACTIVE: 单字母
    let active = ('A'.to_int() + rng.below(26)).unsafe_to_char().to_string()
    // TIER: 0..99
    let tier = rng.below(100).to_int64()
    // 只保留编码器能表示的字符（避免 EBCDIC 不可编码）
    let name_safe = name
    let values : Map[String, CellValue] = Map([])
    values["CUSTOMER-RECORD.CUST-ID"] = Int(cust_id)
    values["CUSTOMER-RECORD.CUST-NAME"] = Text(name_safe)
    values["CUSTOMER-RECORD.BALANCE"] = Decimal(
      Decimal::from_parts(bal_coef.to_int64(), 2, bal_neg),
    )
    values["CUSTOMER-RECORD.OPEN-DATE"] = Int(open_date)
    values["CUSTOMER-RECORD.FLAGS.ACTIVE"] = Text(active)
    values["CUSTOMER-RECORD.FLAGS.TIER"] = Int(tier)
    let encoded = match encode_record(layout, values) {
      Ok(b) => b
      Err(_) => {
        mismatches = mismatches + 1
        if first_bad < 0 {
          first_bad = iter
        }
        continue
      }
    }
    // 逐字节往返：decode(encoded) → encode → 必须与 encoded 完全一致
    let check = match roundtrip_check(layout, encoded) {
      Ok(v) => v
      Err(_) => {
        mismatches = mismatches + 1
        if first_bad < 0 {
          first_bad = iter
        }
        continue
      }
    }
    match check {
      None => ()
      Some(_) => {
        mismatches = mismatches + 1
        if first_bad < 0 {
          first_bad = iter
        }
      }
    }
  }
  if mismatches != 0 {
    abort(
      "roundtrip failures: \{mismatches}/500, first at iteration \{first_bad}",
    )
  }
}

///|
/// 第二个往返：order.cpy 结构（含 OCCURS 组 + COMP + COMP-3）
test "roundtrip: 300 条随机记录（order.cpy 结构）" {
  let layout = compile_layout(
    parse_copybook(
      "01 ORDER-LINES.\n  05 ORDER-ID PIC 9(10).\n  05 LINE-COUNT PIC 9(3).\n  05 LINES OCCURS 5 TIMES.\n    10 SKU PIC X(12).\n    10 QTY PIC S9(4) COMP.\n    10 PRICE PIC S9(5)V99 COMP-3.\n",
    ),
  )
  inspect(layout.byte_length, content="103")
  let rng = Lcg::new(777UL)
  let mut mismatches = 0
  for iter = 0; iter < 300; iter = iter + 1 {
    let values : Map[String, CellValue] = Map([])
    values["ORDER-LINES.ORDER-ID"] = Int(rng.below(1000000000).to_int64())
    values["ORDER-LINES.LINE-COUNT"] = Int(rng.below(1000).to_int64())
    // OCCURS 组的子项在 map 里只有一份（按第 0 次出现的偏移写）
    let sku_len = rng.below(13)
    let sku_chars : Array[String] = []
    for i = 0; i < sku_len; i = i + 1 {
      sku_chars.push(
        ('A'.to_int() + rng.below(26)).unsafe_to_char().to_string(),
      )
    }
    values["ORDER-LINES.LINES.SKU"] = Text(sku_chars.join(""))
    // QTY: S9(4) COMP → 2 字节，PIC 范围 -9999..9999
    let qty = (rng.below(19999) - 9999).to_int64()
    values["ORDER-LINES.LINES.QTY"] = Decimal(
      Decimal::from_parts(qty.abs(), 0, qty < 0L),
    )
    values["ORDER-LINES.LINES.PRICE"] = Decimal(
      Decimal::from_parts(
        (rng.next() % 10000000UL).to_int64(),
        2,
        rng.below(2) == 1,
      ),
    )
    let encoded = match encode_record(layout, values) {
      Ok(b) => b
      Err(_) => {
        mismatches = mismatches + 1
        continue
      }
    }
    match roundtrip_check(layout, encoded) {
      Ok(None) => ()
      _ => mismatches = mismatches + 1
    }
  }
  if mismatches != 0 {
    abort("order roundtrip failures: \{mismatches}/300")
  }
}

///|
test "roundtrip_check 检测出差异" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  // 手工构造一条有控制字节的记录：decode 会失败 → roundtrip_check 报错
  let bad = bsv([0x00, 0x41])
  match roundtrip_check(layout, bad) {
    Ok(_) => fail("expected error")
    Err(InvalidEbcdic(_, _)) => ()
    Err(_) => fail("expected InvalidEbcdic")
  }
}
