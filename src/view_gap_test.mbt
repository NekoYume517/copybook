// CB-16 回归：REDEFINES 视图独占的**中部**区间必须保真，且空洞判定必须
// **值感知** —— 视图解出非 Null 时它确实写了那段字节，不能被原始字节回填覆盖。
//
// 第一部分（缺陷本身，修复前红）：
// 视图比主视图长、超出部分落在记录中部时，filler_gaps 把视图字段算作
// "已覆盖" -> 不发任何旁路键 -> encode_field 对 Null 视图直接 return 不写
// -> 该段字节保持 Writer 初始的 0x40。decode/encode 双双 exit 0，verify 却报
// byte mismatch。复现（min2.cpy，11 字节）：
//   A X(4) | B S9(4) COMP-3 | V REDEFINES B (V1 X(2), V2 9(2)) | C X(3)
//   数据 C1C2C3C4 01234C EE E7E8E9，offset 7 只被 V2 覆盖且解不出
//   -> 回写 C1C2C3C4 01234C 40 E7E8E9
//
// 第二部分（防止修复"判宽"引入反向缺陷）：
// 若只是把视图从覆盖集合剔除，视图解出非 Null 时它写好的字节会被回填
// 覆盖 —— decode -> 编辑视图 -> encode 的编辑被静默丢弃。

///|
fn viewgap_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  A   PIC X(4).\n    05  B   PIC S9(4) COMP-3.\n    05  V   REDEFINES B.\n        10  V1  PIC X(2).\n        10  V2  PIC 9(2).\n    05  C   PIC X(3).\n",
    ),
  )
}

///|
test "redefines view-only interior span survives the JSONL roundtrip (CB-16)" {
  let layout = viewgap_layout()
  inspect(layout.byte_length, content="11")
  let record = bs([
    0xC1, 0xC2, 0xC3, 0xC4, 0x01, 0x23, 0x4C, 0xEE, 0xE7, 0xE8, 0xE9,
  ])
  let row = decode_record(layout, record).unwrap()
  // 主视图解得出，视图两个叶子都解不出（0xEE 的 zone 不是 F）
  match row.get("R.B") {
    Some(Decimal(d)) => inspect(d.to_string(), content="1234")
    _ => fail("R.B must decode")
  }
  assert_true(row.get("R.V.V2") is Some(Null))
  // 视图独占的 offset 7 进中部空洞 -> 必须带出 __filler_hex
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__filler_hex\":\"ee\""))
  // JSONL 往返逐字节一致（修复前 offset 7 变 40）
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  // 两条路径结论必须一致：内存往返同样逐字节一致
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(_) => fail("roundtrip must not error")
  }
}

///|
test "redefines view-only span where the view is Null (CB-16)" {
  // 05 M PIC 9(2) 覆盖 0..2；V X(3) 覆盖 0..3 -> offset 2 只由 V 覆盖
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC 9(2).\n  05 V REDEFINES M PIC X(3).\n  05 Z PIC X(1).\n",
    ),
  )
  inspect(layout.byte_length, content="4")
  let record = bs([0xF1, 0xF2, 0xFF, 0xC1])
  let row = decode_record(layout, record).unwrap()
  assert_true(row.get("R.V") is Some(Null))
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__filler_hex\":\"ff\""))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    record,
  )
}

///|
test "editing a Null view over a hole must win over the bypass bytes (CB-16)" {
  // 视图解不出（FF FE 不可打印）-> 尾部空洞由 __tail_hex 携带
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M PIC X(4).\n"),
  )
  inspect(layout.byte_length, content="4")
  let record = bs([0xC3, 0xC4, 0xFF, 0xFE])
  let text = render_jsonl(layout, [decode_record(layout, record).unwrap()])
  assert_true(text.contains("\"__tail_hex\":\"fffe\""))
  // 原样往返逐字节一致
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    record,
  )
  // 把视图编辑成可打印的 WXYZ：0..4 全部由视图写入 -> 空洞消失，
  // 回填不得把 FF FE 写回来覆盖编辑结果
  let enc = encode_record(
    layout,
    parse_jsonl_row(layout, "{\"R.M\":\"CD\",\"R.V\":\"WXYZ\"}").unwrap(),
  ).unwrap()
  assert_eq(enc, bs([0xE6, 0xE7, 0xE8, 0xE9]))
}

///|
test "editing a non-Null view over a hole must win over the bypass bytes (CB-16)" {
  // V 非 Null：整段都由视图写入，不该有任何空洞
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M PIC X(3).\n  05 Z PIC X(2).\n",
    ),
  )
  inspect(layout.byte_length, content="5")
  let record = bs([0xC3, 0xC4, 0xC5, 0xC6, 0xC7])
  let text = render_jsonl(layout, [decode_record(layout, record).unwrap()])
  assert_false(text.contains("__filler_hex"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    record,
  )
  // 编辑视图：V 覆盖 0..3（视图后写、覆盖主视图，见 encode_field 契约），Z 覆盖 3..5
  let enc = encode_record(
    layout,
    parse_jsonl_row(layout, "{\"R.M\":\"CD\",\"R.V\":\"XYZ\",\"R.Z\":\"HI\"}").unwrap(),
  ).unwrap()
  assert_eq(enc, bs([0xE7, 0xE8, 0xE9, 0xC8, 0xC9]))
}
