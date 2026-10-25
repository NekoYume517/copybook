// REDEFINES 尾部保真回归（CB-9）：重定义视图比主视图长、且该视图解不出时，
// 超出主视图的尾部字节必须在 decode → JSONL → encode 全链路逐字节保留。
//
// 复现（修复前）：01 R. 05 M PIC S9(3) COMP-3. 05 A REDEFINES M. 10 RAW PIC X(4).
// 记录 12 3C FF EE —— M 覆盖 0..1，RAW 覆盖 0..3。FF EE 不可打印，RAW 解码
// 失败置 Null；encode 跳过 RAW 后，位置 2..3 只剩 Writer 初始的 0x40，
// FF EE 被静默改写成 40 40（decode/encode 双双 exit 0，无任何警告）。

///|
fn redefines_tail_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC S9(3) COMP-3.\n  05 A REDEFINES M.\n    10 RAW PIC X(4).\n",
    ),
  )
}

///|
test "redefines tail: raw bytes beyond the primary view survive the JSONL roundtrip" {
  let layout = redefines_tail_layout()
  inspect(layout.byte_length, content="4")
  let record = bs([0x12, 0x3C, 0xFF, 0xEE])
  // 1) 宽容解码：主视图成功，RAW 视图失败置 Null
  let row = decode_record(layout, record).unwrap()
  match row.get("R.M") {
    Some(Decimal(d)) => inspect(d.to_string(), content="123")
    _ => fail("R.M must decode")
  }
  assert_true(row.get("R.A.RAW") is Some(Null))
  // 2) JSONL 往返：尾部字节必须原样回到位置 2..3（render_jsonl 行尾带 \n）
  let jsonl_text = render_jsonl(layout, [row])
  let expected = "{\"R.M\":123,\"R.A.RAW\":null,\"__nibbles\":{\"R.M\":{\"sign\":12}},\"__tail_hex\":\"ffee\"}"
  assert_true(jsonl_text == expected + "\n")
  let parsed = parse_jsonl_row(layout, jsonl_text).unwrap()
  let encoded = encode_record(layout, parsed).unwrap()
  assert_eq(encoded, record)
  // 3) 内存往返（verify 的核心路径）同样逐字节一致
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) =>
      fail("roundtrip must be byte-identical, first diff at \{off}")
    Err(_) => fail("roundtrip must not error")
  }
}

///|
test "redefines tail: space filler does not emit the tail key, zero bytes do" {
  let layout = redefines_tail_layout()
  // 尾部是 0x40（空格填充）：属于「未赋值工作存储区」惯例，不携带旁路信息
  let record = bs([0x12, 0x3C, 0x40, 0x40])
  let row = decode_record(layout, record).unwrap()
  let jsonl_text = render_jsonl(layout, [row])
  assert_false(jsonl_text.contains("__tail_hex"))
  let parsed = parse_jsonl_row(layout, jsonl_text).unwrap()
  let encoded = encode_record(layout, parsed).unwrap()
  assert_eq(encoded, record)
  // 全零**会**带出：0x00 与 0x40 字节不同，静默改写同样是数据损坏
  let record0 = bs([0x12, 0x3C, 0x00, 0x00])
  let row0 = decode_record(layout, record0).unwrap()
  let text0 = render_jsonl(layout, [row0])
  assert_true(text0.contains("\"__tail_hex\":\"0000\""))
  let encoded0 = encode_record(layout, parse_jsonl_row(layout, text0).unwrap()).unwrap()
  assert_eq(encoded0, record0)
}

///|
test "redefines tail: gap after a single primary field is preserved (manual layout)" {
  // 手工构造的布局（compiled 布局不会产生）：主视图 X(1) 在 0 结束于 1，
  // 重定义视图覆盖 0..3——记录尾部 1..3 只有重定义视图覆盖，同样属于
  // 尾部空洞，必须保真。这与 compiled 布局的 REDEFINES 尾部是同一条规则。
  let compiled = compile_layout(parse_copybook("01 R.\n  05 A PIC X(1).\n"))
  let main = compiled.fields[0]
  let alt : FieldLayout = {
    name: "B",
    path: "R.B",
    offset: 0,
    byte_length: 3,
    occurs: 1,
    total_length: 3,
    pic: {
      category: Alphanumeric,
      digits: 3,
      scale: 0,
      storage_digits: 3,
      signed: false,
      usage: Display,
      sign_separate: false,
      sign_leading: false,
      pic_text: "X(3)",
    },
    level: 5,
    redefine_group: 1,
    is_redefining: true,
  }
  let layout : RecordLayout = {
    ..compiled,
    byte_length: 3,
    fields: [main, alt],
    all_fields: [main, alt],
  }
  let record = bs([0xC1, 0xFF, 0xEE])
  let row = decode_record(layout, record).unwrap()
  match row.get("R.A") {
    Some(Text(s)) => inspect(s, content="A")
    _ => fail("R.A must decode")
  }
  // B 视图含不可打印字节 → Null；尾部 FF EE 必须原样保留
  assert_true(row.get("R.B") is Some(Null))
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__tail_hex\":\"ffee\""))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  let encoded = encode_record(layout, parsed).unwrap()
  assert_eq(encoded, record)
}
