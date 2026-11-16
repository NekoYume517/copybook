// 2026-11-16：公开 RecordLayout 可由调用方手工构造。
// 即使 parser 不会产出这种形态，切片边界也必须显式报错，不能回绕。

///|
test "manual layout offset plus length cannot wrap past the bounds check" {
  let base = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  let field = {
    ..base.fields[0],
    offset: 2147483647,
    byte_length: 2,
    total_length: 2,
  }
  let layout = { ..base, byte_length: 0, fields: [field], all_fields: [field], }
  match decode_record(layout, b"\xC1\xC2") {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) => fail("expected FieldOutOfBounds, got \{e.to_display()}")
    Ok(_) => fail("wrapped field offset must not decode")
  }
}
