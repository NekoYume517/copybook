// 2026-11-16：公开 PicClause / RecordLayout 可由调用方手工构造。
// parser 的 18 位上限不替代解码器的 Int64 累加溢出防护。

///|
fn mno_single(pic : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic}.\n"))
}

///|
test "manual 19-digit zoned layout rejects Int64 overflow" {
  let base = mno_single("9(18)")
  let pic = { ..base.fields[0].pic, digits: 19, storage_digits: 19 }
  let field = {
    ..base.fields[0],
    byte_length: 19,
    total_length: 19,
    pic,
  }
  let layout = { ..base, byte_length: 19, fields: [field], all_fields: [field] }
  let record = bs([0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9])
  match decode_record(layout, record) {
    Err(InvalidNumeric(_, message)) => assert_true(message.contains("Int64"))
    Err(e) => fail("expected InvalidNumeric, got \{e.to_display()}")
    Ok(_) => fail("19 zoned nines must not wrap the coefficient")
  }
}

///|
test "manual 19-digit packed layout rejects Int64 overflow" {
  let base = mno_single("9(18) COMP-3")
  let pic = { ..base.fields[0].pic, digits: 19, storage_digits: 19 }
  let field = { ..base.fields[0], pic }
  let layout = { ..base, fields: [field], all_fields: [field] }
  let record = bs([0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9F])
  match decode_record(layout, record) {
    Err(InvalidNumeric(_, message)) => assert_true(message.contains("Int64"))
    Err(e) => fail("expected InvalidNumeric, got \{e.to_display()}")
    Ok(_) => fail("19 packed nines must not wrap the coefficient")
  }
}
