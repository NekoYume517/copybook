///|
test "Decimal to float preserves a negative sign in both formats and widths" {
  for mode in [FloatMode::Hfp, FloatMode::Ieee754] {
    for usage in ["COMP-1", "COMP-2"] {
      let layout = compile_layout_with_float_mode(
        parse_copybook("01 R.\n  05 A USAGE \{usage}.\n"),
        mode,
      )
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(15L, 1, true))
      let bytes = encode_record(layout, row).unwrap()
      assert_eq(bytes[0].to_int() & 0x80, 0x80)
      match decode_record(layout, bytes).unwrap().get("R.A") {
        Some(Float(f)) => assert_eq(f, -1.5)
        _ => assert_true(false)
      }
    }
  }
}

///|
test "Decimal to float preserves negative zero in both formats and widths" {
  for mode in [FloatMode::Hfp, FloatMode::Ieee754] {
    for usage in ["COMP-1", "COMP-2"] {
      let layout = compile_layout_with_float_mode(
        parse_copybook("01 R.\n  05 A USAGE \{usage}.\n"),
        mode,
      )
      let row : Map[String, CellValue] = Map([])
      row["R.A"] = Decimal(Decimal::from_parts(0L, 2, true))
      let bytes = encode_record(layout, row).unwrap()
      assert_eq(bytes[0].to_int(), 0x80)
      for i = 1; i < bytes.length(); i = i + 1 {
        assert_eq(bytes[i].to_int(), 0)
      }
    }
  }
}

///|
test "Decimal to float uses the explicit sign consistently with Decimal text" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A COMP-1.\n"))
  let row : Map[String, CellValue] = Map([])
  let value = Decimal::from_parts(-15L, 1, false)
  assert_eq(value.to_string(), "1.5")
  row["R.A"] = Decimal(value)
  match
    decode_record(layout, encode_record(layout, row).unwrap())
    .unwrap()
    .get("R.A") {
    Some(Float(f)) => assert_eq(f, 1.5)
    _ => assert_true(false)
  }
}
