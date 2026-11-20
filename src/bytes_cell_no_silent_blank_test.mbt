// 字符字段拿到 `Bytes` 单元格：报错，不静默写空白（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `as_text` 的 `Bytes(_) => ""` 让字符类字段把"原始字节单元格"默默写成整段
// 0x40（EBCDIC 空格）：
//
//   row{"R.A": Bytes(...)} + `PIC X(3)` → encode_record = Ok(`40 40 40`), exit 0
//
// 同一个 `Bytes` 喂给数值字段会报错（`as_number` 没有这条 coercion），
// 于是"字符字段丢数据、数值字段报错"—— 与项目「不静默修正」的口径矛盾。
// `Bytes` 是解码器挂在 `__record_bytes` / `__tail_hex` / `__filler_hex`
// 旁路键上的载体（见 FIDELITY），不是字段值。
//
// 修法：`as_text` 返回 `Result`，`Bytes` → `TextNotEncodable`；其它既有
// coercion（`Int` / `Decimal` / `Float` / `Bool` / `Null`）逐字不变。

///|
fn bytes_cell_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
fn bytes_cell_encode(
  layout : RecordLayout,
  path : String,
  raw : Bytes,
) -> Result[Bytes, DecodeError] {
  let row : Map[String, CellValue] = Map([])
  row[path] = Bytes(raw)
  encode_record(layout, row)
}

///|
test "text field rejects a raw Bytes cell instead of writing blanks" {
  let layout = bytes_cell_layout("01 R.\n    05 A PIC X(3).\n")
  match bytes_cell_encode(layout, "R.A", b"\xC1\xC2\xC3") {
    Ok(bs) => fail("must reject, wrote \{bs.length()} blank byte(s)")
    Err(TextNotEncodable(_, detail)) => {
      // 报错要点名字段，并说明 Bytes 是旁路键的载体
      assert_true(detail.contains("R.A"))
      assert_true(detail.contains("Bytes"))
    }
    Err(other) => fail("wrong error: \{other.to_display()}")
  }
}

///|
test "national field rejects a raw Bytes cell" {
  let layout = bytes_cell_layout("01 R.\n    05 A PIC N(2).\n")
  match bytes_cell_encode(layout, "R.A", b"\x00\x41") {
    Ok(_) => fail("NATIONAL must reject a Bytes cell")
    Err(_) => ()
  }
}

///|
test "edited field rejects a raw Bytes cell" {
  let layout = bytes_cell_layout("01 R.\n    05 A PIC ZZ9.99.\n")
  match bytes_cell_encode(layout, "R.A", b"\xF1") {
    Ok(_) => fail("edited field must reject a Bytes cell")
    Err(_) => ()
  }
}

///|
test "other cell coercions for text fields are unchanged" {
  let layout = bytes_cell_layout("01 R.\n    05 A PIC X(6).\n")
  let cases : Array[(CellValue, String)] = [
    (Int(42), "42"),
    (Decimal(Decimal::from_parts(1234L, 2, false)), "12.34"),
    (Bool(true), "true"),
    (Null, ""),
  ]
  for (value, want) in cases {
    let row : Map[String, CellValue] = Map([])
    row["R.A"] = value
    let row_back = decode_record(layout, encode_record(layout, row).unwrap()).unwrap()
    assert_eq(row_back.get("R.A").unwrap().to_display(), want)
  }
}

///|
test "raw Bytes still display as hex (display path untouched)" {
  let layout = bytes_cell_layout("01 R.\n    05 A PIC X(3).\n")
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Bytes(b"\xC1\xC2")
  assert_eq(
    render_table(layout, [row]).contains("c1 c2") ||
    render_table(layout, [row]).contains("C1 C2"),
    true,
  )
}
