// 2026-11-20：FieldSpec/PicClause 可公开手工构造，布局宽度公式必须先提升
// 到 Int64；N digits*2、COMP-3 digits+2、SEPARATE digits+1 不能先回绕。

///|
fn mplo_compile(
  source : String,
  digits : Int32,
) -> Result[RecordLayout, ParseError] raise ParseError {
  let specs = parse_copybook(source)
  let leaf = specs[0].children[0]
  let pic = { ..leaf.pic.unwrap(), digits, storage_digits: digits, }
  let root = { ..specs[0], children: [{ ..leaf, pic: Some(pic), }], }
  Ok(compile_layout([root])) catch {
    e => Err(e)
  }
}

///|
test "manual PIC width arithmetic rejects Int32 wraparound" {
  for
    (label, result) in [
      ("NATIONAL", mplo_compile("01 R.\n  05 A PIC N(4).\n", 1200000000)),
      (
        "SIGN SEPARATE",
        mplo_compile("01 R.\n  05 A PIC S9(4) SIGN SEPARATE.\n", 2147483647),
      ),
    ] {
    match result {
      Err(InvalidLayout(_)) => ()
      Err(e) => fail("\{label}: wrong error: \{e.to_display()}")
      Ok(layout) =>
        fail(
          "\{label}: wrapped width became record length \{layout.byte_length}",
        )
    }
  }
  // (Int32::MAX + 2) / 2 的数学结果仍在 Int32 内；旧实现先回绕成负数，
  // 新实现必须给出这个合法宽度，而不是一律拒绝大位数的 COMP-3。
  match mplo_compile("01 R.\n  05 A PIC 9(4) COMP-3.\n", 2147483647) {
    Ok(layout) => assert_eq(layout.byte_length, 1073741824)
    Err(e) =>
      fail("in-range COMP-3 mathematical width was rejected: \{e.to_display()}")
  }
}

///|
test "ordinary PIC width formulas are unchanged" {
  match mplo_compile("01 R.\n  05 A PIC N(4).\n", 4) {
    Ok(layout) => assert_eq(layout.byte_length, 8)
    Err(e) => fail("legal NATIONAL width regressed: \{e.to_display()}")
  }
  match mplo_compile("01 R.\n  05 A PIC 9(4) COMP-3.\n", 4) {
    Ok(layout) => assert_eq(layout.byte_length, 3)
    Err(e) => fail("legal COMP-3 width regressed: \{e.to_display()}")
  }
  match mplo_compile("01 R.\n  05 A PIC S9(4) SIGN SEPARATE.\n", 4) {
    Ok(layout) => assert_eq(layout.byte_length, 5)
    Err(e) => fail("legal separate-sign width regressed: \{e.to_display()}")
  }
}
