// JUSTIFIED RIGHT 的字节保真（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `05 A PIC X(5) JUSTIFIED RIGHT.` 的补齐方向在**左侧**：记录里的尾随
// 0x40 **不是**补齐，而是被存储的数据。`decode_text` 却按左对齐字段的
// 惯例无条件 `trim_end`：
//
//   rec = `40 C1 C2 40 40`（" AB  "）
//   decode      → Text(" AB")
//   encode      → 右对齐重新排 → `40 40 40 C1 C2`
//   roundtrip   → diff at byte 1
//
// 这直接违反 FIDELITY.md §1 的 L1（「对本项目支持的所有字段类型成立」，
// 例外只有 COMP-2 尾数）与 CB-B5 自己写下的不变量「decode → JSONL →
// encode 逐字节一致」。NATIONAL 字段同形（`PIC N(5) JUSTIFIED RIGHT` 的
// 尾随 `00 20` 同样被 trim）。
//
// 修法：JUSTIFIED RIGHT 字段不 trim 尾随填充；**全空白字段仍然给 `""`**
// （空值语义不变，且两种形态 encode 后字节相同，不影响 L1）。

///|
fn jr_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
fn jr_hex(bs : Bytes) -> String {
  let digits = b"0123456789abcdef"
  let sb = StringBuilder()
  for b in bs {
    let v = b.to_int()
    sb.write_char(digits[(v >> 4) & 0xF].to_int().unsafe_to_char())
    sb.write_char(digits[v & 0xF].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn jr_text_of(layout : RecordLayout, rec : Bytes) -> String raise {
  let row = decode_record(layout, rec).unwrap()
  match row.get("R.A") {
    Some(Text(s)) => s
    _ => fail("R.A must decode to Text")
  }
}

///|
test "justified-right keeps trailing spaces (L1)" {
  let layout = jr_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let rec = b"\x40\xC1\xC2\x40\x40"
  // 尾随 0x40 是数据：既不能丢，也不能让 encode 把它搬到左边
  assert_eq(jr_text_of(layout, rec), " AB  ")
  let row = decode_record(layout, rec).unwrap()
  assert_eq(jr_hex(encode_record(layout, row).unwrap()), "40c1c24040")
  match roundtrip_check(layout, rec) {
    Ok(None) => ()
    Ok(Some(at)) => fail("roundtrip mismatch at byte \{at}")
    Err(e) => fail("roundtrip error: \{e.to_display()}")
  }
}

///|
test "justified-right jsonl edge keeps trailing spaces (L1)" {
  let layout = jr_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let rec = b"\x40\xC1\xC2\x40\x40"
  let row = decode_record(layout, rec).unwrap()
  let jsonl = render_jsonl(layout, [row])
  assert_true(jsonl.contains("\"R.A\":\" AB  \""))
  let back = parse_jsonl_row(layout, jsonl).unwrap()
  assert_eq(jr_hex(encode_record(layout, back).unwrap()), "40c1c24040")
}

///|
test "justified-right canonical form still byte identical" {
  let layout = jr_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let canonical = b"\x40\x40\x40\xC1\xC2"
  assert_eq(jr_text_of(layout, canonical), "   AB")
  let row = decode_record(layout, canonical).unwrap()
  assert_eq(jr_hex(encode_record(layout, row).unwrap()), "404040c1c2")
}

///|
test "justified-right all blank stays the empty value" {
  let layout = jr_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let blank = b"\x40\x40\x40\x40\x40"
  // 全空白 ⇔ 没有值：JSONL 形态与左对齐字段一致
  assert_eq(jr_text_of(layout, blank), "")
  let row = decode_record(layout, blank).unwrap()
  assert_eq(jr_hex(encode_record(layout, row).unwrap()), "4040404040")
}

///|
test "left-justified text still trims trailing padding" {
  let layout = jr_layout("01 R.\n    05 A PIC X(5).\n")
  let rec = b"\xC1\xC2\x40\x40\x40"
  assert_eq(jr_text_of(layout, rec), "AB")
  // 左对齐字段的尾部 0x40 确实只是补齐：encode 会重新补，字节不变
  let row = decode_record(layout, rec).unwrap()
  assert_eq(jr_hex(encode_record(layout, row).unwrap()), "c1c2404040")
}

///|
test "justified-right national keeps trailing national spaces (L1)" {
  let layout = jr_layout("01 R.\n    05 A PIC N(5) JUSTIFIED RIGHT.\n")
  // "AB  " 的 UTF-16BE：0041 0042 0020 0020 0020
  let rec = b"\x00\x41\x00\x42\x00\x20\x00\x20\x00\x20"
  assert_eq(jr_text_of(layout, rec), "AB   ")
  let row = decode_record(layout, rec).unwrap()
  assert_eq(jr_hex(encode_record(layout, row).unwrap()), "00410042002000200020")
  match roundtrip_check(layout, rec) {
    Ok(None) => ()
    Ok(Some(at)) => fail("national roundtrip mismatch at byte \{at}")
    Err(e) => fail("national roundtrip error: \{e.to_display()}")
  }
}
