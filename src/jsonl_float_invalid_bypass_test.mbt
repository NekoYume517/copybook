// 2026-11-20：__float_hex 一致性检查不得把非法数值文本当作 0.0。
// 原始半字节旁路只允许纠正合法解析后精度与 wire 不同的合法数值。

///|
test "invalid float text cannot pass a zero __float_hex consistency check" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  let line = "{\"R.F\":\"garbage\",\"__float_hex\":{\"R.F\":\"00000000\"}}"
  let row = parse_jsonl_row(layout, line).unwrap()
  match encode_record(layout, row) {
    Ok(bytes) =>
      fail(
        "invalid float text was silently replaced by wire bytes \{bytes.to_array()}",
      )
    Err(e) => assert_true(e.to_display().contains("numeric"))
  }
}

///|
test "float hex correction remains available for valid numeric text" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 F COMP-1.\n"))
  let stale = parse_jsonl_row(
    layout, "{\"R.F\":1.0,\"__float_hex\":{\"R.F\":\"00000000\"}}",
  ).unwrap()
  match encode_record(layout, stale) {
    Ok(bytes) =>
      assert_eq(bytes.to_array(), [b'\x41', b'\x10', b'\x00', b'\x00'])
    Err(e) => fail("valid stale-wire correction regressed: \{e.to_display()}")
  }
  let matching = parse_jsonl_row(
    layout, "{\"R.F\":0,\"__float_hex\":{\"R.F\":\"80000000\"}}",
  ).unwrap()
  match encode_record(layout, matching) {
    Ok(bytes) =>
      assert_eq(bytes.to_array(), [b'\x80', b'\x00', b'\x00', b'\x00'])
    Err(e) =>
      fail("matching negative-zero wire bytes regressed: \{e.to_display()}")
  }
}
