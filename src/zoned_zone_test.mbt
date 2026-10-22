///|
test "zoned: repeated sign zones outside the sign position are rejected" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
  for bytes in [b"\xF1\xC2\xF3", b"\xF1\xD2\xF3"] {
    match decode_record(layout, bytes) {
      Err(InvalidNumeric(offset, message)) => {
        assert_eq(offset, 1)
        assert_true(message.contains("expected F"))
      }
      _ => fail("only the declared sign position can carry C/D zones")
    }
  }
}

///|
test "zoned: leading trailing and separate sign positions roundtrip" {
  for
    (clause, bytes, expected) in [
      ("", b"\xF1\xF2\xC3", "123"),
      ("", b"\xF1\xF2\xD3", "-123"),
      (" SIGN IS LEADING", b"\xC1\xF2\xF3", "123"),
      (" SIGN IS LEADING", b"\xD1\xF2\xF3", "-123"),
      (" SIGN IS TRAILING SEPARATE", b"\xF1\xF2\xF3\x4E", "123"),
      (" SIGN IS TRAILING SEPARATE", b"\xF1\xF2\xF3\x60", "-123"),
      (" SIGN IS LEADING SEPARATE", b"\x4E\xF1\xF2\xF3", "123"),
      (" SIGN IS LEADING SEPARATE", b"\x60\xF1\xF2\xF3", "-123"),
    ] {
    let layout = compile_layout(
      parse_copybook("01 R.\n  05 A PIC S9(3)\{clause}.\n"),
    )
    match decode_record(layout, bytes) {
      Ok(row) => {
        match row.get("R.A") {
          Some(Decimal(d)) => assert_eq(d.to_string(), expected)
          _ => fail("missing zoned decimal")
        }
        match encode_record(layout, row) {
          Ok(encoded) => assert_eq(encoded, bytes)
          Err(_) => fail("decoded sign must encode")
        }
      }
      Err(_) => fail("declared sign position must decode")
    }
  }
}
