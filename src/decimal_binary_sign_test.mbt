// 2026-11-19 对抗性回归：Decimal 的 negative 标志是符号的权威来源，
// coefficient 是幅值载体。公开 from_parts 允许负系数；to_string 与其他编码
// 路径（zoned / packed / float）都按 negative 解释它，COMP 也不能例外。

///|
test "signed COMP honors Decimal negative flag instead of coefficient sign" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(4) COMP.\n"))
  let value = Decimal::from_parts(-42L, 0, false)
  assert_eq(value.to_string(), "42")
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Decimal(value)
  let encoded = encode_record(layout, row).unwrap()
  assert_eq(encoded, b"\x00\x2A")
  match decode_record(layout, encoded).unwrap().get("R.A") {
    Some(Decimal(d)) => {
      assert_eq(d.to_string(), "42")
      assert_false(d.negative)
    }
    _ => fail("positive Decimal must roundtrip as +42")
  }
}

///|
test "unsigned COMP accepts a positive Decimal backed by a negative coefficient" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(4) COMP.\n"))
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Decimal(Decimal::from_parts(-42L, 0, false))
  match encode_record(layout, row) {
    Ok(encoded) => assert_eq(encoded, b"\x00\x2A")
    Err(e) =>
      fail("positive Decimal was rejected as negative: \{e.to_display()}")
  }
}
