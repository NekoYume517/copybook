///|
test "IBM NATIONAL: ASCII and Chinese decode as UTF16BE" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC N(2).\n"))
  let row = decode_record(layout, b"\x00\x41\x4E\x2D").unwrap()
  match row.get("R.A") {
    Some(Text(s)) => assert_eq(s, "A中")
    _ => assert_true(false)
  }
}

///|
test "IBM NATIONAL: encode Unicode and pad with U0020" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC N(3).\n"))
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("A中")
  let bytes = encode_record(layout, row).unwrap()
  assert_eq(bytes, b"\x00\x41\x4E\x2D\x00\x20")
  assert_eq(roundtrip_check(layout, bytes).unwrap(), None)
}

///|
test "IBM NATIONAL: a surrogate pair occupies two code units" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC N(2).\n"))
  let bytes : Bytes = b"\xD8\x3D\xDE\x00"
  let row = decode_record(layout, bytes).unwrap()
  match row.get("R.A") {
    Some(Text(s)) => assert_eq(s, "😀")
    _ => assert_true(false)
  }
  assert_eq(encode_record(layout, row).unwrap(), bytes)
  let narrow = compile_layout(parse_copybook("01 R.\n  05 A PIC N(1).\n"))
  assert_true(encode_record(narrow, row) is Err(_))
}

///|
test "IBM NATIONAL: malformed surrogate sequences report the byte offset" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 P PIC X.\n  05 A PIC N(2).\n"),
  )
  for bytes in [b"\xC1\xDC\x00\x00\x20", b"\xC1\xD8\x00\x00\x41"] {
    match decode_record(layout, bytes) {
      Err(InvalidNumeric(offset, _)) => assert_eq(offset, 1)
      _ => assert_true(false)
    }
  }
  let short_layout = compile_layout(parse_copybook("01 R.\n  05 A PIC N(1).\n"))
  assert_true(decode_record(short_layout, b"\xD8\x00") is Err(_))
}
