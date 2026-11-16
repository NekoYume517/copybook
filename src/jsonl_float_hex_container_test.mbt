// 2026-11-16：__float_hex 整键必须是 {field: hex} 对象。
// 数组、标量或 null 都是损坏的保留键，不能静默当成“没有旁路”。

///|
test "__float_hex rejects a non-object container instead of discarding byte identity" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  for bad in ["[]", "null", "\"4180000000000001\"", "1", "true"] {
    let line = "{\"R.D\":8,\"__float_hex\":\{bad}}"
    match parse_jsonl_row(layout, line) {
      Err(e) => assert_true(e.contains("__float_hex"))
      Ok(_) => fail("non-object __float_hex must be rejected: \{bad}")
    }
  }
}

///|
test "__float_hex object container still restores the original bytes" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 D COMP-2.\n"))
  let row = parse_jsonl_row(
    layout, "{\"R.D\":8,\"__float_hex\":{\"R.D\":\"4180000000000001\"}}",
  ).unwrap()
  let encoded = encode_record(layout, row).unwrap()
  assert_eq(encoded, b"\x41\x80\x00\x00\x00\x00\x00\x01")
}
