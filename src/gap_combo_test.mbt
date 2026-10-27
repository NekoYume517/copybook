// CB-15 回归：中部空洞（FILLER 区）与尾部空洞（REDEFINES 视图独占区）
// **同时存在**时，两条旁路键必须各自独立回填各自的区间。
//
// 复现（修复前）：`01 R. 05 A PIC X(2). 05 FILLER PIC X(2).
// 05 M PIC S9(3) COMP-3. 05 B REDEFINES M. 10 RAW PIC X(4).`
// 数据 C1 C2 C3 C4 12 3C FF EE —— FILLER 区的 C3 C4 往返后变 40 40：
//   encode → C1 C2 40 40 12 3C FF EE
// 根因：encode_record 的两个空洞集合（primary_tail_gaps / filler_gaps）
// 共用同一个顺序游标 idx，而承载字节的 `tail` 只取了**一个**键
// （__tail_hex 优先、否则 __filler_hex）；且 filler_gaps 的上界用的是
// byte_length，与尾部区间重叠 —— 同一段字节被消费两次。
//
// 尾部全空格的形态更直观地暴露「字节被搬到错误偏移」：
//   C1 C2 C3 C4 12 3C 40 40  →  C1 C2 40 40 12 3C C3 C4

///|
fn twogap_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(2).\n  05 M PIC S9(3) COMP-3.\n  05 B REDEFINES M.\n    10 RAW PIC X(4).\n",
    ),
  )
}

///|
test "gap combo: interior FILLER gap + REDEFINES tail gap, both non-space (CB-15)" {
  let layout = twogap_layout()
  inspect(layout.byte_length, content="8")
  let record = bs([0xC1, 0xC2, 0xC3, 0xC4, 0x12, 0x3C, 0xFF, 0xEE])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  // 两条旁路键都必须出现，且各自只含本区间的字节
  assert_true(text.contains("\"__tail_hex\":\"ffee\""))
  assert_true(text.contains("\"__filler_hex\":\"c3c4\""))
  // JSONL 往返必须逐字节一致
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  // 内存往返（verify 核心）同样逐字节一致
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(_) => fail("roundtrip must not error")
  }
}

///|
test "gap combo: interior FILLER non-space + all-space tail (CB-15)" {
  let layout = twogap_layout()
  // 尾部全 0x40 → 不携带 __tail_hex，只有 __filler_hex
  let record = bs([0xC1, 0xC2, 0xC3, 0xC4, 0x12, 0x3C, 0x40, 0x40])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__filler_hex\":\"c3c4\""))
  assert_false(text.contains("__tail_hex"))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  // 修复前：字节被搬到尾部 C1 C2 40 40 12 3C C3 C4
  assert_eq(encode_record(layout, parsed).unwrap(), record)
}

///|
test "gap combo: two interior FILLER gaps + a tail gap (CB-15)" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(1).\n  05 FILLER PIC X(1).\n  05 B PIC X(1).\n  05 FILLER PIC X(1).\n  05 M PIC S9(3) COMP-3.\n  05 C REDEFINES M.\n    10 RAW PIC X(4).\n",
    ),
  )
  inspect(layout.byte_length, content="8")
  let record = bs([0xC1, 0xC3, 0xC5, 0xC7, 0x12, 0x3C, 0xFF, 0xEE])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__filler_hex\":\"c3c7\""))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(_) => fail("roundtrip must not error")
  }
}
