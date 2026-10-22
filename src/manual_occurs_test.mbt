///|
fn manual_occurs_layout(pic : String) -> RecordLayout raise ParseError {
  let compiled = compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic}.\n"))
  let field = { ..compiled.fields[0], occurs: 2, total_length: 2, }
  { ..compiled, byte_length: 2, fields: [field], all_fields: [field], }
}

///|
test "manual OCCURS: public unexpanded numeric and text layouts roundtrip" {
  for (pic, bytes) in [("9", b"\xF1\xF2"), ("X", b"\xC1\xC2")] {
    let layout = manual_occurs_layout(pic)
    match decode_record(layout, bytes) {
      Ok(row) => {
        assert_eq(row.length(), 2)
        assert_true(row.get("R.A(1)") is Some(_))
        assert_true(row.get("R.A(2)") is Some(_))
        match decode_record_ordered(layout, bytes) {
          Ok(values) => assert_eq(values.length(), 2)
          Err(_) => fail("ordered decode must expand manual OCCURS")
        }
        match encode_record(layout, row) {
          Ok(encoded) => assert_eq(encoded, bytes)
          Err(_) => fail("decoded indexed values must encode")
        }
      }
      Err(_) => fail("manual OCCURS must decode")
    }
  }
}

///|
test "manual OCCURS: indexed keys precede first-element bare fallback" {
  let layout = manual_occurs_layout("9")
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(9L)
  row["A"] = Int(8L)
  row["R.A(1)"] = Int(1L)
  row["R.A(2)"] = Int(2L)
  match encode_record(layout, row) {
    Ok(bytes) => assert_eq(bytes, b"\xF1\xF2")
    Err(_) => fail("indexed values must encode")
  }
  row.remove("R.A(1)") |> ignore
  row.remove("R.A(2)") |> ignore
  match encode_record(layout, row) {
    Ok(bytes) => assert_eq(bytes, b"\xF9\xF0")
    Err(_) => fail("bare path supplies only first element")
  }
  row.remove("R.A") |> ignore
  match encode_record(layout, row) {
    Ok(bytes) => assert_eq(bytes, b"\xF8\xF0")
    Err(_) => fail("bare name supplies only first element")
  }
  row["R.A(2)"] = Int(2L)
  match encode_record(layout, row) {
    Ok(bytes) => assert_eq(bytes, b"\xF8\xF2")
    Err(_) => fail("sparse indexed values must encode")
  }
}
