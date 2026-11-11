// 审计回归（2026-11-11）：numeric-edited 的存储宽度把 V / P 算进了字符位置。
//
// IBM Enterprise COBOL「Symbols used in the PICTURE clause」：
//   - V：Not counted in the size of the elementary item.
//   - P：Not counted in the size of the data item.
//   - S：Not counted ... unless SIGN SEPARATE.
//
// 布局层对 `Edited` 类别直接用 `pic_storage_len(pic_text)`（展开后的字符数），
// 于是 `PIC ZZ9V99`（应 5 字节）被算成 6、`PIC ZZ9PP`（应 3）被算成 5。
// 这类字段后面的每个字段都整体错位 —— 不是报告错，是**解码错位**。

///|
fn ew_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
test "edited width: V is not a character position" {
  let layout = ew_layout("01 R.\n  05 A PIC ZZ9V99.\n  05 B PIC X(1).\n")
  inspect(layout.find("R.A").unwrap().byte_length, content="5")
  inspect(layout.find("R.B").unwrap().offset, content="5")
  inspect(layout.byte_length, content="6")
}

///|
test "edited width: currency + V" {
  let layout = ew_layout("01 R.\n  05 A PIC $9,999V99.\n  05 B PIC X(1).\n")
  // $ 9 , 9 9 9 9 9 = 8 个字符位置（V 不占）
  inspect(layout.find("R.A").unwrap().byte_length, content="8")
  inspect(layout.find("R.B").unwrap().offset, content="8")
}

///|
test "edited width: P is not a character position" {
  let layout = ew_layout("01 R.\n  05 A PIC ZZ9PP.\n  05 B PIC X(1).\n")
  inspect(layout.find("R.A").unwrap().byte_length, content="3")
  inspect(layout.find("R.B").unwrap().offset, content="3")
}

///|
test "edited width: insertion characters still count" {
  let layout = ew_layout("01 R.\n  05 A PIC ZZ9.99.\n  05 B PIC X(1).\n")
  inspect(layout.find("R.A").unwrap().byte_length, content="6")
  let cr = ew_layout("01 R.\n  05 A PIC 9(5)CR.\n  05 B PIC X(1).\n")
  inspect(cr.find("R.A").unwrap().byte_length, content="7")
  let cur = ew_layout("01 R.\n  05 A PIC $9,999.99.\n  05 B PIC X(1).\n")
  inspect(cur.find("R.A").unwrap().byte_length, content="9")
}

///|
test "edited width: decode/encode follow the corrected offsets" {
  let layout = ew_layout("01 R.\n  05 A PIC ZZ9V99.\n  05 B PIC X(2).\n")
  // A 5 字节 "12345"，B 两字节 "XY"
  let rec = ebcdic_encode("12345XY")
  let row = decode_record(layout, rec).unwrap()
  match row.get("R.B") {
    Some(Text(s)) => inspect(s, content="XY")
    _ => fail("R.B must decode to Text")
  }
  assert_eq(encode_record(layout, row).unwrap(), rec)
}
