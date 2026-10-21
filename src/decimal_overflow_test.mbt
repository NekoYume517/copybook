///|
test "decimal text rejects Int64 wraparound instead of writing small values" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
  for
    text in [
      "18446744073709551617", "-18446744073709551617", "36893488147419103233", "184467440737095516.17",
    ] {
    let row : Map[String, CellValue] = Map([])
    row["R.A"] = Text(text)
    assert_true(encode_record(layout, row) is Err(_))
  }
}

///|
test "decimal JSON number original text is checked before narrowing" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(3).\n"))
  let row = parse_jsonl_row(layout, "{\"R.A\":18446744073709551617}").unwrap()
  assert_true(encode_record(layout, row) is Err(_))
}

///|
test "decimal text still accepts full supported 18 digit precision" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(18).\n"))
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("-999999999999999999")
  let bytes = encode_record(layout, row).unwrap()
  let decoded = decode_record(layout, bytes).unwrap()
  match decoded.get("R.A") {
    Some(Decimal(d)) => assert_eq(d.to_string(), "-999999999999999999")
    _ => assert_true(false)
  }
}
