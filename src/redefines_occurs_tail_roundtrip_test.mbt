// 2026-11-20：parser 可达的 OCCURS + 长 REDEFINES 视图会在每个重复元素
// 尾部产生空洞。第一个元素的空洞位于记录中部，不能用“全记录恒单后缀”
// 的 tail 模型丢弃；内存路径与 JSONL 路径都必须逐字节往返。

///|
fn rotr_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 G OCCURS 2.\n    10 A PIC X(2).\n    10 V REDEFINES A PIC X(4).\n",
    ),
  )
}

///|
fn rotr_record() -> Bytes {
  // 两个 A 都是合法 EBCDIC；两个四字节 V 都含控制字节而 tolerant Null。
  b"\xC1\xC2\x00\x01\xC5\xC6\x02\x03"
}

///|
test "OCCURS REDEFINES preserves every element tail through memory roundtrip" {
  let layout = rotr_layout()
  let original = rotr_record()
  let row = decode_record(layout, original).unwrap()
  assert_true(row.get("R.G.V(1)") is Some(Null))
  assert_true(row.get("R.G.V(2)") is Some(Null))
  match encode_record(layout, row) {
    Ok(encoded) => assert_eq(encoded, original)
    Err(e) =>
      fail(
        "memory roundtrip rejected parser-produced layout: \{e.to_display()}",
      )
  }
}

///|
test "OCCURS REDEFINES preserves every element tail through JSONL roundtrip" {
  let layout = rotr_layout()
  let original = rotr_record()
  let row = decode_record(layout, original).unwrap()
  let jsonl = render_jsonl(layout, [row])
  let parsed = parse_jsonl_row(layout, jsonl).unwrap()
  match encode_record(layout, parsed) {
    Ok(encoded) => assert_eq(encoded, original)
    Err(e) =>
      fail("JSONL roundtrip rejected parser-produced layout: \{e.to_display()}")
  }
}
