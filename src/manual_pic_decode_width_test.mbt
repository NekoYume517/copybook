// 2026-11-20：公开手工 FieldLayout 的 PIC 存储宽度与 slot 必须一致。
// encode 不能只防越界写而在 slot 更宽时放行，decode 也不能按 slot 全长读取；
// 否则同一布局一个方向成功、另一个方向 FieldOutOfBounds 或解出不同数值。

///|
fn mpd_layout(source : String, slot : Int32) -> RecordLayout raise ParseError {
  let base = compile_layout(parse_copybook(source))
  let field = { ..base.fields[0], byte_length: slot, total_length: slot, }
  { ..base, byte_length: slot, fields: [field], all_fields: [field], }
}

///|
fn mpd_record(length : Int32) -> Bytes {
  Bytes::makei(length, fn(_) { b'\xF0' })
}

///|
fn mpd_reject(layout : RecordLayout, label : String) -> Unit raise {
  match decode_record(layout, mpd_record(layout.byte_length)) {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) =>
      fail("\{label}: decode returned the wrong error: \{e.to_display()}")
    Ok(_) => fail("\{label}: decode accepted a PIC/slot width mismatch")
  }
  match encode_record(layout, Map([])) {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) =>
      fail("\{label}: encode returned the wrong error: \{e.to_display()}")
    Ok(_) => fail("\{label}: encode accepted a PIC/slot width mismatch")
  }
}

///|
test "manual numeric PIC and slot widths disagree in both directions" {
  mpd_reject(mpd_layout("01 R.\n  05 A PIC 9(8).\n", 1), "narrow zoned")
  mpd_reject(mpd_layout("01 R.\n  05 A PIC 9(5) COMP.\n", 3), "3-byte COMP")
  mpd_reject(mpd_layout("01 R.\n  05 A PIC N(4).\n", 2), "narrow NATIONAL")
  mpd_reject(mpd_layout("01 R.\n  05 A PIC 9(1).\n", 2), "wide zoned")
}

///|
test "parser-produced numeric widths remain valid" {
  let layout = mpd_layout("01 R.\n  05 A PIC 9(3).\n", 3)
  match decode_record(layout, b"\xF0\xF0\xF1") {
    Ok(row) =>
      match row.get("R.A") {
        Some(Int(i)) => assert_eq(i, 1L)
        _ => fail("legal zoned layout decoded the wrong value")
      }
    Err(e) => fail("legal zoned layout was rejected: \{e.to_display()}")
  }
  match encode_record(layout, Map([("R.A", CellValue::Int(1L))])) {
    Ok(bytes) => assert_eq(bytes.to_array(), [b'\xF0', b'\xF0', b'\xF1'])
    Err(e) => fail("legal zoned layout no longer encodes: \{e.to_display()}")
  }
}
