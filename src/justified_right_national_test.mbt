// NATIONAL 字段的 JUSTIFIED RIGHT（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `PIC N(5) JUSTIFIED RIGHT` 在解析期被接受（`pic.justified_right = true`，
// 10 字节），但 encode 的 NATIONAL 分支只把文本从 offset 起顺序写出、尾部补
// `00 20` —— **完全不看对齐方向**：
//
//   Text("AB") → `0041 0042 0020 0020 0020`（左对齐）
//   IBM 语义   → `0020 0020 0020 0041 0042`（右对齐，左侧补 national space）
//
// 与 CB-B5 修 X(n) 时的缺陷同形（JUSTIFIED RIGHT 被静默忽略），只是入口从
// 单字节文本换成了 NATIONAL。IBM Enterprise COBOL 6.5.0 的 JUSTIFIED 子句
// 明确允许 category 为 national 的数据项，所以这不是"未支持语法"，而是
// 解析接受后的语义缺失。
//
// 逐字节往返（L1）在 #1 修好 decode 侧之后本来成立：值已填满宽度时 pad=0，
// 文本原样写回。这里锁的是**新建值**（L2）的落点。

///|
fn jr_national_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n    05 A PIC N(5) JUSTIFIED RIGHT.\n"))
}

///|
fn jr_encode_hex(layout : RecordLayout, v : CellValue) -> String raise {
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = v
  let bytes = match encode_record(layout, row) {
    Ok(bs) => bs
    Err(e) => fail("encode must succeed: \{e.to_display()}")
  }
  let digits = b"0123456789abcdef"
  let sb = StringBuilder()
  for b in bytes {
    let x = b.to_int()
    sb.write_char(digits[(x >> 4) & 0xF].to_int().unsafe_to_char())
    sb.write_char(digits[x & 0xF].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
test "national justified-right pads on the left with 00 20" {
  let layout = jr_national_layout()
  assert_eq(jr_encode_hex(layout, Text("AB")), "00200020002000410042")
}

///|
test "national justified-right keeps a full-width value in place" {
  let layout = jr_national_layout()
  // 恰好填满：不补 pad，文本原样落盘（decode 侧 #1 已保证这种形态往返）
  assert_eq(jr_encode_hex(layout, Text("ABCDE")), "00410042004300440045")
}

///|
test "national justified-right rejects over-capacity values" {
  let layout = jr_national_layout()
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("ABCDEF")
  match encode_record(layout, row) {
    Ok(_) => fail("over-capacity NATIONAL value must be rejected")
    Err(_) => ()
  }
}

///|
test "national left-justified (no JUSTIFIED clause) is unchanged" {
  let layout = compile_layout(parse_copybook("01 R.\n    05 A PIC N(5).\n"))
  assert_eq(jr_encode_hex(layout, Text("AB")), "00410042002000200020")
}

///|
test "national justified-right empty value is all national spaces" {
  let layout = jr_national_layout()
  assert_eq(jr_encode_hex(layout, Text("")), "00200020002000200020")
  assert_eq(jr_encode_hex(layout, Null), "00200020002000200020")
}
