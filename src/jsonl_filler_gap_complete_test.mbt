// 2026-11-16：几何与字节一起截断不能绕过 FILLER 空洞完整性检查。
// 两个静态 FILLER 洞没有“编辑后新暴露”的来源；漏掉其中一个必须报错，
// 否则该洞从真实字节静默变成 Writer 初始的 0x40。

///|
fn fgc_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X.\n  05 FILLER PIC X.\n  05 B PIC X.\n  05 FILLER PIC X.\n  05 C PIC X.\n",
    ),
  )
}

///|
test "filler geometry omitting another static gap is rejected" {
  let layout = fgc_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.A\":\"A\",\"R.B\":\"B\",\"R.C\":\"C\",\"__filler_hex\":\"c3\",\"__filler_gap\":[[1,2]]}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("__filler_gap"))
    Ok(_) =>
      fail("truncated filler geometry must not silently blank the second gap")
  }
}

///|
test "complete geometry for two static filler gaps remains valid" {
  let layout = fgc_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.A\":\"A\",\"R.B\":\"B\",\"R.C\":\"C\",\"__filler_hex\":\"c3c7\",\"__filler_gap\":[[1,2],[3,4]]}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) => fail("complete filler geometry must encode: \{e.to_display()}")
    Ok(encoded) => assert_eq(encoded, b"\xC1\xC3\xC2\xC7\xC3")
  }
}
