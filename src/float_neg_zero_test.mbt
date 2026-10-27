// CB-17 回归：浮点的 **负零** 必须跨 JSONL 链路保住符号位。
//
// FIDELITY.md §2.3 明确承诺 HFP 的 ±0 各自往返（`00 00 00 00` vs
// `80 00 00 00`），§3 把「浮点符号位（含 ±0）」列为必须保留的信息。
//
// 复现（修复前）：output.mbt 的 Float 分支用 f.to_string() 取 repr，
// 而 Double::to_string() 对 -0.0 返回 "0"（探针实测），于是 JSON 里只剩
// `0`，符号位在文本这一环丢失：
//   decode → {"R.F":0}      （应为 {"R.F":-0}）
//   encode → 00 00 00 00    （orig 80 00 00 00）
// 而 verify 同一条记录报 byte-identical —— 两条路径结论互相矛盾。
//
// 注意 jsonl.mbt 的 format_json_number（手写 JSON 无 repr 的兜底路径）
// **已经**正确处理了负零，只有导出侧漏了。

///|
test "HFP COMP-1 negative zero keeps its sign bit across JSONL (CB-17)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  inspect(layout.byte_length, content="4")
  let neg_zero = bs([0x80, 0x00, 0x00, 0x00])
  let row = decode_record(layout, neg_zero).unwrap()
  // decode 必须区分 -0.0 与 +0.0
  match row.get("R.F") {
    Some(Float(f)) => assert_true(f == 0.0)
    _ => fail("expected a Float cell for R.F")
  }
  let text = render_jsonl(layout, [row])
  // JSONL 里必须是 -0（JSON 禁止把 -0 规范化成 0 之外的形态）
  assert_true(text.contains("-0"))
  // 往返逐字节一致
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), neg_zero)
  // 内存路径（verify 核心）也一致 —— 两条路径必须给出同一结论
  match roundtrip_check(layout, neg_zero) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(_) => fail("roundtrip must not error")
  }
}

///|
test "HFP COMP-1 positive zero stays +0 (no spurious sign) (CB-17)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  let pos_zero = bs([0x00, 0x00, 0x00, 0x00])
  let row = decode_record(layout, pos_zero).unwrap()
  let text = render_jsonl(layout, [row])
  assert_false(text.contains("-0"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    pos_zero,
  )
}

///|
test "HFP COMP-2 negative zero keeps its sign bit across JSONL (CB-17)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  inspect(layout.byte_length, content="8")
  let neg_zero = bs([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  let row = decode_record(layout, neg_zero).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("-0"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    neg_zero,
  )
}

///|
test "IEEE COMP-1 negative zero keeps its sign bit across JSONL (CB-17)" {
  // IEEE 的 -0.0 位模式同为 80 00 00 00；--float-mode ieee 下同样必须保真
  let layout = compile_layout_with_float_mode(
    parse_copybook("01 R.\n  05 F COMP-1.\n"),
    Ieee754,
  )
  let neg_zero = bs([0x80, 0x00, 0x00, 0x00])
  let row = decode_record(layout, neg_zero).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("-0"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    neg_zero,
  )
}

///|
test "integer and packed negative zero are unaffected (regression guard) (CB-17)" {
  // CB-2 已修：zoned F0 F0 D0 / packed 00 0D 的 -0 靠 __nibbles 旁路保真，
  // 本次改动不得破坏它。
  let zoned = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
  let zrec = bs([0xF0, 0xF0, 0xD0])
  let ztext = render_jsonl(zoned, [decode_record(zoned, zrec).unwrap()])
  assert_eq(
    encode_record(zoned, parse_jsonl_row(zoned, ztext).unwrap()).unwrap(),
    zrec,
  )
  let packed = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-3.\n"),
  )
  let prec = bs([0x00, 0x00, 0x0D])
  let ptext = render_jsonl(packed, [decode_record(packed, prec).unwrap()])
  assert_eq(
    encode_record(packed, parse_jsonl_row(packed, ptext).unwrap()).unwrap(),
    prec,
  )
}
