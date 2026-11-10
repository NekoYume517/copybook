// CB-A2（2026-11-10 审计）：__filler_hex / __tail_hex 字节数 ≠ 空洞大小时
// 静默降级，违背 NEW-6「旁路键损坏必须报错」的承诺。
//
// ## 缺陷形态（修复前）
//
// encode_record 的空洞回填闭包 `if src < bs.length() { w.set(...) }`：
//   - 旁路字节**短缺**（文件截断/传输损坏把 "c3c4" 剪成 "c3"）→
//     剩余空洞字节被写成 0x40 空格，exit 0 零提示 ——「无损往返」
//     变成静默改字节，与 NEW-6 已修的奇数长度/非 hex 形态完全同型；
//   - 旁路字节**超长**（"c3c4c9"）→ 多出字节被静默忽略，exit 0。
//
// decode 写出的旁路恒为精确空洞字节集，长度不对只可能是损坏或蓄意构造。

///|
fn gl_encode(
  line : String,
  cb : String,
) -> Result[Bytes, String] raise ParseError {
  let layout = compile_layout(parse_copybook(cb))
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
let filler_cb : String = "01  R.\n    05  A  PIC X(2).\n    05  FILLER PIC X(2).\n    05  B  PIC X(2).\n"

///|
let tail_cb : String = "01  R.\n    05  A  PIC X(4).\n    05  V  REDEFINES A PIC X(6).\n"

///|
test "CB-A2: __filler_hex 短缺必须报错而不是静默写 0x40" {
  // 空洞 2 字节（offset 2..4），旁路只有 1 字节：C4 被静默换成 0x40
  inspect(
    gl_encode(
      "{\"R.A\":\"AB\",\"R.B\":\"EF\",\"__filler_hex\":\"c3\"}", filler_cb,
    ),
    content="Err(invalid bypass key: __filler_hex must be exactly 2 byte(s) for this record's FILLER gap(s), got 1)",
  )
}

///|
test "CB-A2: __filler_hex 超长必须报错而不是静默忽略" {
  inspect(
    gl_encode(
      "{\"R.A\":\"AB\",\"R.B\":\"EF\",\"__filler_hex\":\"c3c4c9\"}", filler_cb,
    ),
    content="Err(invalid bypass key: __filler_hex must be exactly 2 byte(s) for this record's FILLER gap(s), got 3)",
  )
}

///|
test "CB-A2: __tail_hex 短缺必须报错而不是静默写 0x40" {
  // 尾部空洞 2 字节（offset 4..6，只有重定义视图覆盖），旁路只有 1 字节
  inspect(
    gl_encode("{\"R.A\":\"1234\",\"R.V\":null,\"__tail_hex\":\"ff\"}", tail_cb),
    content="Err(invalid bypass key: __tail_hex must be exactly 2 byte(s) for this record's tail gap(s), got 1)",
  )
}

///|
test "CB-A2: 精确长度的旁路仍逐字节回填（修复不伤正路径）" {
  match
    gl_encode(
      "{\"R.A\":\"AB\",\"R.B\":\"EF\",\"__filler_hex\":\"c3c4\"}", filler_cb,
    ) {
    Err(e) => fail("exact-length filler bypass must encode: \{e}")
    Ok(b) => {
      let want = [0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6]
      assert_eq(b.length(), 6)
      for i in 0..<6 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
  match
    gl_encode(
      "{\"R.A\":\"1234\",\"R.V\":null,\"__tail_hex\":\"ffee\"}", tail_cb,
    ) {
    Err(e) => fail("exact-length tail bypass must encode: \{e}")
    Ok(b) => {
      let want = [0xF1, 0xF2, 0xF3, 0xF4, 0xFF, 0xEE]
      assert_eq(b.length(), 6)
      for i in 0..<6 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}
