// IEEE 754 模式的浮点保真回归（2026-11-04 对抗性审计 NEW-2）。
//
// ## 缺陷形态（修复前）
//
// `--float-mode ieee` 下的 `COMP-2` 走 `decode.mbt` 的 Ieee754 分支，那条分支
// **只产 `Float`，不挂 `FloatRaw` 原始字节旁路**。于是：
//
//   `decode` → `{"R.F":"NaN"}`（`output.mbt` 把 NaN 渲染成字符串）
//   `jsonl`  → `"NaN"` 解回规范 quiet NaN `0x7FF8000000000000`
//   `encode` → 按数值重编码
//
// 原始 `7F F8 00 00 00 00 00 01`（quiet NaN，带 52 位 payload）因此变成
// `FF F8 00 00 00 00 00 00`：**符号位翻转、payload 清零**，exit 0。
//
// 最刺眼的是同一份数据上两条路径自相矛盾：
//
//   `verify --float-mode ieee`  → `1 record(s) OK, byte-identical roundtrip`（exit 0）
//   `decode → JSONL → encode`   → 字节已变（exit 0）
//
// 内存路径（`verify`）用 reinterpret 保留全部位，文本路径（JSONL）丢光——
// 这正是 FIDELITY §1「L1 对所有支持的字段类型成立」被证伪的地方，也是
// 「verify 掩盖文本往返缺陷」这个形态的第三次复发（前两次是 CB-2 负零与
// AUD-3 浮点负零）。
//
// ## 修复方向
//
// NaN/Inf 的符号位与 payload 是**位级身份**的一部分，`Double` 能承载
// （binary64 的 NaN payload 有 52 位）。JSON 数字没有地方放它们，所以按
// CB-21 的既有手法挂原始字节旁路：`FloatRaw(f, raw)` + `__float_hex`，
// encode 优先写回原字节。只在非有限值上挂旁路，普通有限值仍走 `Float`，
// 普通记录的 JSONL 输出保持不变。

///|
fn ieee_layout() -> RecordLayout raise ParseError {
  compile_layout_with_float_mode(
    parse_copybook("01  R.\n    05  F   COMP-2.\n"),
    Ieee754,
  )
}

///|
fn ieee_layout1() -> RecordLayout raise ParseError {
  compile_layout_with_float_mode(
    parse_copybook("01  R.\n    05  F   COMP-1.\n"),
    Ieee754,
  )
}

///|
test "NEW-2: IEEE 模式的 NaN 必须保住符号位与 payload（COMP-2）" {
  let layout = ieee_layout()
  // quiet NaN 带 payload：0x7FF8000000000001
  let rec : Bytes = b"\x7F\xF8\x00\x00\x00\x00\x00\x01"
  let values = decode_record(layout, rec).unwrap()
  match values.get("R.F") {
    Some(FloatRaw(_, raw)) => {
      inspect(raw.length(), content="8")
      assert_eq(raw[0].to_int(), 0x7F)
      assert_eq(raw[7].to_int(), 0x01)
    }
    Some(Float(_)) =>
      fail("IEEE NaN must carry FloatRaw so the payload survives JSONL")
    _ => fail("expected a float cell, got something else")
  }
  // 内存路径（本来是对的，锁定它不许回退）
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
  // 文本路径：必须逐字节还原
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  assert_true(jsonl.contains("__float_hex"))
  let line = jsonl.trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let encoded = encode_record(layout, rowmap).unwrap()
  assert_eq(encoded[0].to_int(), 0x7F)
  assert_eq(encoded[7].to_int(), 0x01)
}

///|
test "NEW-2: IEEE 模式的负 NaN 与负无穷保住符号位（COMP-2）" {
  let layout = ieee_layout()
  // -NaN
  let neg_nan : Bytes = b"\xFF\xF8\x00\x00\x00\x00\x00\x00"
  let rows = decode_records(layout, neg_nan, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0xFF)
  // -Infinity
  let neg_inf : Bytes = b"\xFF\xF0\x00\x00\x00\x00\x00\x00"
  let rows2 = decode_records(layout, neg_inf, layout.byte_length).unwrap()
  let line2 = render_jsonl(layout, rows2).trim_end().to_string()
  let rowmap2 = parse_jsonl_row(layout, line2).unwrap()
  let out2 = encode_record(layout, rowmap2).unwrap()
  assert_eq(out2[0].to_int(), 0xFF)
  assert_eq(out2[1].to_int(), 0xF0)
}

///|
test "NEW-2: IEEE 模式的普通有限值不受影响，不写旁路键" {
  let layout = ieee_layout()
  // 1.0 = 0x3FF0000000000000
  let rec : Bytes = b"\x3F\xF0\x00\x00\x00\x00\x00\x00"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  assert_false(jsonl.contains("__float_hex"))
  let line = jsonl.trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0x3F)
  assert_eq(out[1].to_int(), 0xF0)
}

///|
test "NEW-2: IEEE 模式的 COMP-1 NaN 同样保住位模式" {
  let layout = ieee_layout1()
  // binary32 quiet NaN 带 payload：0x7FC00001
  let rec : Bytes = b"\x7F\xC0\x00\x01"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let line = render_jsonl(layout, rows).trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let out = encode_record(layout, rowmap).unwrap()
  assert_eq(out[0].to_int(), 0x7F)
  assert_eq(out[1].to_int(), 0xC0)
  assert_eq(out[3].to_int(), 0x01)
}
