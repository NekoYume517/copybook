// CB-A4（2026-11-10 审计）：__nibbles / __float_hex 指向不存在字段的键
// 被静默忽略。
//
// ## 缺陷形态（修复前）
//
// parse 层把旁路键收进 map，随后只按 layout.fields 逐字段查找消费，
// 从不校验「每个键都被命中」：
//
//   - {"R.A":123,"__nibbles":{"R.Q":{"sign":12}}}   → R.Q 不存在，
//     符号信息被静默丢弃，exit 0
//   - {"R.D":8,"__float_hex":{"R.X":"4180000000000001"}} → R.X 不存在，
//     原始字节旁路被静默丢弃、按文本近似值重编码，exit 0
//
// decode 写出的键恒为布局内字段；指向不存在字段的键只可能是改错名或
// 蓄意构造，静默忽略会让符号/原始字节信息无声丢失——与 NEW-6「损坏
// 必须报错，没有误伤面」同一哲学。

///|
fn bk_encode_line(
  cb : String,
  line : String,
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
let bk_nib_cb : String = "01  R.\n    05  N  PIC S9(3).\n"

///|
let bk_float_cb : String = "01  R.\n    05  D  COMP-2.\n"

///|
test "CB-A4: __nibbles 指向不存在字段必须报错" {
  inspect(
    bk_encode_line(
      bk_nib_cb, "{\"R.N\":123,\"__nibbles\":{\"R.Q\":{\"sign\":12}}}",
    ),
    content="Err(__nibbles['R.Q'] does not match any field in this copybook)",
  )
}

///|
test "CB-A4: __float_hex 指向不存在字段必须报错" {
  inspect(
    bk_encode_line(
      bk_float_cb, "{\"R.D\":8,\"__float_hex\":{\"R.X\":\"4180000000000001\"}}",
    ),
    content="Err(__float_hex['R.X'] does not match any COMP-1/COMP-2 field in this copybook)",
  )
}

///|
test "CB-A4: 命中字段的旁路键不受影响（修复不伤正路径）" {
  // 完整路径与裸名（CB-5）两种写法都必须继续生效
  match
    bk_encode_line(
      bk_nib_cb, "{\"R.N\":123,\"__nibbles\":{\"R.N\":{\"sign\":12}}}",
    ) {
    Err(e) => fail("path-key bypass must encode: \{e}")
    Ok(b) => assert_eq(b[2].to_int(), 0xC3)
  }
  match
    bk_encode_line(
      bk_nib_cb, "{\"R.N\":123,\"__nibbles\":{\"N\":{\"sign\":12}}}",
    ) {
    Err(e) => fail("bare-name bypass must encode: \{e}")
    Ok(b) => assert_eq(b[2].to_int(), 0xC3)
  }
}
