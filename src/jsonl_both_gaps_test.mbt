// 2026-11-17 审计 C6：两条空洞几何旁路**同时出现**的组合没有任何测试。
//
// ## 为什么这条要紧
//
// CB-15 的原始缺陷正是「中部 FILLER + REDEFINES 尾部并存」：`__tail_hex` 与
// `__filler_hex` 两段字节塞进一个 `tail` 变量、两轮循环共用一个递增的 `idx`，
// 于是先处理的区间吃掉第二段的字节、剩下的真实空洞静默填成 0x40。
// 修复后各键用自己的游标，但**没有一条测试同时产出两组键**：
//
//   - `view_gap_test.mbt`            只有中部（无尾部）；
//   - `jsonl_gap_geometry_test.mbt`  shape 1/2 只有尾部、shape 3 只有中部；
//   - `all_filler_test.mbt`          只有全 FILLER（`fields` 为空）。
//
// 需要「中部静态 FILLER 洞 + 尾部视图洞」的布局才同时产两组键。下面这份：
//
//     01 R.
//        05 M        PIC X(2).          offset 0..2   （主视图）
//        05 FILLER   PIC X(2).          offset 2..4   （中部洞）
//        05 B        PIC X(2).          offset 4..6   （主视图）
//        05 V REDEFINES B PIC X(6).     offset 4..10  （尾部洞 6..10）
//
// 记录 10 字节：M="AB"、B="EF"、V 解不出（FF EE F7 F8 不可打印）→
// `__filler_hex:"c3c4"` + `__filler_gap:[[2,4]]` 与
// `__tail_hex:"ffeef7f8"` + `__tail_gap:[[6,10]]` 必须同时出现，且往返逐字节一致。

///|
fn c6_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(2).\n  05 FILLER PIC X(2).\n  05 B PIC X(2).\n  05 V REDEFINES B PIC X(6).\n",
    ),
  )
}

///|
fn c6_record() -> Bytes {
  bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE, 0xF7, 0xF8])
}

///|
test "C6: both hole carriers appear in one JSONL line" {
  let layout = c6_layout()
  inspect(layout.byte_length, content="10")
  let text = render_jsonl(layout, [decode_record(layout, c6_record()).unwrap()])
  assert_true(text.contains("\"__filler_hex\":\"c3c4\""))
  assert_true(text.contains("\"__filler_gap\":[[2,4]]"))
  assert_true(text.contains("\"__tail_hex\":\"ffeef7f8\""))
  assert_true(text.contains("\"__tail_gap\":[[6,10]]"))
}

///|
test "C6: both carriers round-trip byte for byte" {
  let layout = c6_layout()
  let rec = c6_record()
  let line = render_jsonl(layout, [decode_record(layout, rec).unwrap()])
    .trim_end()
    .to_string()
  match parse_jsonl_row(layout, line) {
    Err(e) => fail("the exported row must parse back: \{e}")
    Ok(row) =>
      match encode_record(layout, row) {
        Ok(b) => assert_eq(b, rec)
        Err(e) => fail("both-carrier roundtrip must encode: \{e.to_display()}")
      }
  }
  // 内存路径（verify）对同一份字节给出同一结论
  match roundtrip_check(layout, rec) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(e) => fail("roundtrip must not error: \{e.to_display()}")
  }
}

///|
test "C6: editing the tail view keeps the FILLER hole and the edit" {
  let layout = c6_layout()
  let row = parse_jsonl_row(
    layout,
    render_jsonl(layout, [decode_record(layout, c6_record()).unwrap()])
    .trim_end()
    .to_string(),
  ).unwrap()
  // 把视图编辑成可打印的 6 字节：尾部空洞消失，中部 FILLER 洞仍由 __filler_hex 回填
  row["R.V"] = Text("CDEFGH")
  match encode_record(layout, row) {
    Err(e) => fail("editing the view must encode: \{e.to_display()}")
    Ok(b) => {
      // 中部洞 [2,4) 保住原始 C3 C4
      assert_eq(b[2].to_int(), 0xC3)
      assert_eq(b[3].to_int(), 0xC4)
      // 视图写满 [4,10)：编辑生效，旧快照不得覆盖回来
      assert_eq(b[4].to_int(), 0xC3)
      assert_eq(b[5].to_int(), 0xC4)
      assert_eq(b[6].to_int(), 0xC5)
      assert_eq(b[7].to_int(), 0xC6)
      assert_eq(b[8].to_int(), 0xC7)
      assert_eq(b[9].to_int(), 0xC8)
    }
  }
}

///|
test "C6: the legacy path (no gap keys) still round-trips with both carriers" {
  // 2026-11-12 之前的 JSONL：没有 __tail_gap / __filler_gap，两个快照按各自
  // 空洞的顺序回填。CB-15 的原始缺陷就发生在这条路径上（两段字节共用一个
  // 递增游标），所以这条也要锁住 —— 迁移前提是旧文件一字不改地保持原行为。
  let layout = c6_layout()
  let rec = c6_record()
  let line = "{\"R.M\":\"AB\",\"R.B\":\"EF\",\"R.V\":null,\"__tail_hex\":\"ffeef7f8\",\"__filler_hex\":\"c3c4\"}"
  match parse_jsonl_row(layout, line) {
    Err(e) => fail("legacy row must parse: \{e}")
    Ok(row) =>
      match encode_record(layout, row) {
        Ok(b) => assert_eq(b, rec)
        Err(e) => fail("legacy both-carrier row must encode: \{e.to_display()}")
      }
  }
}
