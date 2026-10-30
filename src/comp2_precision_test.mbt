// CB-21 回归：IBM HFP `COMP-2` 的 56 位尾数 vs `Double` 的 53 位。
//
// 驳回意见指出「所有支持类型逐字节往返」与「COMP-2 转 Double 丢精度」
// 自相矛盾。本测试锁定修复后的契约：
//
//   1. 尾数低 3 位非零 => decode 产出 `FloatRaw`（带原始字节），
//      encode 原样写回，`roundtrip_check` 必须返回 None（字节恒等）；
//   2. 尾数低 3 位全零 => 产出普通 `Float`（`Double` 能精确承载），
//      JSONL 不写 `__float_hex`，普通记录输出不变。
//
// 关键样本 `41 80 00 00 00 00 00 01`：F = 2^55 + 1，56 位有效，
// 低 3 位是 001 —— `Double` 存不下，修复前 decode 得 `8`，
// 重编码写回 `...00`，`verify` 报 byte mismatch / exit 1。

///|
fn comp2_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  D   PIC 9(3) COMP-2.\n"))
}

///|
test "CB-21: COMP-2 尾数超 Double 精度时挂原始字节，往返字节恒等" {
  let layout = comp2_layout()
  // F = 2^55 + 1：56 位尾数，低 3 位 = 001（不可丢）
  let rec : Bytes = b"\x41\x80\x00\x00\x00\x00\x00\x01"
  let values = decode_record(layout, rec).unwrap()
  match values.get("R.D") {
    Some(FloatRaw(f, raw)) => {
      // 数值本身是近似（8.0），但原始字节必须完整保存
      assert_eq(f, 8.0)
      inspect(raw.length(), content="8")
      assert_eq(raw[7].to_int(), 1)
    }
    Some(Float(_)) =>
      fail("expected FloatRaw for lossy COMP-2, got plain Float")
    _ => fail("expected FloatRaw for lossy COMP-2")
  }
  // 内存路径往返：必须字节恒等
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
  // encode 必须原样写回
  let encoded = encode_record(layout, values).unwrap()
  assert_eq(encoded[7].to_int(), 1)
}

///|
test "CB-21: COMP-2 尾数低 3 位为零时不挂旁路，契约不变" {
  let layout = comp2_layout()
  // F = 2^52：53 位以内可精确表示
  let rec : Bytes = b"\x41\x10\x00\x00\x00\x00\x00\x00"
  let values = decode_record(layout, rec).unwrap()
  match values.get("R.D") {
    Some(Float(f)) => assert_eq(f, 1.0)
    Some(FloatRaw(_, _)) =>
      fail("exactly-representable COMP-2 must stay plain Float")
    _ => fail("expected Float")
  }
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
}

///|
test "CB-21: JSONL 经 __float_hex 旁路保住 COMP-2 原始字节" {
  let layout = comp2_layout()
  let rec : Bytes = b"\x41\x80\x00\x00\x00\x00\x00\x01"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  // 旁路键必须以原始字节出现
  assert_true(jsonl.contains("__float_hex"))
  assert_true(jsonl.contains("4180000000000001"))
  // 走真实文本路径：解析回来再编码，字节必须一致
  let line = jsonl.trim_end().to_string()
  let rowmap = parse_jsonl_row(layout, line).unwrap()
  let encoded = encode_record(layout, rowmap).unwrap()
  inspect(encoded.length(), content="8")
  assert_eq(encoded[7].to_int(), 1)
  assert_eq(encoded[0].to_int(), 0x41)
}

///|
test "CB-21: 可精确表示的 COMP-2 不写 __float_hex，普通输出不变" {
  let layout = comp2_layout()
  let rec : Bytes = b"\x41\x10\x00\x00\x00\x00\x00\x00"
  let rows = decode_records(layout, rec, layout.byte_length).unwrap()
  let jsonl = render_jsonl(layout, rows)
  assert_false(jsonl.contains("__float_hex"))
}
