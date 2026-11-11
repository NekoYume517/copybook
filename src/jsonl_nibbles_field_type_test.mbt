// 审计回归（2026-11-11）：`__nibbles` 被套用到**不产生符号半字节的字段**上。
//
// `__nibbles` 是 decode 为 zoned / packed 十进制写出的保留键（符号半字节、
// packed 填充半字节）。旧实现只要键命中任意字段就把文本强行解析成
// `Decimal`，于是文本字段会被静默改写：
//
//     {"R.A":"00012","__nibbles":{"R.A":{"sign":15}}}   (PIC X(5))
//       -> 解成 Decimal(12) -> encode 写 "12   "（前导零丢失，exit 0）
//
// COMP / COMP-1/2 / NATIONAL / 编辑型根本没有这个半字节位置；`__float_hex`
// 已经按「只服务 COMP-1/2」做键对账，`__nibbles` 也必须按字段类型对账，
// 否则一个多余/错位的旁路键能改写用户数据。

///|
fn nbt_rejects(cb : String, line : String) -> Unit raise {
  let layout = compile_layout(parse_copybook(cb))
  match parse_jsonl_row(layout, line) {
    Err(e) => assert_true(e.contains("__nibbles"))
    Ok(_) => fail("__nibbles on a non-zoned/packed field must be rejected")
  }
}

///|
test "__nibbles on a text field is rejected (does not rewrite leading zeros)" {
  nbt_rejects(
    "01 R.\n  05 A PIC X(5).\n", "{\"R.A\":\"00012\",\"__nibbles\":{\"R.A\":{\"sign\":15}}}",
  )
}

///|
test "__nibbles on NATIONAL / edited / COMP / float fields is rejected" {
  nbt_rejects(
    "01 R.\n  05 A PIC N(3).\n", "{\"R.A\":\"123\",\"__nibbles\":{\"R.A\":{\"sign\":13}}}",
  )
  nbt_rejects(
    "01 R.\n  05 A PIC $9,999.99.\n", "{\"R.A\":\"1234.56\",\"__nibbles\":{\"R.A\":{\"sign\":15}}}",
  )
  nbt_rejects(
    "01 R.\n  05 A PIC S9(3) COMP.\n", "{\"R.A\":\"123\",\"__nibbles\":{\"R.A\":{\"sign\":13}}}",
  )
  nbt_rejects(
    "01 R.\n  05 A PIC S9(4) COMP-1.\n", "{\"R.A\":\"1.5\",\"__nibbles\":{\"R.A\":{\"sign\":15}}}",
  )
}

///|
test "__nibbles on zoned / packed decimal still works" {
  // zoned：符号半字节 0xD 是负号
  let zoned = compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
  let line = "{\"R.A\":-25,\"__nibbles\":{\"R.A\":{\"sign\":13}}}"
  let row = parse_jsonl_row(zoned, line).unwrap()
  let bs = encode_record(zoned, row).unwrap()
  assert_eq(bs[2].to_int(), 0xD5)
  // packed：sign + pad 都生效
  let packed = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-3.\n"),
  )
  let line2 = "{\"R.A\":1234,\"__nibbles\":{\"R.A\":{\"sign\":12,\"pad\":0}}}"
  let row2 = parse_jsonl_row(packed, line2).unwrap()
  let bs2 = encode_record(packed, row2).unwrap()
  assert_eq(bs2, b"\x01\x23\x4C")
}
