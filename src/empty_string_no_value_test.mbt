// 契约 A2（2026-11-12，Lead 拍板）：`""` 在数值/浮点字段上是「本行没有给
// 这个字段值」，与 `null` / 缺键同义，**绝不等于 0.0**；文本字段的 `""`
// 仍是「若干空格」（合法值，行为不变）。
//
// ## 缺陷形态（修复前）
//
// 浮点字段带旁路快照时给空串：
//
//     {"R.D":"","__float_hex":{"R.D":"4180000000000001"}}
//
// `parse_jsonl_row` 把 `Text("")` 交给 `parse_double`，异常被 `catch { _ => 0.0 }`
// 兜成 0.0；于是「旁路字节解出的 8.0」与「0.0」比较 → 不一致 → 判成
// 「用户把值编辑成了 0」→ 旁路当陈旧快照丢弃 → encode 写出整片 `0x00`，
// exit 0、零提示。声明的字节事实被静默换成浮点零。
//
// 数值字段的空串则走 `parse_decimal_text("")` → None → 报
// `cannot parse '' as a decimal number`，虽然也是 exit 1，但消息里没有字段
// 路径，读的人无法定位是哪一行哪一列。
//
// ## 本轮的判据
//
//   - 浮点/数值 + `""` + 有旁路快照 → 按旁路还原**原始字节**（字节真值）；
//   - 浮点/数值 + `""` + 无旁路 → 带字段路径的 data error（exit 1），绝不写零；
//   - 浮点/数值 + `""` + 该字段是重定义视图（字节被主视图覆盖）→ 跳过写入，
//     主视图的字节保留（与 `null` 的视图语义一致）；
//   - 文本 / NATIONAL + `""` → 全空格（不变）；
//   - `null` 的既有语义完全不变（数值写 0、浮点写 +0.0、视图跳过）；
//   - 显式零（`0` / `0.0` / `"0"` / `"-0"`）仍写出真正的零字节。

///|
fn esnv_layout(mode : FloatMode) -> RecordLayout raise ParseError {
  compile_layout_with_float_mode(
    parse_copybook(
      "01  R.\n    05  D  COMP-2.\n    05  F  COMP-1.\n    05  N  PIC S9(3).\n    05  P  PIC S9(3) COMP-3.\n    05  T  PIC X(2).\n",
    ),
    mode,
  )
}

///|
fn esnv_encode_line(line : String) -> Result[Bytes, String] raise ParseError {
  let layout = esnv_layout(FloatMode::Hfp)
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
fn esnv_hex(b : Bytes, from : Int32, to : Int32) -> String {
  let sb = StringBuilder::new()
  for i = from; i < to; i = i + 1 {
    let v = b[i].to_int()
    if v < 16 {
      sb.write_string("0")
    }
    sb.write_string(v.to_string(radix=16))
  }
  sb.to_string()
}

// ---------------------------------------------------------------------------
// 矩阵 1：浮点 `""` + 一致旁路 → 写出原始字节
// ---------------------------------------------------------------------------

///|
test "A2 matrix 1: empty string on a float field restores the bypass bytes" {
  match
    esnv_encode_line(
      "{\"R.D\":\"\",\"__float_hex\":{\"R.D\":\"4180000000000001\"}}",
    ) {
    Err(e) => fail("bypass must win over an empty string: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 19)
      assert_eq(esnv_hex(b, 0, 8), "4180000000000001")
    }
  }
  // COMP-1 同款（4 字节旁路）
  match
    esnv_encode_line("{\"R.F\":\"\",\"__float_hex\":{\"R.F\":\"41180000\"}}") {
    Err(e) => fail("bypass must win over an empty string: \{e}")
    Ok(b) => assert_eq(esnv_hex(b, 8, 12), "41180000")
  }
}

///|
test "A2 matrix 1: decode -> empty the float value -> encode is byte-identical" {
  // 真实工作流：decode 出一条记录，把浮点值清空成 ""，其余键（含旁路）不动
  let layout = esnv_layout(FloatMode::Hfp)
  let rec = bs([
    0x41, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x41, 0x18, 0x00, 0x00, 0xF1,
    0xF2, 0xF3, 0x00, 0x0C, 0x40, 0x40,
  ])
  let row = decode_record(layout, rec).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__float_hex\""))
  let blanked = text.replace(old="\"R.D\":8", new="\"R.D\":\"\"")
  assert_true(blanked.contains("\"R.D\":\"\""))
  let parsed = parse_jsonl_row(layout, blanked).unwrap()
  match encode_record(layout, parsed) {
    Err(e) => fail("blanked float value must still encode: \{e.to_display()}")
    Ok(b) => assert_eq(b, rec)
  }
}

// ---------------------------------------------------------------------------
// 矩阵 2：浮点 `""` + 无旁路 → 带字段路径的 data error，绝不写 0x00
// ---------------------------------------------------------------------------

///|
test "A2 matrix 2: empty string without a bypass is a data error naming the field" {
  // 8.0 精确可表示 → decode 不产 __float_hex；此时清空值必须报错而不是写零
  match esnv_encode_line("{\"R.D\":\"\"}") {
    Err(e) => {
      assert_true(e.contains("R.D"))
      assert_true(e.contains("no value"))
    }
    Ok(b) =>
      fail(
        "empty float without bypass must not encode, got bytes \{esnv_hex(b, 0, 8)}",
      )
  }
  // COMP-1 同款
  match esnv_encode_line("{\"R.F\":\"\"}") {
    Err(e) => assert_true(e.contains("R.F"))
    Ok(_) => fail("empty COMP-1 without bypass must not encode")
  }
}

