// 审计回归（2026-11-12）：HANDOVER 16.5 遗留第 2 条 —— B7 的 fallback 只覆盖
// 「全视图不写」的超集快照，「部分视图解出 + 编辑」仍被长度校验挡住。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     01 R.
//        05 M  PIC X(4).
//        05 V2 REDEFINES M PIC X(6).
//        05 V3 REDEFINES M PIC X(8).
//
// decode `C1 C2 C3 C4 C5 C6 FF EE`：
//
//     {"R.M":"ABCD","R.V2":"ABCDEF","R.V3":null,"__tail_hex":"ffee"}
//
// （M 与 V2 解出、V3 含不可打印字节置 Null，尾部空洞 = [6,8) = 2 字节）
//
// 用户把唯一为 null 的 V3 改成 "ABCDEFGH"，其余键原样留着，encode：
//
//     exit 1  __tail_hex must be exactly 0 byte(s) for this record's tail gap(s), got 2
//
// 快照长度 2 既不等于**当前**空洞数 0（V3 已覆盖 6..8），也不等于「全视图
// 不写」的超集 4（B7 的 fallback 只认这一个长度），于是这条合法编辑被
// 长度校验挡住 —— 与 CB-16「旁路快照压过编辑」同族，只是方向相反。
//
// ## 修法（保守，不猜位置）
//
// 快照字节全部落在尾部区间 `[主视图结束偏移, byte_length)` 内。**当前空洞集
// 为空**意味着这段区间里每个字节都由某个字段值写出，快照指向的位置全部被
// 编辑覆盖 —— 无论它当初对应哪几个位置，都没有任何字节需要回填，丢弃它
// 不会丢信息（这是唯一不靠元数据也能证明安全的形态）。
//
// 仍然可能含糊的形态（空洞非空、快照长度既不是当前空洞数也不是超集数）
// 保持报错：把 2 字节按猜出来的位置塞进 4 字节区间才是真正的静默改字节。

///|
fn pv_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(4).\n  05 V2 REDEFINES M PIC X(6).\n  05 V3 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
fn pv_decode_record(rec : Bytes) -> String raise ParseError {
  let layout = pv_layout()
  let row = decode_record(layout, rec).unwrap()
  render_jsonl(layout, [row])
}

///|
test "stale tail snapshot: decode leaves a 2-byte hole when one view fails" {
  let text = pv_decode_record(
    bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE]),
  )
  // **契约变更（B1，2026-11-12）**：decode 的 JSONL 现在同时带出空洞区间
  // `__tail_gap`，供 encode 端按绝对位置映射（N4 只修了「当前空洞为空」一档）。
  // 这是输出格式的扩展，不是测试被削弱。
  inspect(
    text,
    content="{\"R.M\":\"ABCD\",\"R.V2\":\"ABCDEF\",\"R.V3\":null,\"__tail_hex\":\"ffee\",\"__tail_gap\":[[6,8]]}\n",
  )
}

///|
test "stale tail snapshot: editing the null view is not blocked by the old snapshot" {
  let layout = pv_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.M\":\"ABCD\",\"R.V2\":\"ABCDEF\",\"R.V3\":\"ABCDEFGH\",\"__tail_hex\":\"ffee\"}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) =>
      fail("editing the failed view must encode, got: \{e.to_display()}")
    Ok(b) => {
      // V3 覆盖 0..8，三个字段按定义顺序写：最后落盘的是 V3 的值
      // （cp037 EBCDIC：A..H = C1..C8）
      assert_eq(b.length(), 8)
      let want = [0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8]
      for i in 0..<8 {
        assert_eq(b[i].to_int(), want[i])
      }
    }
  }
}

///|
test "stale tail snapshot: an unedited row still restores the hole byte for byte" {
  let layout = pv_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.M\":\"ABCD\",\"R.V2\":\"ABCDEF\",\"R.V3\":null,\"__tail_hex\":\"ffee\"}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) => fail("unedited row must encode: \{e.to_display()}")
    Ok(b) => {
      assert_eq(b.length(), 8)
      assert_eq(b[6].to_int(), 0xFF)
      assert_eq(b[7].to_int(), 0xEE)
    }
  }
}

///|
test "stale tail snapshot: a corrupt length with a real hole still errors" {
  // 空洞非空（V3 仍为 null，空洞 = [6,8) 需要 2 字节），快照给 3 字节：
  // 既不是当前空洞数也不是超集数，含糊 → 必须报错（CB-A2 原意不变）
  let layout = pv_layout()
  let row = parse_jsonl_row(
    layout, "{\"R.M\":\"ABCD\",\"R.V2\":\"ABCDEF\",\"R.V3\":null,\"__tail_hex\":\"ffeeff\"}",
  ).unwrap()
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("__tail_hex"))
    Ok(_) => fail("ambiguous snapshot length must be rejected")
  }
}
