// 2026-11-16：手工 OCCURS 重定义视图的空洞判定必须逐元素镜像 encode。
// 视图比主视图长时，显式编辑一个元素不能让其它元素的快照覆盖它；
// 裸路径只后备第一个元素，也不能让后续 Null 元素丢掉尾部快照。

///|
fn movg_layout() -> RecordLayout raise ParseError {
  let primary = compile_layout(parse_copybook("01 R.\n  05 A PIC X.\n"))
  let numeric = compile_layout(parse_copybook("01 R.\n  05 B PIC 9.\n"))
  let view = {
    ..numeric.fields[0],
    occurs: 2,
    total_length: 2,
    redefine_group: 1,
    is_redefining: true,
  }
  {
    ..primary,
    byte_length: 2,
    fields: [primary.fields[0], view],
    all_fields: [primary.fields[0], view],
  }
}

///|
test "manual OCCURS view: an indexed edit wins over the original tail snapshot" {
  let layout = movg_layout()
  let original = b"\xD1\xD2"
  let row = decode_record(layout, original).unwrap()
  assert_true(row.get("R.B(1)") is Some(Null))
  assert_true(row.get("R.B(2)") is Some(Null))
  assert_true(row.get("__record_bytes") is Some(Bytes(_)))
  row["R.B(2)"] = Int(2L)
  match encode_record(layout, row) {
    Ok(encoded) => assert_eq(encoded, b"\xD1\xF2")
    Err(e) => fail("indexed view edit must encode: \{e.to_display()}")
  }
}

///|
test "manual OCCURS view: bare fallback does not erase later null elements" {
  let layout = movg_layout()
  let original = b"\xD1\xD2"
  let row = decode_record(layout, original).unwrap()
  // 让裸路径后备真正生效：显式下标键优先，所以先移除 B(1) 的 Null。
  row.remove("R.B(1)") |> ignore
  row["R.B"] = Int(8L)
  match encode_record(layout, row) {
    // 裸路径只给 B(1)；B(2) 仍是 Null，尾部 D2 必须回填。
    Ok(encoded) => assert_eq(encoded, b"\xF8\xD2")
    Err(e) => fail("bare first-element fallback must encode: \{e.to_display()}")
  }
}

///|
test "manual OCCURS view: mixed indexed values preserve the remaining snapshot" {
  let layout = movg_layout()
  let original = b"\xD1\xD2"
  let row = decode_record(layout, original).unwrap()
  row["R.B(1)"] = Int(8L)
  row["R.B(2)"] = Text("")
  match encode_record(layout, row) {
    // 数值视图的空串与 Null 一样跳过；第二个字节仍由快照承载。
    Ok(encoded) => assert_eq(encoded, b"\xF8\xD2")
    Err(e) => fail("mixed indexed values must encode: \{e.to_display()}")
  }
}
