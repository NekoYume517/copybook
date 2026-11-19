// 2026-11-20：FieldLayout.total_length 是 byte_length * occurs 的公开布局事实，
// 不是可小于实际写入宽度的提示值。非法跨度会在 decode/encode 之间产生不同域，
// 并让空洞快照把字段新值当作未写区间覆盖。

///|
fn mls_layout(total_length : Int32) -> RecordLayout raise ParseError {
  let compiled = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  let main = { ..compiled.fields[0], total_length, }
  let view = {
    ..compiled.fields[0],
    name: "B",
    path: "R.B",
    redefine_group: 1,
    is_redefining: true,
    is_synced: false,
  }
  { ..compiled, fields: [main, view], all_fields: [main, view], }
}

///|
test "manual layout rejects spans smaller than the actual field" {
  for bad_span in [0, -2] {
    let layout = mls_layout(bad_span)
    match
      encode_record(
        layout,
        Map([
          ("R.A", Text("AB")),
          ("R.B", Null),
          ("__record_bytes", Bytes(b"\xF1\xF2")),
        ]),
      ) {
      Err(FieldOutOfBounds(_, _, _)) => ()
      Err(e) =>
        fail("bad span returned the wrong encode error: \{e.to_display()}")
      Ok(bytes) =>
        fail(
          "bad span let __record_bytes overwrite the edit: \{bytes.to_array()}",
        )
    }
    match decode_record(layout, b"\xC1\xC2") {
      Err(FieldOutOfBounds(_, _, _)) => ()
      Err(e) =>
        fail("bad span returned the wrong decode error: \{e.to_display()}")
      Ok(_) =>
        fail("decode and encode disagree about the same malformed layout")
    }
  }
}

///|
test "valid layout still lets an edited field beat its stale byte snapshot" {
  let layout = mls_layout(2)
  match
    encode_record(
      layout,
      Map([
        ("R.A", Text("AB")),
        ("R.B", Null),
        ("__record_bytes", Bytes(b"\xF1\xF2")),
      ]),
    ) {
    Ok(bytes) => assert_eq(bytes.to_array(), [b'\xC1', b'\xC2'])
    Err(e) => fail("valid edited layout was rejected: \{e.to_display()}")
  }
}
