// 2026-11-17 审计 C3：`__` 保留键的**键名**这一维没有对账。
//
// NEW-6 / CB-A4 立的原则是「这些键只可能来自 decode 的输出或蓄意构造，损坏
// 必须报错，没有误伤面」，并已逐条做到：整键非对象、条目非对象、半字节超域、
// hex 奇数长度、几何与字节数不符……但只覆盖了**已认识的键名**。任何拼错或改名
// 的保留键（`__nibble` / `__tail_hexx` / `__float_hexx` / `__gap`）都落进
// 「未知字段」的宽容分支，旁路信息被静默丢弃、exit 0 —— 正是 NEW-6 要消灭的
// 形态：decode 写出的 → 用户改个字 → encode 静默换成默认字节。
//
// 误伤面为零有据：`lexer.mbt` 只让标识符以字母开头（`is_ascii_letter`），
// COBOL 字段名不可能以 `_` 开头，所以「以 `__` 开头且不在白名单」只可能是损坏。
//
// `__record_bytes` 是**内存路径专用**（decode 挂在结果 map 上的原始记录字节），
// 它出现在 JSONL 里必是损坏：JSONL 的原始字节载体是 `__tail_hex` /
// `__filler_hex` 加配套几何。

///|
fn c3_packed_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 N PIC S9(3) COMP-3.\n"))
}

///|
fn c3_filler_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 FILLER PIC X(2).\n"))
}

///|
test "C3: a misspelled reserved key is rejected instead of silently dropped" {
  let layout = c3_packed_layout()
  // 本意是负号半字节（sign 13）：拼错成 __nibble 后旧实现静默丢弃，
  // encode 写出 12 3C（+123）而不是 12 3D（-123）。
  match
    parse_jsonl_row(
      layout, "{\"R.N\":123,\"__nibble\":{\"R.N\":{\"sign\":13}}}",
    ) {
    Err(e) => assert_true(e.contains("__nibble"))
    Ok(_) => fail("a misspelled reserved key must be rejected")
  }
}

///|
test "C3: other misspellings are rejected too" {
  let layout = c3_filler_layout()
  for
    line in [
      "{\"__tail_hexx\":\"c1c2\"}", "{\"__filler_hexg\":\"c1c2\"}", "{\"__gap\":[[0,2]]}",
      "{\"__\":\"x\"}",
    ] {
    match parse_jsonl_row(layout, line) {
      Err(_) => ()
      Ok(_) => fail("unknown reserved key must be rejected: \{line}")
    }
  }
}

///|
test "C3: __record_bytes is not a JSONL key" {
  // 内存路径专用：decode 把整条记录挂在结果 map 上，由 encode_record 消费。
  // 写进 JSONL 说明行被手改坏了，必须报错而不是当未知字段放过。
  let layout = c3_filler_layout()
  match parse_jsonl_row(layout, "{\"__record_bytes\":\"c1c2\"}") {
    Err(e) => assert_true(e.contains("__record_bytes"))
    Ok(_) => fail("__record_bytes must not be accepted from JSONL")
  }
}

///|
test "C3: every documented reserved key still parses" {
  // 白名单 = API.md §6 表格里的 6 个键。误伤面必须为零。
  let layout = c3_filler_layout()
  for
    line in [
      "{\"__filler_hex\":\"c1c2\"}", "{\"__filler_hex\":\"c1c2\",\"__filler_gap\":[[0,2]]}",
      "{\"__tail_hex\":\"c1c2\"}", "{\"__tail_hex\":\"c1c2\",\"__tail_gap\":[[0,2]]}",
    ] {
    match parse_jsonl_row(layout, line) {
      Ok(_) => ()
      Err(e) => fail("documented key must still parse: \{line} -> \{e}")
    }
  }
  let packed = c3_packed_layout()
  match
    parse_jsonl_row(
      packed, "{\"R.N\":123,\"__nibbles\":{\"R.N\":{\"sign\":12}}}",
    ) {
    Ok(_) => ()
    Err(e) => fail("__nibbles must still parse: \{e}")
  }
}
