// 2026-11-17 审计 C11：手工 `PicClause` 的荒谬 scale 会让十进制渲染空转。
//
// ## 缺陷形态
//
// `PicClause` / `RecordLayout` / `FieldLayout` 都是 `pub(all)`，库用户可以直接
// 构造。parser 把总位数限在 18（`parser.mbt` 的上限检查），但手写 `scale` 没有
// 任何约束：
//
//   decode_record  ──► Decimal{scale: 2_000_000_000}  ──► Ok（本测试这一层）
//                     └─► to_string / render_jsonl / render_table
//                          `for i < scale - digits + 1` 十亿次空转（挂死形态）
//
// 另有一个更隐蔽的分支：`scale == Int32::MIN` 时 `-self.scale` 自身回绕成负数，
// `for i < -scale` 一次都不跑，于是输出一个**没有任何小数部分**的错误字符串
// 而不是报错（静默错误值）。
//
// 修法按 Lead 裁决放在**入口**：`Decimal::to_string` 返回 `String`，没法报错，
// 所以守卫放在「从 PicClause 产出/消费 Decimal」的边界（`decode_field` /
// `encode_field`），越界返回带位置的 `InvalidNumeric`。
//
// 合理域取 `[-18, 18]`：PIC 的存储位数上限是 18（parser 强制），P 缩放位也计入
// 这个上限，所以任何 parser 可达的 pic 都满足 `|scale| <= 18`。常数
// `MAX_DECIMAL_SCALE` 在 decode.mbt，理由写在那里。

///|
fn c11_layout(scale : Int32) -> RecordLayout raise ParseError {
  let base = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(3).\n"))
  let pic = { ..base.fields[0].pic, scale, }
  let field = { ..base.fields[0], pic, }
  { ..base, fields: [field], all_fields: [field], }
}

///|
test "C11: decode rejects an absurd positive scale instead of materializing it" {
  let layout = c11_layout(2000000000)
  match decode_record(layout, b"\xF1\xF2\xF3") {
    Err(e) => assert_true(e.to_display().contains("scale"))
    Ok(_) => fail("absurd scale must be rejected at decode")
  }
}

///|
test "C11: decode rejects Int32::MIN scale (negation would wrap)" {
  let layout = c11_layout(-2147483648)
  match decode_record(layout, b"\xF1\xF2\xF3") {
    Err(e) => assert_true(e.to_display().contains("scale"))
    Ok(_) =>
      fail("Int32::MIN scale must be rejected, not silently mis-rendered")
  }
}

///|
test "C11: encode rejects an absurd scale too" {
  let layout = c11_layout(2000000000)
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("123")
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("scale"))
    Ok(_) => fail("absurd scale must be rejected at encode as well")
  }
}

///|
test "C11: the parser-reachable range still works" {
  // 反向锁：|scale| <= 18 是 parser 能产出的全部范围，包含边界，必须照旧。
  for scale in [-18, -2, 0, 2, 18] {
    let layout = c11_layout(scale)
    match decode_record(layout, b"\xF1\xF2\xF3") {
      Ok(_) => ()
      Err(e) =>
        fail("scale \{scale} is in range and must decode: \{e.to_display()}")
    }
  }
  // 真实 copybook 的 PP / P 缩放位不受影响
  let pp = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(3)PP.\n"))
  inspect(pp.fields[0].pic.scale, content="-2")
  match decode_record(pp, b"\xF1\xF2\xF3") {
    Ok(_) => ()
    Err(e) => fail("PIC 9(3)PP must still decode: \{e.to_display()}")
  }
}