///|
test "A2 matrix 2: a float view with an empty string keeps the primary bytes" {
  // 「有覆盖则用覆盖」：视图的字节由主视图写出，空串不覆盖它
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(8).\n  05 V REDEFINES A COMP-2.\n"),
  )
  let row = parse_jsonl_row(layout, "{\"R.A\":\"ABCDEFGH\",\"R.V\":\"\"}").unwrap()
  match encode_record(layout, row) {
    Err(e) => fail("empty view value must not fail: \{e.to_display()}")
    Ok(b) => assert_eq(esnv_hex(b, 0, 8), "c1c2c3c4c5c6c7c8")
  }
}

// ---------------------------------------------------------------------------
// 矩阵 3：显式零仍写出真正的零字节（HFP 与 IEEE 各一组）
// ---------------------------------------------------------------------------

///|
test "A2 matrix 3: explicit zeros write real zero bytes in both float modes" {
  for mode in [FloatMode::Hfp, FloatMode::Ieee754] {
    let layout = esnv_layout(mode)
    // JSON 数字 0 与文本 "0" 都是 +0
    for literal in ["0", "\"0\""] {
      let line = "{\"R.D\":" + literal + ",\"R.F\":" + literal + "}"
      let row = parse_jsonl_row(layout, line).unwrap()
      match encode_record(layout, row) {
        Err(e) => fail("+\{literal} must encode: \{e.to_display()}")
        Ok(b) => assert_eq(esnv_hex(b, 0, 12), "000000000000000000000000")
      }
    }
    // "-0" 是负零：两种格式都是符号位 + 全零尾数
    let row = parse_jsonl_row(layout, "{\"R.D\":\"-0\",\"R.F\":\"-0\"}").unwrap()
    match encode_record(layout, row) {
      Err(e) => fail("-0 must encode: \{e.to_display()}")
      Ok(b) => {
        assert_eq(esnv_hex(b, 0, 8), "8000000000000000")
        assert_eq(esnv_hex(b, 8, 12), "80000000")
      }
    }
    // 0.0 也是 +0（JSON 数字带小数点的形态）
    let row2 = parse_jsonl_row(layout, "{\"R.D\":0.0,\"R.F\":0.0}").unwrap()
    match encode_record(layout, row2) {
      Err(e) => fail("0.0 must encode: \{e.to_display()}")
      Ok(b) => assert_eq(esnv_hex(b, 0, 12), "000000000000000000000000")
    }
  }
}

// ---------------------------------------------------------------------------
// 矩阵 4：数值字段 `""` → 不写 0；有覆盖则用覆盖
// ---------------------------------------------------------------------------

///|
test "A2 matrix 4: empty string on a numeric field is a data error naming the field" {
  match esnv_encode_line("{\"R.N\":\"\"}") {
    Err(e) => {
      assert_true(e.contains("R.N"))
      assert_true(e.contains("no value"))
    }
    Ok(b) => fail("empty numeric must not encode, got \{esnv_hex(b, 12, 15)}")
  }
  // COMP-3 同款
  match esnv_encode_line("{\"R.P\":\"\"}") {
    Err(e) => assert_true(e.contains("R.P"))
    Ok(_) => fail("empty COMP-3 must not encode")
  }
}

///|
test "A2 matrix 4: a numeric view with an empty string keeps the primary bytes" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 N PIC S9(3).\n  05 V REDEFINES N PIC S9(3).\n"),
  )
  let row = parse_jsonl_row(layout, "{\"R.N\":\"123\",\"R.V\":\"\"}").unwrap()
  match encode_record(layout, row) {
    Err(e) => fail("empty numeric view must not fail: \{e.to_display()}")
    Ok(b) => assert_eq(esnv_hex(b, 0, 3), "f1f2f3")
  }
}

// ---------------------------------------------------------------------------
// 矩阵 5：文本字段 `""` 仍是全空格（行为不变）
// ---------------------------------------------------------------------------

///|
test "A2 matrix 5: an empty string on a text field is spaces, unchanged" {
  match esnv_encode_line("{\"R.T\":\"\"}") {
    Err(e) => fail("empty text must encode as spaces: \{e}")
    Ok(b) => assert_eq(esnv_hex(b, 17, 19), "4040")
  }
  // 与「根本没给这个字段」逐字节相同
  match esnv_encode_line("{}") {
    Err(e) => fail("empty row must encode: \{e}")
    Ok(b) => assert_eq(esnv_hex(b, 17, 19), "4040")
  }
}

// ---------------------------------------------------------------------------
// 矩阵 6：`null` 的既有语义完全不变
// ---------------------------------------------------------------------------

///|
test "A2 matrix 6: null plus a bypass is still byte-identical (B1 e2e)" {
  match
    esnv_encode_line(
      "{\"R.D\":null,\"__float_hex\":{\"R.D\":\"4180000000000001\"}}",
    ) {
    Err(e) => fail("null + bypass must encode: \{e}")
    Ok(b) => assert_eq(esnv_hex(b, 0, 8), "4180000000000001")
  }
}

///|
test "A2 matrix 6: null on a numeric field still writes unassigned-storage zeros" {
  match esnv_encode_line("{\"R.N\":null,\"R.P\":null}") {
    Err(e) => fail("null numeric must still encode: \{e}")
    Ok(b) => {
      assert_eq(esnv_hex(b, 12, 15), "f0f0f0")
      assert_eq(esnv_hex(b, 15, 17), "000c")
    }
  }
}

///|
test "A2 matrix 6: null on a float field still writes +0.0" {
  match esnv_encode_line("{\"R.D\":null,\"R.F\":null}") {
    Err(e) => fail("null float must still encode: \{e}")
    Ok(b) => assert_eq(esnv_hex(b, 0, 12), "000000000000000000000000")
  }
}
