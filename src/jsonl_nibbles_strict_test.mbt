// CB-3（2026-11-08 审计）：__nibbles 损坏形态静默降级，违背 NEW-6 承诺。
//
// ## 缺陷形态（修复前）
//
// NEW-6 的承诺（jsonl_strictness_test.mbt）：「__ 开头的键只可能来自
// decode 的输出或蓄意构造，内容损坏必须报错，没有误伤面」。__tail_hex /
// __filler_hex / __float_hex 都照做了（坏 hex 报错、条目非字符串报错），
// 唯独 __nibbles 三种损坏形态全部静默：
//
//   a) "__nibbles":"x"            —— 整键非对象 → 静默忽略（exit 0）
//   b) "__nibbles":{"R.N":"x"}    —— 条目非对象 → 静默忽略（exit 0）
//   c) "__nibbles":{"R.N":{"sign":256}} —— 半字节超 0..15 → 静默落
//      encode 默认分支（S9 字段被写成 F 区号，符号信息丢失）
//   d) sign = 1e20 → to_int() 饱和/回绕 → 同 c
//
// 文件截断/传输损坏后，「无损往返」变成静默改字节 —— 与 NEW-6 拒绝的
// __filler_hex 形态完全同型。
//
// ## 修复
//
// a/b/c/d 全部报错（数据错误），文案带键名与实际类型/数值。

///|
fn cb3_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  N  PIC S9(3).\n"))
}

///|
fn cb3_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = cb3_layout()
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
test "NEW-6b: __nibbles 整键非对象必须报错" {
  inspect(
    cb3_encode_line("{\"R.N\":1,\"__nibbles\":\"x\"}"),
    content="Err(__nibbles must be an object of {field: {sign?, pad?}}, got a string)",
  )
}

///|
test "NEW-6b: __nibbles 条目非对象必须报错" {
  inspect(
    cb3_encode_line("{\"R.N\":1,\"__nibbles\":{\"R.N\":\"x\"}}"),
    content="Err(__nibbles['R.N'] must be an object of {sign?, pad?}, got a string)",
  )
}

///|
test "NEW-6b: __nibbles sign 超 0..15 必须报错" {
  // 256 超出半字节值域；旧实现静默落 encode 默认分支丢符号
  inspect(
    cb3_encode_line("{\"R.N\":1,\"__nibbles\":{\"R.N\":{\"sign\":256}}}"),
    content="Err(__nibbles['R.N'].sign must be an integer in 0..=15, got 256)",
  )
}

///|
test "NEW-6b: __nibbles sign 非有限大数必须报错" {
  // 1e20 在 Int32 饱和/回绕，同样必须拒绝而不是静默降级
  inspect(
    cb3_encode_line(
      "{\"R.N\":1,\"__nibbles\":{\"R.N\":{\"sign\":100000000000000000000}}}",
    ),
    content="Err(__nibbles['R.N'].sign must be an integer in 0..=15, got 100000000000000000000)",
  )
}

///|
test "NEW-6b: pad 超值域同样报错" {
  inspect(
    cb3_encode_line("{\"R.N\":1,\"__nibbles\":{\"R.N\":{\"pad\":16}}}"),
    content="Err(__nibbles['R.N'].pad must be an integer in 0..=15, got 16)",
  )
}
