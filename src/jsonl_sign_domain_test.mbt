// CB-A3（2026-11-10 审计）：__nibbles.sign 值域过宽 / pad 落在非 COMP-3
// 字段被静默忽略。
//
// ## 缺陷形态（修复前）
//
// parse 层 sign 接受整个 0..=15，但 decode 的 zoned/packed 侧只认
// C/D/F（其余区号本来就报 InvalidNumeric）——于是 sign=10（0xA）这类
// **decode 永远写不出来的值**被静默收下、落进 encode 默认分支丢掉符号
// （F1F2C3 的 sign 12 改成 10 → 写出 F1F2F3，exit 0）；sign=99 报错而
// sign=10 静默，同一损坏家族两种行为。
//
// pad 侧：非零 pad 只在 COMP-3 有意义（尾字节高半字节），zoned 等其他
// 用法的 pad 被 encode 静默忽略——decode 从不为它们写 pad，pad≠0 只可能
// 是损坏。

///|
fn sd_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = compile_layout(parse_copybook("01  R.\n    05  N  PIC S9(3).\n"))
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
test "CB-A3: sign=10（0xA）必须报错而不是静默落默认符号" {
  // decode 只写 C/D/F；0xA 是 decode 永远写不出的损坏，静默收下会
  // 丢符号（+123 的 C 区号被写成 F）
  inspect(
    sd_encode_line("{\"R.N\":123,\"__nibbles\":{\"R.N\":{\"sign\":10}}}"),
    content="Err(__nibbles['R.N'].sign must be one of 12 (C, positive), 13 (D, negative), 15 (F, unsigned), got 10)",
  )
}

///|
test "CB-A3: sign=14（0xE）同样报错" {
  inspect(
    sd_encode_line("{\"R.N\":123,\"__nibbles\":{\"R.N\":{\"sign\":14}}}"),
    content="Err(__nibbles['R.N'].sign must be one of 12 (C, positive), 13 (D, negative), 15 (F, unsigned), got 14)",
  )
}

///|
test "CB-A3: 非零 pad 落在 zoned 字段必须报错" {
  // zoned 没有 pad 半字节；decode 从不为它写 pad。pad=5 被静默忽略
  // 是「损坏静默降级」的同型
  inspect(
    sd_encode_line(
      "{\"R.N\":123,\"__nibbles\":{\"R.N\":{\"sign\":12,\"pad\":5}}}",
    ),
    content="Err(__nibbles['R.N'].pad applies only to COMP-3 fields, got 5)",
  )
}

///|
test "CB-A3: 合法 sign 与 pad=0 不受影响（修复不伤正路径）" {
  // sign 13（负）+ pad 0：decode 的正常输出形态，原样往返
  match
    sd_encode_line(
      "{\"R.N\":-123,\"__nibbles\":{\"R.N\":{\"sign\":13,\"pad\":0}}}",
    ) {
    Err(e) => fail("legal sign/pad must encode: \{e}")
    Ok(b) => {
      let want = [0xF1, 0xF2, 0xD3]
      assert_eq(b.length(), 3)
      for i in 0..<3 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}
