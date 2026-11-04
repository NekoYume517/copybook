// 全 FILLER 记录的旁路回归（2026-11-04 对抗性审计 NEW-1）。
//
// ## 缺陷形态（修复前）
//
// ```cobol
// 01  R.
//     05  FILLER PIC X(2).
//     05  FILLER PIC X(2).
// ```
// 数据 `F1 F2 F3 F4`：
//
//     decode -> {}                        exit 0   （字节没有任何载体）
//     encode -> 40 40 40 40              exit 0   （全空格，原始字节丢失）
//     手工补 {"__filler_hex":"f1f2f3f4"} -> 40 40 40 40   也不生效
//
// 根因：`layout.fields` 为空（FILLER 按布局层契约不进 leaves），于是
// `primary_end_offset` 返回 0，`filler_gaps` 的空洞集为空 —— `__filler_hex`
// 永远不被消费。`verify` 能报 byte mismatch（exit 1），但 JSONL 工作流
// **无解**，与 FIDELITY §3「FILLER 区由 __filler_hex 承载」的承诺冲突。
//
// 这个形态是 CB-11（FILLER 中部空洞保真）没覆盖的：CB-11 修的是「有其它
// 字段时 FILLER 夹在中间」，而这里**整条记录全是 FILLER**，主视图上界为 0。
//
// ## 修复
//
// `filler_gaps` 的上界在 `layout.fields` 为空时回退到 `layout.byte_length`。
// 尾部空洞的上界 `byte_length - primary_end` 自然收缩为 0，两条旁路仍不
// 重叠（CB-15 的约束不受影响）。

///|
fn all_filler_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  FILLER PIC X(2).\n    05  FILLER PIC X(2).\n",
    ),
  )
}

///|
test "NEW-1: 全 FILLER 记录 decode 带出 __filler_hex" {
  let layout = all_filler_layout()
  inspect(layout.byte_length, content="4")
  inspect(layout.fields.length(), content="0")
  let rec : Bytes = b"\xF1\xF2\xF3\xF4"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  assert_true(jsonl.contains("__filler_hex"))
  assert_true(jsonl.contains("f1f2f3f4"))
}

///|
test "NEW-1: 全 FILLER 记录的端到端往返逐字节一致" {
  let layout = all_filler_layout()
  let rec : Bytes = b"\xF1\xF2\xF3\xF4"
  // 内存路径：本来就自洽（Writer 初值 + verify 比对），锁定不许回退
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
  // 文本路径：修复前这里会得到 40 40 40 40
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0xF1)
  assert_eq(out[3].to_int(), 0xF4)
}

///|
test "NEW-1: 手写的 __filler_hex 在全 FILLER 布局上也生效" {
  let layout = all_filler_layout()
  // 修复前这个键被完全忽略（空洞集为空，无处回填）。
  // 走真实文本入口（parse_jsonl_row 把 `__filler_hex` 还原成 Bytes 单元格），
  // 而不是手工塞 Text —— CLI 的路径就是这样。
  let line = "{\"__filler_hex\":\"f1f2f3f4\"}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0xF1)
  assert_eq(out[1].to_int(), 0xF2)
  assert_eq(out[2].to_int(), 0xF3)
  assert_eq(out[3].to_int(), 0xF4)
}

///|
test "NEW-1: 全 0x40 的 FILLER 记录不写旁路键（未赋值存储惯例）" {
  let layout = all_filler_layout()
  let rec : Bytes = b"\x40\x40\x40\x40"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  assert_false(jsonl.contains("__filler_hex"))
  // 往返仍然一致（全空格就是 Writer 的初值）
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
}
