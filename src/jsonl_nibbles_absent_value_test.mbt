// 审计回归（2026-11-12）：`__nibbles` 指向的字段**没有值**时，声明的符号
// 半字节被静默丢弃。
//
// ## 缺陷形态（修复前）
//
//     {"__nibbles":{"R.N":{"sign":13}}}                      ← PIC S9(3)
//       -> encode 写出 F0 F0 F0（无符号零），exit 0
//     {"__nibbles":{"R.P":{"sign":13}}}                      ← PIC S9(3) COMP-3
//       -> encode 写出 00 0C（正号），exit 0
//
// 行里明确声明了 0xD（负号），编出来的字节却是正号 —— 字节层事实被静默改写，
// 与 N2（`__float_hex` 无值时按 0.0）同一族：旁路键只在「字段值是 Text」时
// 才被消费，`out.get` 为 None/Null 时直接 `_ => ()` 走掉，符号信息无声丢失。
//
// ## 判据
//
// 与 `__float_hex` / `__tail_hex` / `__filler_hex` 统一：**没有值 = 没有竞争的
// 编辑**，旁路键就是字节真值。系数按「未赋值存储 = 0」取零，符号/填充半字节
// 按声明写回（`PIC S9(3)` 的负零 = `F0 F0 D0`，COMP-3 的负零 = `00 0D`）。
// 有值时仍走既有的值感知判定（CB-2 的 `"-0"`、RJ-3a 的编辑优先都不动）。

///|
fn nav_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  N  PIC S9(3).\n    05  P  PIC S9(3) COMP-3.\n    05  T  PIC X(2).\n",
    ),
  )
}

///|
fn nav_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = nav_layout()
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
test "__nibbles without a field value keeps the declared sign (zoned)" {
  match nav_encode_line("{\"__nibbles\":{\"R.N\":{\"sign\":13}}}") {
    Err(e) => fail("nibble-only row must encode: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 7)
      // S9(3) 的负零：数字位 F0 F0，末字节符号区 D0
      assert_eq(b[0].to_int(), 0xF0)
      assert_eq(b[1].to_int(), 0xF0)
      assert_eq(b[2].to_int(), 0xD0)
    }
  }
}

///|
test "__nibbles without a field value keeps the declared sign (COMP-3)" {
  match nav_encode_line("{\"__nibbles\":{\"R.P\":{\"sign\":13}}}") {
    Err(e) => fail("nibble-only row must encode: \{e}")
    Ok(b) => {
      // P 在偏移 3（S9(3) DISPLAY 占 3 字节），COMP-3 2 字节：00 0D
      assert_eq(b[3].to_int(), 0x00)
      assert_eq(b[4].to_int(), 0x0D)
    }
  }
}

///|
test "__nibbles with an explicit null value keeps the declared sign" {
  match
    nav_encode_line("{\"R.N\":null,\"__nibbles\":{\"R.N\":{\"sign\":13}}}") {
    Err(e) => fail("null value + nibble must encode: \{e}")
    Ok(b) => assert_eq(b[2].to_int(), 0xD0)
  }
}

///|
test "__nibbles still works alongside an explicit value (no regression)" {
  // CB-2 的已锁定契约：文本 "-0" + sign 13 是 decode 的原样输出
  match
    nav_encode_line("{\"R.N\":\"-0\",\"__nibbles\":{\"R.N\":{\"sign\":13}}}") {
    Err(e) => fail("value + nibble must encode: \{e}")
    Ok(b) => assert_eq(b[2].to_int(), 0xD0)
  }
}

///|
test "__nibbles on a field that takes no nibbles still errors without a value" {
  // B8 的契约：文本/其它类别字段没有半字节，损坏必须报错（不能被新分支吃掉）
  match nav_encode_line("{\"__nibbles\":{\"R.T\":{\"sign\":13}}}") {
    Err(e) => assert_true(e.contains("does not match any field"))
    Ok(_) => fail("nibble on a text field must be rejected")
  }
}
