// CB-18 回归：COMP 的十进制容量校验必须**两侧对称**（drivers: 
// docs/implementation.md §9「decode 与 encode 必须对称强制」）。
//
// 复现（修复前）：`PIC S9(18) COMP` 的 8 字节容器能表示 -2^63，但字段语义
// 只有 18 位十进制数。decode_binary 取绝对值时 |-2^63| 在 Int64 里回绕成
// 负数，于是 `raw >= dec_limit` 恒假、越过容量检查：
//   decode 80 00 00 00 00 00 00 00  ->  {"R.N":-9223372036854775808}  exit 0
//   verify 同一份数据 ->  invalid numeric ... exceeds 18 decimal digits   exit 1
// 正数侧正确：7F FF FF FF FF FF FF FF 被拒。
//
// 合法边界必须仍然可用：-999999999999999999 .. 999999999999999999。

///|
fn comp18_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 N PIC S9(18) COMP.\n"))
}

///|
test "S9(18) COMP rejects -2^63 (out of declared 18 digits) (CB-18)" {
  let layout = comp18_layout()
  inspect(layout.byte_length, content="8")
  // 1000...0 = 2^63，即 Int64 的最小值
  let rec = bs([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  match decode_record(layout, rec) {
    Ok(_) => fail("decode must reject -2^63 for PIC S9(18) COMP")
    Err(e) => assert_true(e.to_display().contains("exceeds 18 decimal digits"))
  }
  // 两条路径必须一致：verify 也拒绝
  match roundtrip_check(layout, rec) {
    Ok(_) => fail("roundtrip must reject -2^63 as well")
    Err(_) => ()
  }
}

///|
test "S9(18) COMP still accepts the legal boundaries (CB-18)" {
  let layout = comp18_layout()
  // 999999999999999999 = 0x0DE0B6B3A763FFFF
  let max_pos = bs([0x0D, 0xE0, 0xB6, 0xB3, 0xA7, 0x63, 0xFF, 0xFF])
  match decode_record(layout, max_pos) {
    Ok(m) =>
      match m.get("R.N") {
        Some(Decimal(d)) => inspect(d.to_string(), content="999999999999999999")
        _ => fail("R.N must be a Decimal")
      }
    Err(e) => fail("legal max must decode: \{e.to_display()}")
  }
  // -999999999999999999 = 0xF21F494C589C0001（补码）
  let max_neg = bs([0xF2, 0x1F, 0x49, 0x4C, 0x58, 0x9C, 0x00, 0x01])
  match decode_record(layout, max_neg) {
    Ok(m) =>
      match m.get("R.N") {
        Some(Decimal(d)) =>
          inspect(d.to_string(), content="-999999999999999999")
        _ => fail("R.N must be a Decimal")
      }
    Err(e) => fail("legal min must decode: \{e.to_display()}")
  }
  // 双向：合法值 encode 后逐字节还原
  for rec in [max_pos, max_neg] {
    let text = render_jsonl(layout, [decode_record(layout, rec).unwrap()])
    assert_eq(
      encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
      rec,
    )
  }
}

///|
test "S9(18) COMP positive overflow is still rejected (CB-18 guard)" {
  let layout = comp18_layout()
  // 2^63-1 = 19 位，超出 PIC 声明
  let rec = bs([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
  match decode_record(layout, rec) {
    Ok(_) => fail("decode must reject 2^63-1 for PIC S9(18) COMP")
    Err(e) => assert_true(e.to_display().contains("exceeds 18 decimal digits"))
  }
}

///|
test "S9(9) COMP negative capacity bound is enforced too (CB-18)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 N PIC S9(9) COMP.\n"))
  inspect(layout.byte_length, content="4")
  // -2147483648（10 位）超出 S9(9) 的 9 位声明
  let rec = bs([0x80, 0x00, 0x00, 0x00])
  match decode_record(layout, rec) {
    Ok(_) => fail("decode must reject -2147483648 for PIC S9(9) COMP")
    Err(e) => assert_true(e.to_display().contains("exceeds 9 decimal digits"))
  }
  // 合法边界 -999999999 仍可解（0xC4653601）
  let ok = bs([0xC4, 0x65, 0x36, 0x01])
  match decode_record(layout, ok) {
    Ok(m) =>
      match m.get("R.N") {
        Some(Decimal(d)) => inspect(d.to_string(), content="-999999999")
        _ => fail("R.N must be a Decimal")
      }
    Err(e) => fail("legal min must decode: \{e.to_display()}")
  }
}
