///|
test "IBM packed: even precision has a leading zero nibble" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-3.\n"),
  )
  let row = decode_record(layout, b"\x01\x23\x4C").unwrap()
  match row.get("R.A") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 1234L)
      assert_eq(d.pad_nibble, Some(0))
    }
    _ => assert_true(false)
  }
  assert_eq(encode_record(layout, row).unwrap(), b"\x01\x23\x4C")
}

///|
test "IBM packed: encoding even precision does not append a zero digit" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-3.\n"),
  )
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(-1234L)
  assert_eq(encode_record(layout, row).unwrap(), b"\x01\x23\x4D")
}

///|
test "IBM packed: nonzero or nondecimal leading padding is rejected" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-3.\n"),
  )
  for bytes in [b"\x11\x23\x4C", b"\xF1\x23\x4C", b"\x12\x34\x0C"] {
    assert_true(decode_record(layout, bytes) is Err(_))
  }
}

///|
test "IBM packed: odd precision ending in zero has no padding" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3) COMP-3.\n"),
  )
  let row = decode_record(layout, b"\x12\x0C").unwrap()
  match row.get("R.A") {
    Some(Decimal(d)) => assert_eq(d.pad_nibble, None)
    _ => assert_true(false)
  }
}
