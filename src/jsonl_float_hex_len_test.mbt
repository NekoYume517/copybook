// CB-A1（2026-11-10 审计）：__float_hex 字节数不符使 encode panic / 静默重编码。
//
// ## 缺陷形态（修复前）
//
// parse_jsonl_row 的一致性判定先把旁路 hex 累进 UInt64（`i < want && i <
// bs.length()` 防了越界），随后**无条件**调用 hfp_decode_long/short——这两个
// 函数固定读 8/4 字节：
//
//   - hex 比 4/8 字节短 → hfp 解码越界 → `index out of bounds` panic，
//     没有任何业务错误信息（五个退出码之外的第六态）
//   - hex 比 4/8 字节长 → 多余字节被静默截断，按截断值重编码 exit 0
//     （`4180000000000001` + 8 字节零尾 → 写出 `4180000000000000`）
//
// NEW-6 的承诺是「__ 旁路键损坏必须报错，没有误伤面」。decode 写出的
// __float_hex 恒为精确 4/8 字节，长度不对只可能是损坏或蓄意构造——
// 与「奇数长度 hex 必须报错」（jsonl_strictness_test）同一哲学，长度损坏
// 是漏网的同型。

///|
fn fhl_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01  R.\n    05  D  COMP-2.\n    05  F  COMP-1.\n"),
  )
}

///|
fn fhl_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = fhl_layout()
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
test "CB-A1: __float_hex 空 hex 报错而不是 panic（COMP-2）" {
  inspect(
    fhl_encode_line("{\"R.D\":8,\"__float_hex\":{\"R.D\":\"\"}}"),
    content="Err(__float_hex['R.D'] must be exactly 8 bytes for COMP-2, got 0)",
  )
}

///|
test "CB-A1: __float_hex 短 hex 报错（COMP-2 收到 4 字节）" {
  inspect(
    fhl_encode_line("{\"R.D\":8,\"__float_hex\":{\"R.D\":\"41800000\"}}"),
    content="Err(__float_hex['R.D'] must be exactly 8 bytes for COMP-2, got 4)",
  )
}

///|
test "CB-A1: __float_hex 超 8 字节报错而不是静默截断" {
  inspect(
    fhl_encode_line(
      "{\"R.D\":8,\"__float_hex\":{\"R.D\":\"41800000000000010000000000000000\"}}",
    ),
    content="Err(__float_hex['R.D'] must be exactly 8 bytes for COMP-2, got 16)",
  )
}

///|
test "CB-A1: __float_hex 短 hex 报错（COMP-1 收到 2 字节）" {
  inspect(
    fhl_encode_line("{\"R.F\":1.5,\"__float_hex\":{\"R.F\":\"4118\"}}"),
    content="Err(__float_hex['R.F'] must be exactly 4 bytes for COMP-1, got 2)",
  )
}

///|
test "CB-A1: 精确 8 字节的旁路仍正常生效（修复不伤正路径）" {
  // 文本 "8" 与 4180000000000001 解出的 double 相等（低 3 位在 53 位
  // double 里舍入到 8.0），一致性成立 → 旁路生效、原始字节原样写回。
  match
    fhl_encode_line(
      "{\"R.D\":8,\"__float_hex\":{\"R.D\":\"4180000000000001\"}}",
    ) {
    Err(e) => fail("consistent bypass must encode: \{e}")
    Ok(b) => {
      // encode_record 返回整条记录（COMP-2 8 字节 + COMP-1 4 字节 = 12），
      // 前 8 字节必须是旁路原始字节（R.F 未赋值，尾部任意默认填充）。
      let want = [0x41, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]
      assert_eq(b.length(), 12)
      for i in 0..<8 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}
