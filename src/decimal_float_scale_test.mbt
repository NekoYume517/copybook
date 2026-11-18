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

///|
test "float Decimal input rejects scales outside the parser-reachable domain" {
  // PicClause 的 C11 闸门管不到公开 Decimal::from_parts。MIN 会在 -scale
  // 时回绕；19 已越界但足够小，旧实现会迅速成功而不是在红灯阶段挂死。
  // 修复后再把 2_000_000_000 纳入同一回归：它必须被入口立即拒绝，绝不能
  // 进入 pow10 的线性循环（旧代码上不可直接运行这个输入）。
  for scale in [-2147483648, 19, 2000000000] {
    for usage in ["COMP-1", "COMP-2"] {
      let layout = compile_layout(
        parse_copybook("01 R.\n  05 A USAGE \{usage}.\n"),
      )
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(123L, scale, false))
      match encode_record(layout, row) {
        Err(e) => assert_true(e.to_display().contains("scale"))
        Ok(_) => fail("Decimal scale \{scale} must be rejected at float entry")
      }
    }
  }
}
