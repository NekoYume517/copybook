// 组委会验收意见（2026-11-06）的回归：JSONL 编辑必须生效（RJ-3a/3b）。
//
// ## 缺陷形态（修复前）
//
// `decode → 编辑 JSONL → encode` 这条**编辑工作流**被自己的旁路键打穿：
//
//   3a. `{"R.N":25,"__nibbles":{"R.N":{"sign":13}}}`（原值 -25 改成 +25）
//       → encode 仍写 `F0 F2 D5`（负号）—— **改正数仍写负数**。
//       根因：`negative = d.negative || sn == Some(0xD)` 让陈旧符号半字节
//       无条件压过用户编辑。
//   3b. `{"R.D":9,"__float_hex":{"R.D":"4180000000000001"}}`（8.0+ulp 改成 9）
//       → encode 写回 `41 80 …01` —— **浮点修改不生效**。
//       根因：原始字节无条件压过编辑后的数值。
//
// 两者同族：旁路键是 decode 时的**快照**，用户带着它编辑值是正常用法
// （文本编辑器不会动到行尾的旁路键），快照必须让位于编辑 —— 与 CB-16
// 在视图通道上的「值感知」教训同族。
//
// ## 修复
//
//   - `__nibbles`：符号半字节 0xD 与文本正号（非零系数）矛盾时判为编辑，
//     按文本值编码，正号给 0xC；一致时保持原行为（CB-2 负零豁免不变）。
//   - `__float_hex`：旁路字节按 **decode 同款解释**（HFP 字节走
//     `hfp_decode_*`，IEEE 字节按位模式 reinterpret）得到的值与文本值
//     相等才生效；NaN/±Inf 的文本形态（"NaN"/"Infinity"）一致即生效。
//     不一致 = 用户编辑，按文本值编码。

///|
fn sgn_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  N  PIC S9(3).\n"))
}

///|
fn comp2_layout_rj() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  D  COMP-2.\n"))
}

///|
test "RJ-3a: 编辑后的正数不再写负号（C 区号）" {
  let layout = sgn_layout()
  // 原值 -25（F0 F2 D5），用户改成 +25，行尾的 __nibbles 是旧快照
  let line = "{\"R.N\":25,\"__nibbles\":{\"R.N\":{\"sign\":13}}}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  // 修复前：F0 F2 D5（改正数仍写负数）
  assert_eq(out[0].to_int(), 0xF0)
  assert_eq(out[1].to_int(), 0xF2)
  assert_eq(out[2].to_int(), 0xC5)
}

///|
test "RJ-3a: 未编辑的负数保持原样（旁路一致性不被破坏）" {
  let layout = sgn_layout()
  // decode 的原样输出：文本 -25 与符号半字节 0xD 一致
  let line = "{\"R.N\":-25,\"__nibbles\":{\"R.N\":{\"sign\":13}}}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[2].to_int(), 0xD5)
}

///|
test "RJ-3a: 负零豁免不被编辑检测误伤（CB-2 保持）" {
  let layout = sgn_layout()
  // 文本 "-0" + 半字节 0xD：系数为 0，符号半字节是唯一符号载体
  let line = "{\"R.N\":-0,\"__nibbles\":{\"R.N\":{\"sign\":13}}}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[2].to_int(), 0xD0)
  // 文本 "0"（JSON 词法把 -0 的负号吞掉后的形态）+ 0xD 同样豁免
  let line2 = "{\"R.N\":0,\"__nibbles\":{\"R.N\":{\"sign\":13}}}"
  let rowmap2 = parse_jsonl_row(layout, line2).unwrap()
  let out2 = encode_record(layout, rowmap2).unwrap()
  assert_eq(out2[2].to_int(), 0xD0)
}

///|
test "RJ-3b: 编辑后的浮点值生效（不被旧 __float_hex 覆盖）" {
  let layout = comp2_layout_rj()
  // 原值 41 80 00 00 00 00 00 01（8.0+ulp），用户改成 9
  let line = "{\"R.D\":9,\"__float_hex\":{\"R.D\":\"4180000000000001\"}}"
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  // 9.0 = 41 90 00 00 00 00 00 00；修复前是 41 80 …01（编辑不生效）
  assert_eq(out[0].to_int(), 0x41)
  assert_eq(out[1].to_int(), 0x90)
  assert_eq(out[7].to_int(), 0x00)
}

///|
test "RJ-3b: 未编辑的超精度值仍逐字节还原（CB-21 不回退）" {
  let layout = comp2_layout_rj()
  let rec = bs([0x41, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0x41)
  assert_eq(out[7].to_int(), 0x01)
}

///|
test "RJ-3b: IEEE NaN 的旁路在值感知下仍生效" {
  // decode 写 {"R.F":"NaN","__float_hex":…}；文本 "NaN" 与旁路字节的
  // 非有限性一致 → 旁路生效，payload 保真（NEW-2 不回退）
  let layout = compile_layout_with_float_mode(
    parse_copybook("01  R.\n    05  F  COMP-2.\n"),
    Ieee754,
  )
  let rec = bs([0x7F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0x7F)
  assert_eq(out[7].to_int(), 0x01)
}

///|
test "RJ-3b: 编辑成另一个有限值后 payload 不再保留" {
  // 把 NaN 编辑成 5：旁路字节（NaN）与文本（5.0）不一致 → 按值编码。
  // "编辑 NaN 成有限数"是合法修复动作，旧 payload 理应消失。
  let layout = compile_layout_with_float_mode(
    parse_copybook("01  R.\n    05  F  COMP-2.\n"),
    Ieee754,
  )
  let rec = bs([0x7F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  // 编辑：NaN → 5
  let edited = line.replace(old="\"NaN\"", new="5")
  let rowmap = parse_jsonl_row(layout, edited).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  // 5.0 = 0x4014000000000000
  assert_eq(out[0].to_int(), 0x40)
  assert_eq(out[1].to_int(), 0x14)
}
