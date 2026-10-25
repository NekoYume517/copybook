// P1-2 回归：FILLER 区域的原始字节必须在 decode → JSONL → encode 与
// verify（内存往返）全链路逐字节保留，不能被 Writer 初始的 0x40 静默替换。
//
// 复现（修复前）：`01 R. 05 A PIC X(2). 05 FILLER PIC X(2). 05 B PIC X(2).`
// 数据 C1 C2 C3 C4 C5 C6 —— FILLER 区的 C3 C4 往返后变 40 40，
// `copybook verify` 自身 exit 1（byte mismatch at offset 2）。
// JSONL 契约保持：输出里不出现 FILLER 字段，旁路信息走保留键 __filler_hex
// （与 __tail_hex 同一手法；全 0x40 的未赋值惯例不携带、不输出）。

///|
test "filler: interior FILLER bytes survive the JSONL roundtrip (P1-2)" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(2).\n  05 B PIC X(2).\n",
    ),
  )
  inspect(layout.byte_length, content="6")
  let record = bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6])
  // 1) 宽容解码挂原始字节；JSONL 用 __filler_hex 带出 C3 C4
  let row = decode_record(layout, record).unwrap()
  match row.get("R.A") {
    Some(Text(s)) => inspect(s, content="AB")
    _ => fail("R.A must decode")
  }
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__filler_hex\":\"c3c4\""))
  // 2) JSONL 往返逐字节一致
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  // 3) 内存往返（verify 核心）逐字节一致
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) =>
      fail("filler roundtrip must be byte-identical, diff at \{off}")
    Err(_) => fail("filler roundtrip must not error")
  }
}

///|
test "filler: all-space FILLER emits no bypass key and still roundtrips (P1-2)" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(2).\n  05 B PIC X(2).\n",
    ),
  )
  // 全 0x40：未赋值工作存储区惯例，不携带信息（与 __tail_hex 同规）
  let record = bs([0xC1, 0xC2, 0x40, 0x40, 0xC5, 0xC6])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  assert_false(text.contains("__filler_hex"))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    _ => fail("space filler roundtrip must be byte-identical")
  }
}

///|
test "filler: trailing FILLER rides the __tail_hex path (P1-2)" {
  // 尾部 FILLER 是「主视图结束之后的空洞」，语义上与 REDEFINES 尾部空洞
  // 同类，走既有 __tail_hex 通道，同样必须保真。
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(1).\n  05 FILLER PIC X(2).\n"),
  )
  inspect(layout.byte_length, content="3")
  let record = bs([0xC1, 0xC3, 0xC4])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__tail_hex\":\"c3c4\""))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    _ => fail("trailing filler roundtrip must be byte-identical")
  }
}

///|
test "filler: multiple interior gaps each preserved in order (P1-2)" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(1).\n  05 FILLER PIC X(1).\n  05 B PIC X(1).\n  05 FILLER PIC X(1).\n  05 C PIC X(1).\n",
    ),
  )
  inspect(layout.byte_length, content="5")
  let record = bs([0xC1, 0xC3, 0xC5, 0xC7, 0xC9])
  let row = decode_record(layout, record).unwrap()
  let text = render_jsonl(layout, [row])
  // 两个 1 字节空洞按偏移序拼接：c3 c7
  assert_true(text.contains("\"__filler_hex\":\"c3c7\""))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    _ => fail("multi-gap filler roundtrip must be byte-identical")
  }
}
