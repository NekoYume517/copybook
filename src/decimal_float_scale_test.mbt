// 2026-11-19 对抗性回归：Decimal 的值定义为 coefficient × 10^(-scale)。
// 转 COMP-1/COMP-2 时负 scale 必须乘 10 的正幂，不能和正 scale 一样走除法。

///|
test "Decimal with negative scale keeps its magnitude in every float mode and width" {
  let value = Decimal::from_parts(123L, -2, false)
  assert_eq(value.to_string(), "12300")
  for mode in [FloatMode::Hfp, FloatMode::Ieee754] {
    for usage in ["COMP-1", "COMP-2"] {
      let layout = compile_layout_with_float_mode(
        parse_copybook("01 R.\n  05 A USAGE \{usage}.\n"),
        mode,
      )
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(value)
      let encoded = encode_record(layout, row).unwrap()
      match decode_record(layout, encoded).unwrap().get("R.A") {
        Some(Float(actual)) => assert_eq(actual, 12300.0)
        _ => fail("Decimal 12300 must decode back as Float 12300")
      }
    }
  }
}
