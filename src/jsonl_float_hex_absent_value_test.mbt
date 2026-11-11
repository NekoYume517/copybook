// 审计回归（2026-11-12）：`__float_hex` 没有配套字段值时按 `0.0` 处理。
//
// ## 缺陷形态（HANDOVER 16.5 遗留第 4 条，本轮确认仍成立）
//
// 只有旁路键、没有字段值的行（手写 JSONL 的常见形态）：
//
//     {"__float_hex":{"R.D":"4180000000000001"}}
//     {"R.D":null,"__float_hex":{"R.D":"4180000000000001"}}
//
// `parse_jsonl_row` 取字段文本时用 `_ => ""` 兜底，`parse_double("")` 抛异常后
// 又被 `_ => 0.0` 兜住，于是「旁路字节解出的值」与「0.0」比较 → 不一致 →
// 判定成「用户把值编辑成了 0」，`__float_hex` 被当作过时快照丢弃。
// 结果：`encode` 写出一整片 0x00（COMP-2 的 0.0），退出码 0、零提示。
//
// decode 从不产出这种行（有 `__float_hex` 必有值），所以这是手写/程序生成的
// 行；而它声明的**字节事实**被静默换成 0.0，正是「绝不静默修正」要拒绝的形态。
//
// ## 判据
//
// 旁路键是字节层的真值。**没有值 = 没有竞争的编辑**，此时按声明的字节原样写回
// （与 `__tail_hex` / `__filler_hex` 无条件还原同一规则）；有值时仍走既有的
// 「值感知」判定（值一致 → 保留旁路；值被编辑 → 编辑生效）。

///|
fn fharn_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01  R.\n    05  D  COMP-2.\n    05  F  COMP-1.\n"),
  )
}

///|
fn fharn_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = fharn_layout()
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
test "__float_hex without a field value restores the declared bytes (COMP-2)" {
  // 没有 "R.D" 键：旁路声明的 8 字节就是唯一已知事实
  match fharn_encode_line("{\"__float_hex\":{\"R.D\":\"4180000000000001\"}}") {
    Err(e) => fail("bypass-only row must encode: \{e}")
    Ok(b) => {
      let want = [0x41, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]
      assert_eq(b.length(), 12)
      for i in 0..<8 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}

///|
test "__float_hex with an explicit null value restores the declared bytes (COMP-1)" {
  // COMP-1 的 1.5 = 41 18 00 00
  match
    fharn_encode_line("{\"R.F\":null,\"__float_hex\":{\"R.F\":\"41180000\"}}") {
    Err(e) => fail("null value + bypass must encode: \{e}")
    Ok(b) => {
      // R.D 在前（8 字节未赋值 → 0.0），R.F 在偏移 8
      assert_eq(b.length(), 12)
      let want = [0x41, 0x18, 0x00, 0x00]
      for i in 0..<4 {
        assert_eq(b[8 + i].to_int(), want[i])
      }
    }
  }
}

///|
test "__float_hex restores bytes through the bare-name fallback too" {
  // CB-5 的裸名回退：手写行可以用裸字段名
  match fharn_encode_line("{\"__float_hex\":{\"D\":\"4180000000000001\"}}") {
    Err(e) => fail("bare-name bypass must encode: \{e}")
    Ok(b) => assert_eq(b[7].to_int(), 0x01)
  }
}

///|
test "__float_hex still loses to an edited value (no regression on RJ-3b)" {
  // 值 9 与旁路字节解出的 8.0 不一致 → 编辑生效，按 9 编码
  match
    fharn_encode_line(
      "{\"R.D\":9,\"__float_hex\":{\"R.D\":\"4180000000000001\"}}",
    ) {
    Err(e) => fail("edited value must encode: \{e}")
    Ok(b) => {
      // 9.0 的 HFP COMP-2 = 41 90 00 00 00 00 00 00（0.5625 * 16^1，阶码 65）
      let want = [0x41, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
      for i in 0..<8 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}
