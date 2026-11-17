// 2026-11-17 审计 C12：全 FILLER 布局的 `--format table` 输出空行、exit 0。
//
// ## 缺陷形态
//
// `01 R. 05 FILLER PIC X(4).` 是**合法**布局：`byte_length = 4`，但
// `layout.fields` 为空（FILLER 按布局契约不进 leaves）。JSONL 路径由
// `__filler_hex` 承载（`all_filler_test.mbt` 已锁），而表格路径直接返回空串
// （`render_table` 的 `if ncol == 0 { return "" }`），CLI 于是打印一个空行、
// exit 0：
//
//     copybook decode --copybook allfiller.cpy --data d.dat --format table
//     （空行）
//
// 表格是给人看的输出：空行与"没有记录 / 命令没生效"不可区分。这里保留 exit 0
// （布局合法、解码成功），但让输出可辨识。

///|
fn c12_all_filler_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01 R.\n  05 FILLER PIC X(2).\n  05 FILLER PIC X(2).\n"),
  )
}

///|
test "C12: an all-FILLER layout renders a recognisable table line" {
  let layout = c12_all_filler_layout()
  inspect(layout.byte_length, content="4")
  inspect(layout.fields.length(), content="0")
  let rows = decode_records(layout, b"\xF1\xF2\xF3\xF4", 4).unwrap()
  let text = render_table(layout, rows)
  // 红：修复前是空串
  assert_true(text.length() > 0)
  assert_true(text.contains("FILLER"))
  assert_true(text.contains("4"))
}

///|
test "C12: a layout with value fields is unaffected" {
  // 反向锁：正常布局的表格输出逐字符不变（output_test 已锁列宽，这里锁"非空
  // 且不含 FILLER 提示"）。
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
  let rows = decode_records(layout, b"\xC1\xC2", 2).unwrap()
  let text = render_table(layout, rows)
  assert_true(text.contains("A"))
  assert_eq(text.contains("FILLER"), false)
}
