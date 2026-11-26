// 审计回归（2026-11-15）：`field_will_write` 没有镜像契约 A2 的
// 「数值类字段上空串 = 没有值」跳过分支 —— `encode_field` 对重定义视图的
// `Text("")` 直接跳过写入（注释明言「与 null 的视图语义一致」），但空洞
// 判定把它当「会写」，decode 带出的 `__tail_hex` / `__tail_gap` 快照因此
// 被静默丢弃，洞里的字节落回 Writer 初始的 0x40。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     01 R.
//        05 M PIC X(2).
//        05 V REDEFINES M PIC 9(4).
//     data：C1 C2 F3 F4（V 按 zoned 解：首字节区号 C 非 F → 视图 null）
//     decode -> {"R.M":"AB","R.V":null,"__tail_hex":"f3f4","__tail_gap":[[2,4]]}
//
//     {"R.M":"AB","R.V":null,"__tail_hex":"f3f4","__tail_gap":[[2,4]]}
//       -> C1 C2 F3 F4                     （快照回填 ✓）
//     {"R.M":"AB","R.V":"","__tail_hex":"f3f4","__tail_gap":[[2,4]]}
//       -> C1 C2 40 40                     （快照被静默丢弃 ✗）
//
// 同一输入只把 null 换成 ""，字节结果不同 —— 违反 A2「"" 在数值字段上
// 等价于 null 或缺键」（API.md §6）。视图覆盖还延伸到主视图之外时，
// 「该段字节由主视图决定」的承诺落空：主视图不覆盖的部分既不写值也不回填。
//
// 修复：`field_will_write` 镜像 `encode_field` 的 A2 跳过分支
// （重定义视图 + Numeric 类别 + `Text("")` → 不写）。

///|
fn evw_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M PIC 9(4).\n"),
  )
}

///|
fn evw_encode(layout : RecordLayout, line : String) -> Result[Bytes, String] {
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
test "empty string on a tail-extending numeric view still restores the snapshot" {
  let layout = evw_layout()
  match
    evw_encode(
      layout, "{\"R.M\":\"AB\",\"R.V\":\"\",\"__tail_hex\":\"f3f4\",\"__tail_gap\":[[2,4]]}",
    ) {
    Err(e) => fail("an empty view value must not fail: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 4)
      // 快照里的 F3 F4 必须回填：视图 "" = 没有值 = 这段我不写
      assert_eq(b[2].to_int(), 0xF3)
      assert_eq(b[3].to_int(), 0xF4)
    }
  }
}

///|
test "null and empty string on a numeric view produce identical bytes" {
  let layout = evw_layout()
  let with_null = evw_encode(
    layout, "{\"R.M\":\"AB\",\"R.V\":null,\"__tail_hex\":\"f3f4\",\"__tail_gap\":[[2,4]]}",
  ).unwrap()
  let with_empty = evw_encode(
    layout, "{\"R.M\":\"AB\",\"R.V\":\"\",\"__tail_hex\":\"f3f4\",\"__tail_gap\":[[2,4]]}",
  ).unwrap()
  assert_eq(with_null, with_empty)
}

///|
test "decode output with the null view edited to \"\" roundtrips byte-exactly" {
  // 真实工作流：decode 导出、把视图值 null 改成 ""（语义上是无操作），
  // 其余键不动 —— 字节必须与原记录一致
  let layout = evw_layout()
  let rec = bs([0xC1, 0xC2, 0xF3, 0xF4])
  let row = decode_record(layout, rec).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"R.V\":null"))
  let blanked = text.replace(old="\"R.V\":null", new="\"R.V\":\"\"")
  let parsed = parse_jsonl_row(layout, blanked).unwrap()
  match encode_record(layout, parsed) {
    Err(e) => fail("edited null->\"\" must still encode: \{e.to_display()}")
    Ok(b) => assert_eq(b, rec)
  }
}

///|
test "without a snapshot, an empty view value still leaves unassigned 0x40" {
  // 与 null 无快照一致：没有字节可回填时，洞 = 未赋值存储 = 空格。
  //
  // **CB-20-3（2026-11-28 第二十轮审计）**：这条「洞 = 空格」在**没有快照**
  // 时不再是无条件成立的 —— `05 V REDEFINES M PIC 9(4).` 的 V 解不出
  // （置 null）、空洞 [2,4) 没有任何字段值解释，缺 `__tail_hex` 时编码器
  // 只能凭空写 0x40，于是 encode 报 `InvalidBypass`（`""` 与 `null` 都不会
  // 让 V 产生字节，因此两者都拒绝，正是本条要的「一致」）。
  // 要让「洞 = 未赋值 0x40」成立，必须**显式**给出空几何：`__tail_gap:[]`
  // 表示「我知道这里没有快照，也确实要让它们成为未赋值存储」。
  let layout = evw_layout()
  let with_empty = evw_encode(
    layout, "{\"R.M\":\"AB\",\"R.V\":\"\",\"__tail_gap\":[]}",
  )
  let with_null = evw_encode(
    layout, "{\"R.M\":\"AB\",\"R.V\":null,\"__tail_gap\":[]}",
  )
  // 空几何与「缺载体」同判：这条行里仍然没有字节来源 → 两条都报错
  assert_true(with_empty is Err(_))
  assert_true(with_null is Err(_))
  // 空几何**加上**空快照（`__tail_hex:""`）才是显式声明「空洞里没有字节」
  let forced = evw_encode(
    layout, "{\"R.M\":\"AB\",\"R.V\":\"\",\"__tail_hex\":\"\",\"__tail_gap\":[]}",
  ).unwrap()
  assert_eq(forced[2].to_int(), 0x40)
  assert_eq(forced[3].to_int(), 0x40)
}
