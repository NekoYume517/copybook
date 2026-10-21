// decode 单元测试：手工构造字节，逐条验证解码语义。

///|
/// 用字节值数组构造 Bytes（便于按 EBCDIC 十六进制写测试）
fn bs(values : Array[Int32]) -> Bytes {
  let arr : Array[Byte] = []
  for v in values {
    arr.push(v.to_byte())
  }
  Bytes::from_array(arr)
}

///|
/// 单数值字段的 layout 辅助
fn one_numeric(
  digits : Int32,
  scale : Int32,
  signed : Bool,
  usage : Usage,
) -> RecordLayout raise ParseError {
  let pic : PicClause = {
    category: Numeric,
    digits,
    scale,
    storage_digits: digits + scale,
    signed,
    usage,
    sign_separate: false,
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
fn one_text(n : Int32) -> RecordLayout raise ParseError {
  let pic : PicClause = {
    category: Alphanumeric,
    digits: n,
    scale: 0,
    storage_digits: n,
    signed: false,
    usage: Display,
    sign_separate: false,
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
/// 取唯一字段的值（失败直接 abort：测试里错误路径单独断言）
fn only(layout : RecordLayout, record : BytesView) -> CellValue {
  match decode_record_ordered(layout, record) {
    Ok(values) => values[0]
    Err(_) => abort("unexpected decode error")
  }
}

///|
test "Decimal::to_string 各种形态" {
  inspect(
    Decimal::from_parts(123456789L, 2, true).to_string(),
    content="-1234567.89",
  )
  inspect(Decimal::from_parts(5L, 3, false).to_string(), content="0.005")
  inspect(Decimal::from_parts(42L, 0, false).to_string(), content="42")
  inspect(Decimal::from_parts(120L, 2, false).to_string(), content="1.20")
  inspect(Decimal::from_parts(0L, 2, true).to_string(), content="-0.00")
  inspect(Decimal::from_parts(1L, 0, true).to_string(), content="-1")
}

///|
test "zoned 正数 123 → F1 F2 F3" {
  let layout = one_numeric(3, 0, true, Display)
  let v = only(layout, bs([0xF1, 0xF2, 0xF3]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="123")
      inspect(d.negative, content="false")
      inspect(d.to_string(), content="123")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "zoned 负数 -123 → F1 F2 D3" {
  let layout = one_numeric(3, 0, true, Display)
  let v = only(layout, bs([0xF1, 0xF2, 0xD3]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="123")
      inspect(d.negative, content="true")
      inspect(d.to_string(), content="-123")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "zoned 正号也可用 0xC 结尾" {
  let layout = one_numeric(3, 0, true, Display)
  let v = only(layout, bs([0xF1, 0xF2, 0xC3]))
  match v {
    Decimal(d) => {
      inspect(d.negative, content="false")
      inspect(d.to_string(), content="123")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "zoned 带小数位 S9(3)V99 → 12345 表示 123.45" {
  let layout = one_numeric(3, 2, true, Display)
  // 5 位数字，末字节 D5 负
  let v = only(layout, bs([0xF1, 0xF2, 0xF3, 0xF4, 0xD5]))
  match v {
    Decimal(d) => inspect(d.to_string(), content="-123.45")
    _ => fail("expected Decimal")
  }
}

///|
test "zoned 无符号字段被读成 Int" {
  let layout = one_numeric(4, 0, false, Display)
  let v = only(layout, bs([0xF0, 0xF0, 0xF4, 0xF2]))
  match v {
    Int(i) => inspect(i, content="42")
    _ => fail("expected Int")
  }
}

///|
test "zoned 非法数字半字节报错带偏移" {
  let layout = one_numeric(3, 0, true, Display)
  let r = decode_record_ordered(layout, bs([0xF1, 0xFA, 0xF3]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(offset, _)) => inspect(offset, content="1")
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "zoned 非法符号半字节报错" {
  let layout = one_numeric(3, 0, true, Display)
  let r = decode_record_ordered(layout, bs([0xF1, 0xF2, 0xA3]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(offset, _)) => inspect(offset, content="2")
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "zoned 无符号字段出现 D 符号报错" {
  let layout = one_numeric(3, 0, false, Display)
  let r = decode_record_ordered(layout, bs([0xF1, 0xF2, 0xD3]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(_, detail)) => assert_true(detail.contains("negative"))
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "packed 正数 123 → 12 3C" {
  let layout = one_numeric(3, 0, true, Comp3)
  let v = only(layout, bs([0x12, 0x3C]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="123")
      inspect(d.negative, content="false")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "packed 负数 123 → 12 3D" {
  let layout = one_numeric(3, 0, true, Comp3)
  let v = only(layout, bs([0x12, 0x3D]))
  match v {
    Decimal(d) => inspect(d.to_string(), content="-123")
    _ => fail("expected Decimal")
  }
}

///|
test "packed S9(7)V99 → 5 字节，值 -123456789" {
  let layout = one_numeric(7, 2, true, Comp3)
  // 9 位数字 1 2 3 4 5 6 7 8 9 + 符号 D → 5 字节
  let v = only(layout, bs([0x12, 0x34, 0x56, 0x78, 0x9D]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="123456789")
      inspect(d.to_string(), content="-1234567.89")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "packed 偶数位数以 0 填充高半字节" {
  // digits=4 scale=0 signed → 5 半字节 → 3 字节，末字节高半字节填充
  let layout = one_numeric(4, 0, true, Comp3)
  inspect(layout.byte_length, content="3")
  let v = only(layout, bs([0x12, 0x34, 0x0C]))
  match v {
    Decimal(d) => inspect(d.coefficient, content="1234")
    _ => fail("expected Decimal")
  }
}

///|
test "packed F 填充也接受" {
  let layout = one_numeric(4, 0, true, Comp3)
  let v = only(layout, bs([0x12, 0x34, 0xFC]))
  match v {
    Decimal(d) => inspect(d.coefficient, content="1234")
    _ => fail("expected Decimal")
  }
}

///|
test "packed 非法符号报错" {
  let layout = one_numeric(3, 0, true, Comp3)
  let r = decode_record_ordered(layout, bs([0x12, 0x3A]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(offset, _)) => inspect(offset, content="1")
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "packed 非法数字半字节报错" {
  let layout = one_numeric(3, 0, true, Comp3)
  let r = decode_record_ordered(layout, bs([0x1A, 0x3C]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(offset, _)) => inspect(offset, content="0")
    Err(_) => fail("expected InvalidNumeric")
  }
}

///|
test "COMP 2 字节无符号" {
  let layout = one_numeric(3, 0, false, Comp)
  let v = only(layout, bs([0x00, 0x7B]))
  match v {
    Decimal(d) => inspect(d.coefficient, content="123")
    _ => fail("expected Decimal")
  }
}

///|
test "COMP 4 字节大端有符号负数补码" {
  let layout = one_numeric(5, 0, true, Comp)
  // -1234 = 0xFB2E
  let v = only(layout, bs([0xFF, 0xFF, 0xFB, 0x2E]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="1234")
      inspect(d.negative, content="true")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "COMP 4 字节正数" {
  let layout = one_numeric(5, 0, true, Comp)
  let v = only(layout, bs([0x00, 0x00, 0x04, 0xD2]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="1234")
      inspect(d.negative, content="false")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "COMP 总位 9 是 4 字节" {
  let layout = one_numeric(7, 2, true, Comp)
  inspect(layout.byte_length, content="4")
}

///|
test "COMP 8 字节带小数 scale（总位 10）" {
  // S9(8)V99 → 总位 10 → 8 字节
  let layout = one_numeric(8, 2, true, Comp)
  inspect(layout.byte_length, content="8")
  // 1234567 = 0x0012D687
  let v = only(layout, bs([0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0xD6, 0x87]))
  match v {
    Decimal(d) => inspect(d.to_string(), content="12345.67")
    _ => fail("expected Decimal")
  }
}

///|
test "COMP 8 字节负数 -1234567" {
  let layout = one_numeric(8, 2, true, Comp)
  // -1234567 补码 = 0xFFED2979
  let v = only(layout, bs([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xED, 0x29, 0x79]))
  match v {
    Decimal(d) => {
      inspect(d.coefficient, content="1234567")
      inspect(d.negative, content="true")
    }
    _ => fail("expected Decimal")
  }
}

///|
test "文本字段 EBCDIC 解码 + trim_end" {
  let layout = one_text(6)
  // "HI" + 4 空格 → C8 C9 40 40 40 40
  let v = only(layout, bs([0xC8, 0xC9, 0x40, 0x40, 0x40, 0x40]))
  match v {
    Text(s) => inspect(s, content="HI")
    _ => fail("expected Text")
  }
}

///|
test "文本字段保留前导空格" {
  let layout = one_text(5)
  // " AB  " → 40 C1 C2 40 40
  let v = only(layout, bs([0x40, 0xC1, 0xC2, 0x40, 0x40]))
  match v {
    Text(s) => inspect(s, content=" AB")
    _ => fail("expected Text")
  }
}

///|
test "文本字段全空格 → 空串" {
  let layout = one_text(3)
  let v = only(layout, bs([0x40, 0x40, 0x40]))
  match v {
    Text(s) => inspect(s, content="")
    _ => fail("expected Text")
  }
}

///|
test "文本字段控制字节报 InvalidEbcdic" {
  let layout = one_text(3)
  let r = decode_record_ordered(layout, bs([0xC1, 0x00, 0xC2]))
  match r {
    Ok(_) => fail("expected error")
    Err(InvalidEbcdic(offset, byte)) => {
      inspect(offset, content="1")
      inspect(byte, content="0")
    }
    Err(_) => fail("expected InvalidEbcdic")
  }
}

///|
test "记录过短报 RecordTooShort" {
  let layout = one_numeric(8, 0, false, Display)
  let r = decode_record_ordered(layout, bs([0xF0, 0xF1]))
  match r {
    Ok(_) => fail("expected error")
    Err(RecordTooShort(expected, actual)) => {
      inspect(expected, content="8")
      inspect(actual, content="2")
    }
    Err(_) => fail("expected RecordTooShort")
  }
}

///|
test "记录超长仍可解码（只读前 N 字节）" {
  let layout = one_numeric(2, 0, false, Display)
  let v = only(layout, bs([0xF4, 0xF2, 0xFF, 0xFF]))
  match v {
    Int(i) => inspect(i, content="42")
    _ => fail("expected Int")
  }
}

///|
test "decode_record 返回按路径索引的 map" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(2).\n  05 B PIC 9(2).\n"),
  )
  let rec = bs([0xC1, 0xC2, 0xF4, 0xF2])
  let m = decode_record(layout, rec).unwrap()
  inspect(m.length(), content="2")
  match m.get("R.A") {
    Some(Text(s)) => inspect(s, content="AB")
    _ => fail("R.A")
  }
  match m.get("R.B") {
    Some(Int(i)) => inspect(i, content="42")
    _ => fail("R.B")
  }
}

///|
test "decode_records 批量解码" {
  let layout = one_numeric(2, 0, false, Display)
  let data = bs([0xF0, 0xF1, 0xF0, 0xF2, 0xF0, 0xF3])
  let rows = decode_records(layout, data, 2).unwrap()
  inspect(rows.length(), content="3")
}

///|
test "decode_records 残缺尾记录报错" {
  let layout = one_numeric(2, 0, false, Display)
  let data = bs([0xF0, 0xF1, 0xF0, 0xF2, 0xF0])
  let r = decode_records(layout, data, 2)
  match r {
    Ok(_) => fail("expected error")
    Err(RecordTooShort(_, _)) => ()
    Err(_) => fail("expected RecordTooShort")
  }
}

///|
test "decode_records 记录长度小于 layout 报错" {
  let layout = one_numeric(4, 0, false, Display)
  let data = bs([0xF0, 0xF1])
  let r = decode_records(layout, data, 2)
  match r {
    Ok(_) => fail("expected error")
    Err(RecordTooShort(_, _)) => ()
    Err(_) => fail("expected RecordTooShort")
  }
}

///|
test "DecodeError::to_display" {
  inspect(
    DecodeError::RecordTooShort(54, 10).to_display(),
    content="record too short: expected 54 bytes, got 10",
  )
  inspect(
    DecodeError::InvalidEbcdic(7, 0).to_display(),
    content="invalid EBCDIC byte 0x00 at offset 7",
  )
  inspect(
    DecodeError::InvalidEbcdic(8, 0xAB).to_display(),
    content="invalid EBCDIC byte 0xAB at offset 8",
  )
}

///|
test "customer.cpy 真实记录解码" {
  let layout = compile_layout(
    parse_copybook(
      "01 CUSTOMER-RECORD.\n  05 CUST-ID PIC 9(8).\n  05 CUST-NAME PIC X(30).\n  05 BALANCE PIC S9(7)V99 COMP-3.\n  05 OPEN-DATE PIC 9(8).\n  05 FLAGS.\n    10 ACTIVE PIC X(1).\n    10 TIER PIC 9(2).\n",
    ),
  )
  // CUST-ID "00000042" → 8×0xF0/F4
  // CUST-NAME "ALICE" + 25 空格
  // BALANCE 123456789 → 5 字节 packed
  // OPEN-DATE 20260930 → 4×
  // ACTIVE "Y", TIER 07
  let arr : Array[Int32] = []
  for v in ([0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF4, 0xF2] : Array[Int32]) {
    arr.push(v)
  }
  for v in ([0xC1, 0xD3, 0xC9, 0xC3, 0xC5] : Array[Int32]) {
    arr.push(v)
  }
  for i = 0; i < 25; i = i + 1 {
    arr.push(0x40)
  }
  for v in ([0x12, 0x34, 0x56, 0x78, 0x9C] : Array[Int32]) {
    arr.push(v)
  }
  for v in ([0xF2, 0xF0, 0xF2, 0xF6, 0xF0, 0xF9, 0xF3, 0xF0] : Array[Int32]) {
    arr.push(v)
  }
  arr.push(0xE8) // Y
  arr.push(0xF0) // 0
  arr.push(0xF7) // 7
  let rec = bs(arr)
  inspect(rec.length(), content="54")
  let m = decode_record(layout, rec).unwrap()
  match m.get("CUSTOMER-RECORD.CUST-ID") {
    Some(Int(i)) => inspect(i, content="42")
    _ => fail("CUST-ID")
  }
  match m.get("CUSTOMER-RECORD.CUST-NAME") {
    Some(Text(s)) => inspect(s, content="ALICE")
    _ => fail("CUST-NAME")
  }
  match m.get("CUSTOMER-RECORD.BALANCE") {
    Some(Decimal(d)) => inspect(d.to_string(), content="1234567.89")
    _ => fail("BALANCE")
  }
  match m.get("CUSTOMER-RECORD.FLAGS.ACTIVE") {
    Some(Text(s)) => inspect(s, content="Y")
    _ => fail("ACTIVE")
  }
  match m.get("CUSTOMER-RECORD.FLAGS.TIER") {
    Some(Int(i)) => inspect(i, content="7")
    _ => fail("TIER")
  }
}

///|
test "redefines.cpy 同段字节两个视图" {
  let layout = compile_layout(
    parse_copybook(
      "01 ACCOUNT-MASTER.\n  05 ACCT-NO PIC 9(12).\n  05 ACCT-TYPE PIC X(2).\n  05 LIMIT-AMT PIC S9(9)V99 COMP-3.\n  05 ALT-VIEW REDEFINES LIMIT-AMT.\n    10 RAW-BYTE PIC X(6).\n  05 SSN PIC 9(9).\n",
    ),
  )
  inspect(layout.byte_length, content="29")
  let arr : Array[Int32] = []
  // ACCT-NO 12 位数字
  for i = 0; i < 12; i = i + 1 {
    arr.push(0xF0 + i % 10)
  }
  arr.push(0xC1)
  arr.push(0xC2)
  // LIMIT-AMT 6 字节 packed: 9 位数字 + 符号
  for v in ([0x12, 0x34, 0x56, 0x78, 0x9C, 0x0D] : Array[Int32]) {
    arr.push(v)
  }
  // SSN 9 位数字
  for i = 0; i < 9; i = i + 1 {
    arr.push(0xF1)
  }
  let rec = bs(arr)
  inspect(rec.length(), content="29")
  let m = decode_record(layout, rec).unwrap()
  // 两个视图都出现
  assert_true(m.get("ACCOUNT-MASTER.LIMIT-AMT") is Some(_))
  assert_true(m.get("ACCOUNT-MASTER.ALT-VIEW.RAW-BYTE") is Some(_))
}
