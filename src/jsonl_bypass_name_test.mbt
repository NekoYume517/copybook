// CB-5（2026-11-08 审计）：__nibbles / __float_hex 旁路键只认完整路径，
// 与字段值查询的「路径优先、裸名后备」宽容度不一致。
//
// ## 缺陷形态（修复前）
//
// 字段值查询（parse_jsonl_row 开头）是 obj.get(field.path) 失败后回退
// obj.get(field.name)；旁路键查询（__nibbles / __float_hex）只查
// field.path。于是手写
//
//     {"R.N":25,"__nibbles":{"N":{"sign":13}}}
//
// 时旁路静默失效：编辑检测不触发，S9 字段被编成默认 F 区号
// （F0 F2 F5，期望路径键形态的 F0 F2 C5）。decode 导出恒为路径键，
// 仅手写构造触发，严重性低，但同一函数两种键宽容度不一致没有理由。
//
// ## 修复
//
// 旁路键查询加同款裸名后备：先按 field.path，失败回退 field.name。
// 与字段值查询完全对齐。

///|
fn cb5_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  N  PIC S9(3).\n"))
}

///|
test "CB-5: __nibbles 裸名键与路径键行为一致（正号）" {
  let layout = cb5_layout()
  // 路径键：未编辑（文本正、半字节正）→ C
  let by_path = parse_jsonl_row(
    layout, "{\"R.N\":25,\"__nibbles\":{\"R.N\":{\"sign\":12}}}",
  ).unwrap()
  assert_eq(encode_record(layout, by_path).unwrap()[2].to_int(), 0xC5)
  // 裸名键：同款语义（修复前 F0 F2 F5，sign 被静默丢弃）
  let by_name = parse_jsonl_row(
    layout, "{\"R.N\":25,\"__nibbles\":{\"N\":{\"sign\":12}}}",
  ).unwrap()
  assert_eq(encode_record(layout, by_name).unwrap()[2].to_int(), 0xC5)
}

///|
test "CB-5: __nibbles 裸名键的编辑检测同样生效" {
  let layout = cb5_layout()
  // 裸名键 + 编辑（文本正、半字节 0xD）→ 编辑优先，正号 C
  let edited = parse_jsonl_row(
    layout, "{\"R.N\":25,\"__nibbles\":{\"N\":{\"sign\":13}}}",
  ).unwrap()
  assert_eq(encode_record(layout, edited).unwrap()[2].to_int(), 0xC5)
}

///|
test "CB-5: __nibbles 裸名与路径同时出现时路径优先" {
  let layout = cb5_layout()
  // 路径 D + 裸名 C：按路径键的 0xD 走（文本负）→ D
  let both = parse_jsonl_row(
    layout, "{\"R.N\":-25,\"__nibbles\":{\"R.N\":{\"sign\":13},\"N\":{\"sign\":12}}}",
  ).unwrap()
  assert_eq(encode_record(layout, both).unwrap()[2].to_int(), 0xD5)
}
