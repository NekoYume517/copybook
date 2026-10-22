///|
test "IBM COMP: PIC widths are halfword, fullword, doubleword" {
  for (digits, width) in [(1, 2), (4, 2), (5, 4), (9, 4), (10, 8), (18, 8)] {
    let layout = compile_layout(
      parse_copybook("01 R.\n  05 A PIC S9(\{digits}) COMP.\n"),
    )
    assert_eq(layout.byte_length, width)
  }
}

///|
test "IBM COMP: signed and unsigned 18 digit values fit eight bytes" {
  for
    (signed, value) in [
      (false, 999999999999999999L),
      (true, -999999999999999999L),
    ] {
    let prefix = if signed { "S" } else { "" }
    let layout = compile_layout(
      parse_copybook("01 R.\n  05 A PIC \{prefix}9(18) COMP.\n"),
    )
    let row : Map[String, CellValue] = Map([])
    row["R.A"] = Int(value)
    match encode_record(layout, row) {
      Ok(bytes) => {
        assert_eq(bytes.length(), 8)
        match decode_record(layout, bytes) {
          Ok(decoded) =>
            match decoded.get("R.A") {
              Some(Decimal(d)) => assert_eq(d.to_string(), value.to_string())
              _ => assert_true(false)
            }
          Err(_) => assert_true(false)
        }
      }
      Err(_) => assert_true(false)
    }
  }
}

///|
test "IBM COMP: exact big endian bytes and following field offsets" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP.\n  05 B PIC X.\n"),
  )
  assert_eq(layout.fields[1].offset, 2)
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(-1234L)
  row["R.B"] = Text("A")
  match encode_record(layout, row) {
    Ok(bytes) => assert_eq(bytes, b"\xFB\x2E\xC1")
    Err(_) => assert_true(false)
  }
}

///|
test "IBM COMP: unsigned doubleword outside Int64 magnitude is rejected" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(18) COMP.\n"))
  assert_true(
    decode_record(layout, b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF") is Err(_),
  )
}

///|
test "IBM COMP: 18 digit decimal capacity rejects all 19 digit input forms" {
  for prefix in ["", "S"] {
    let layout = compile_layout(
      parse_copybook("01 R.\n  05 A PIC \{prefix}9(18) COMP.\n"),
    )
    for magnitude in [1000000000000000000L, 1234567890123456789L] {
      for negative in [false, true] {
        if negative && prefix == "" {
          continue
        }
        let value = if negative { -magnitude } else { magnitude }
        let inputs : Array[CellValue] = [
          Int(value),
          Text(value.to_string()),
          Decimal(Decimal::from_parts(magnitude, 0, negative)),
        ]
        for input in inputs {
          let row : Map[String, CellValue] = Map([])
          row["R.A"] = input
          match encode_record(layout, row) {
            Err(InvalidNumeric(_, message)) =>
              assert_true(message.contains("999999999999999999"))
            _ => fail("19 digit value must exceed PIC 9(18) capacity")
          }
        }
      }
    }
  }
}

///|
test "IBM COMP: exact 18 digit boundaries roundtrip every input form" {
  for prefix in ["", "S"] {
    let layout = compile_layout(
      parse_copybook("01 R.\n  05 A PIC \{prefix}9(18) COMP.\n"),
    )
    for negative in [false, true] {
      if negative && prefix == "" {
        continue
      }
      let magnitude = 999999999999999999L
      let value = if negative { -magnitude } else { magnitude }
      let inputs : Array[CellValue] = [
        Int(value),
        Text(value.to_string()),
        Decimal(Decimal::from_parts(magnitude, 0, negative)),
      ]
      for input in inputs {
        let row : Map[String, CellValue] = Map([])
        row["R.A"] = input
        match encode_record(layout, row) {
          Ok(bytes) =>
            match decode_record(layout, bytes) {
              Ok(decoded) =>
                match decoded.get("R.A") {
                  Some(Decimal(d)) =>
                    assert_eq(d.to_string(), value.to_string())
                  _ => fail("missing decoded numeric field")
                }
              Err(_) => fail("valid COMP bytes must decode")
            }
          Err(_) => fail("18 digit boundary must encode")
        }
      }
    }
  }
}
