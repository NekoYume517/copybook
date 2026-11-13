// 审计回归（2026-11-13）：`__nibbles` 落在「值为 `null` 的重定义视图」上时，
// 旁路被物化成一个负零并**覆盖主视图刚写好的字节**。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     copybook：01 R. 05 M PIC S9(3).  05 V REDEFINES M PIC S9(3).
//     JSONL  ：{"R.M":123,"R.V":null,"__nibbles":{"R.V":{"sign":13}}}
//       -> encode exit 0，输出 F0 F0 D0
//
// 行里 `R.V` 是 `null`（decode 对「视图解不出」的表示），按 API.md §6 与
// A2 契约，**视图必须跳过、该段字节由主视图决定**。但 `__nibbles` 的
// 「没有值 ⇒ 旁路即字节真值」分支（2026-11-12 的 N3 修复）在视图上照旧
// 物化：系数取零、符号按声明的 0xD —— 于是视图把主视图的 123 覆盖成负零，
// 退出码 0、零提示。**主视图数据被静默改写**。
//
// ## 判据
//
// N3 的分支服务的是「基本项没有值」；视图的「没有值」在契约里已有明确
// 语义（跳过，主视图优先，与 `null` / `""` 的视图语义一致）。因此
// `is_redefining && 无值` 时不物化，旁路键照旧被消费（不触发键对账报错）。
//
// 不受影响：基本项的无值物化（N3 锁定，见 `jsonl_nibbles_absent_value_test`）、
// 视图**给了值**的 last-wins 写入（用户显式编辑）。

///|
fn nvn_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  M   PIC S9(3).\n    05  V   REDEFINES M PIC S9(3).\n    05  P   PIC S9(3) COMP-3.\n    05  PV  REDEFINES P PIC S9(3) COMP-3.\n",
    ),
  )
}

///|
fn nvn_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = nvn_layout()
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
test "null view + __nibbles must not overwrite the primary view (zoned)" {
  match
    nvn_encode_line(
      "{\"R.M\":123,\"R.V\":null,\"__nibbles\":{\"R.V\":{\"sign\":13}}}",
    ) {
    Err(e) => fail("legal row must encode: \{e}")
    Ok(b) => {
      // 主视图 R.M = 123 的默认 zoned 写法：F1 F2 F3（视图被跳过）
      assert_eq(b[0].to_int(), 0xF1)
      assert_eq(b[1].to_int(), 0xF2)
      assert_eq(b[2].to_int(), 0xF3)
    }
  }
}

///|
test "null view + __nibbles must not overwrite the primary view (COMP-3)" {
  match
    nvn_encode_line(
      "{\"R.P\":-123,\"R.PV\":null,\"__nibbles\":{\"R.P\":{\"sign\":13},\"R.PV\":{\"sign\":13}}}",
    ) {
    Err(e) => fail("legal row must encode: \{e}")
    Ok(b) => {
      // 主视图 R.P = -123 打包两字节 12 3D；R.PV 被跳过
      assert_eq(b[3].to_int(), 0x12)
      assert_eq(b[4].to_int(), 0x3D)
    }
  }
}

///|
test "a view's own nibble is still consumed (no bypass-key reconcile error)" {
  // 视图上的 __nibbles 是合法键（decode 会为解出的视图写出它）；无值时
  // 只是不物化，不能落进「does not match any field」的损坏分支。
  match
    nvn_encode_line(
      "{\"R.M\":123,\"R.V\":null,\"__nibbles\":{\"R.V\":{\"sign\":13}}}",
    ) {
    Err(e) => fail("view nibble must be accepted: \{e}")
    Ok(_) => ()
  }
}

///|
test "no-value materialization on a primary field is unchanged (N3)" {
  match nvn_encode_line("{\"__nibbles\":{\"R.M\":{\"sign\":13}}}") {
    Err(e) => fail("primary-field nibble-only row must encode: \{e}")
    Ok(b) => {
      assert_eq(b[0].to_int(), 0xF0)
      assert_eq(b[1].to_int(), 0xF0)
      assert_eq(b[2].to_int(), 0xD0)
    }
  }
}

///|
test "a view with an explicit value still wins (last-wins contract)" {
  match nvn_encode_line("{\"R.M\":123,\"R.V\":456}") {
    Err(e) => fail("explicit view value must encode: \{e}")
    Ok(b) => {
      assert_eq(b[0].to_int(), 0xF4)
      assert_eq(b[1].to_int(), 0xF5)
      assert_eq(b[2].to_int(), 0xF6)
    }
  }
}
