// 审计回归（2026-11-15）：`__nibbles` 的 sign=13（D，负号）落在**无符号**
// 数值字段上被静默接受 —— 而无符号字段的 decode 恒拒 D
// （decode_zoned / decode_packed 的 unsigned 分支直接报 InvalidNumeric），
// 所以它永远不是 decode 的输出。两条下游行为都不对：
//   - 无符号 zoned：encode 的「-0 归零」分支把 D 静默翻回 F —— 旁路
//     声明的字节事实被吞掉，exit 0；
//   - 无符号 COMP-3：直接写出 `00 0D`，这份字节被 decode 自己拒收
//     （verify exit 1）—— encode 的输出脱离了 decode 可能的输出集合。
//
// CB-A3（2026-11-10）已把 sign 限到 C/D/F，理由正是「decode 只写这些」；
// 同一论证在字段维度上同样成立：D 只可能出现在带符号字段上
// （PIC 9 / 无符号 COMP-3 的合法符号半字节只有 C 与 F）。
// 修复：parse_jsonl_row 在 nibble 绑定到字段时校验
// sign=13 => field.pic.signed，报错样式与 CB-A3 的 pad 检查一致。

///|
fn su_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01 R.\n  05 Z PIC 9(3).\n  05 P PIC 9(3) COMP-3.\n"),
  )
}

///|
fn su_encode(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = su_layout()
  match parse_jsonl_row(layout, line) {
    Err(e) => Err(e)
    Ok(row) =>
      match encode_record(layout, row) {
        Err(e) => Err(e.to_display())
        Ok(b) => Ok(b)
      }
  }
}

///|
test "sign 13 on an unsigned zoned field must be rejected" {
  match su_encode("{\"R.Z\":null,\"__nibbles\":{\"R.Z\":{\"sign\":13}}}") {
    Err(e) => {
      assert_true(e.contains("R.Z"))
      assert_true(e.contains("13"))
      assert_true(e.contains("unsigned"))
    }
    Ok(b) =>
      fail(
        "sign 13 on an unsigned zoned field must not encode, got \{b.length()} byte(s)",
      )
  }
}

///|
test "sign 13 on an unsigned COMP-3 field must be rejected" {
  // 修复前：写出 00 0D —— decode 自己报 "unsigned packed decimal has
  // negative sign"，encode 的输出脱离 decode 可能的输出集合
  match su_encode("{\"R.P\":null,\"__nibbles\":{\"R.P\":{\"sign\":13}}}") {
    Err(e) => {
      assert_true(e.contains("R.P"))
      assert_true(e.contains("unsigned"))
    }
    Ok(_) => fail("sign 13 on an unsigned COMP-3 field must not encode")
  }
}

///|
test "sign 13 with an explicit text value on an unsigned field is also rejected" {
  // RJ-3a 的「编辑生效」路径同样不应收下：整条旁路条目都不可能是
  // decode 的输出（无符号字段 decode 恒拒 D）
  match su_encode("{\"R.Z\":\"5\",\"__nibbles\":{\"R.Z\":{\"sign\":13}}}") {
    Err(e) => assert_true(e.contains("unsigned"))
    Ok(_) =>
      fail("sign 13 on an unsigned field must be rejected even with a value")
  }
}

///|
test "sign 12 and 15 on unsigned fields still encode (decode can emit them)" {
  // P1-3：无符号 zoned 的 C 区号是 decode 的合法输出（同一份数据按 S9
  // 与 9 两种 copybook 解释）；F 是未符号化的默认形态
  match su_encode("{\"R.Z\":\"123\",\"__nibbles\":{\"R.Z\":{\"sign\":12}}}") {
    Err(e) => fail("sign 12 on an unsigned zoned field must encode: \{e}")
    Ok(b) => {
      assert_eq(b[0].to_int(), 0xF1)
      assert_eq(b[1].to_int(), 0xF2)
      assert_eq(b[2].to_int(), 0xC3)
    }
  }
  match su_encode("{\"R.P\":\"123\",\"__nibbles\":{\"R.P\":{\"sign\":15}}}") {
    Err(e) => fail("sign 15 on an unsigned COMP-3 field must encode: \{e}")
    Ok(b) => {
      assert_eq(b[3].to_int(), 0x12)
      assert_eq(b[4].to_int(), 0x3F)
    }
  }
}

///|
test "sign 13 on a signed field is untouched (CB-2 negative zero)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 N PIC S9(3).\n"))
  let parsed = parse_jsonl_row(
    layout, "{\"R.N\":null,\"__nibbles\":{\"R.N\":{\"sign\":13}}}",
  )
  match parsed {
    Err(e) => fail("sign 13 on a signed field must still encode: \{e}")
    Ok(row) =>
      match encode_record(layout, row) {
        Err(e) => fail("negative zero must encode: \{e.to_display()}")
        Ok(b) => {
          assert_eq(b[0].to_int(), 0xF0)
          assert_eq(b[1].to_int(), 0xF0)
          assert_eq(b[2].to_int(), 0xD0)
        }
      }
  }
}
