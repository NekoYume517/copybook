// 2026-11-19 对抗性回归：Decimal 的值定义为 coefficient × 10^(-scale)。
// 转 COMP-1/COMP-2 时负 scale 必须乘 10 的正幂，不能和正 scale 一样走除法。
// Decimal 的值域不等于 PicClause 的 [-18,18] 域；极端 scale 也必须保持数学
// 语义，只是不能通过线性循环计算。

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
test "COMP-2 preserves a legitimate Decimal scale of 19" {
  let layout = compile_layout_with_float_mode(
    parse_copybook("01 R.\n  05 A USAGE COMP-2.\n"),
    FloatMode::Ieee754,
  )
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Decimal(Decimal::from_parts(1L, 19, false))
  let encoded = encode_record(layout, row).unwrap()
  match decode_record(layout, encoded).unwrap().get("R.A") {
    Some(Float(actual)) => assert_eq(actual, 0.0000000000000000001)
    _ => fail("Decimal scale 19 must decode as Float")
  }
}

///|
test "COMP-2 retains finite values on both sides of the pow10 boundary" {
  // pow10(308) 仍是有限 Double；308 不能直接走极端值短路。
  let layout = compile_layout_with_float_mode(
    parse_copybook("01 R.\n  05 A USAGE COMP-2.\n"),
    FloatMode::Ieee754,
  )
  let mut boundary = 1.0
  for i = 0; i < 308; i = i + 1 {
    boundary = boundary * 10.0
  }
  for (scale, expected) in [(308, 1.0 / boundary), (-308, boundary)] {
    let row : Map[String, CellValue] = Map([])
    row["R.A"] = Decimal(Decimal::from_parts(1L, scale, false))
    let encoded = encode_record(layout, row).unwrap()
    match decode_record(layout, encoded).unwrap().get("R.A") {
      Some(Float(actual)) => assert_eq(actual, expected)
      _ => fail("finite boundary value must decode as Float")
    }
  }
}

///|
test "COMP-2 extreme nonzero scales short-circuit to the same signed values" {
  let layout = compile_layout_with_float_mode(
    parse_copybook("01 R.\n  05 A USAGE COMP-2.\n"),
    FloatMode::Ieee754,
  )
  // pow10(309) 已是 Infinity。正 scale 的非零值除以它为 signed zero；
  // 负 scale 的非零值乘以它为 signed Infinity。MIN 不能取反，也走这里。
  for
    (scale, negative, expected) in [
      (309, false, 0.0),
      (2000000000, false, 0.0),
      (309, true, -0.0),
      (-309, false, 1.0 / 0.0),
      (-2147483648, false, 1.0 / 0.0),
      (-309, true, -1.0 / 0.0),
      (-2147483648, true, -1.0 / 0.0),
    ] {
    let row : Map[String, CellValue] = Map([])
    row["R.A"] = Decimal(Decimal::from_parts(1L, scale, negative))
    let encoded = encode_record(layout, row).unwrap()
    match decode_record(layout, encoded).unwrap().get("R.A") {
      Some(Float(actual)) =>
        assert_eq(
          actual.reinterpret_as_int64(),
          expected.reinterpret_as_int64(),
        )
      Some(FloatRaw(actual, _)) =>
        assert_eq(
          actual.reinterpret_as_int64(),
          expected.reinterpret_as_int64(),
        )
      _ => fail("extreme nonzero value must decode as Float")
    }
  }
}

///|
test "COMP-2 extreme zero scales never turn zero into NaN" {
  let layout = compile_layout_with_float_mode(
    parse_copybook("01 R.\n  05 A USAGE COMP-2.\n"),
    FloatMode::Ieee754,
  )
  for scale in [-2147483648, -309, 309, 2000000000] {
    for negative in [false, true] {
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(0L, scale, negative))
      let encoded = encode_record(layout, row).unwrap()
      match decode_record(layout, encoded).unwrap().get("R.A") {
        Some(Float(actual)) => {
          let expected = if negative { -9223372036854775808L } else { 0L }
          assert_eq(actual.reinterpret_as_int64(), expected)
        }
        _ => fail("extreme zero must decode as Float")
      }
    }
  }
}
