// 审计回归（2026-11-15）：B3（c13f55d）判据不完备 —— 多区间 `__tail_gap`
// 带「中洞」仍能通过全部三条校验，洞里的字节被静默填成 0x40。
//
// ## 缺陷形态（修复前，CLI 实测，copybook / 数据与
// jsonl_gap_geometry_strict_test 同源）
//
//     decode -> __tail_hex "ffeef7f8"，__tail_gap [[6,10]]
//     攻击行：{"__tail_hex":"ffaaf7","__tail_gap":[[6,7],[8,10]]}
//       -> exit 0，输出 c1..c6 ff 40 aa f7 —— 第 7 字节（原始 EE）静默变空格
//
// [[6,7],[8,10]] 升序不相交 ✓、末段 [8,10] 结束于记录末尾 ✓、全部落在超集
// [6,10) 内 ✓ —— 2026-11-13 的三条判据全绿。但 **decode 的尾部空洞恒为单个
// 后缀区间**：尾部区间 [主视图结束, byte_length) 里写字节的只有重定义视图，
// 视图都从目标起点开始、覆盖该区间的前缀，空洞恒等于 [max(写者结束),
// byte_length)。多区间不可能是 decode 的输出；合法编辑（尾部收缩 / 前缀
// 扩张）只会让空洞从**左端**收缩，也不会在中间打洞。因此尾部几何必须是
// **恰好一个**区间 —— B3 的「结束于记录末尾」只约束了最后一段，漏掉了
// 「中洞」形态。
//
// 中部空洞（__filler_gap）不受影响：两个 FILLER 天然产出两个区间，
// 仍只受「升序不相交」约束。

///|
fn tg_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 M PIC X(2).\n  05 V2 REDEFINES M PIC X(4).\n  05 V4 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
fn tg_encode_result(
  layout : RecordLayout,
  line : String,
) -> Result[Bytes, String] {
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
test "multi-interval tail geometry with an interior hole must be rejected" {
  let layout = tg_layout()
  match
    tg_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V4\":null,\"__tail_hex\":\"ffaaf7\",\"__tail_gap\":[[6,7],[8,10]]}",
    ) {
    Err(e) => assert_true(e.contains("__tail_gap"))
    Ok(b) =>
      fail(
        "tail geometry with an interior hole must be rejected, got \{b.length()} byte(s)",
      )
  }
}

///|
test "contiguous multi-interval tail geometry must also be rejected" {
  // 即使区间连续拼成完整后缀，decode 也从不产出多区间尾部几何：
  // 按「decode 可能的输出」严格收敛，不做拼接猜测。
  let layout = tg_layout()
  match
    tg_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V4\":null,\"__tail_hex\":\"ffaaf7f8\",\"__tail_gap\":[[6,7],[7,10]]}",
    ) {
    Err(e) => assert_true(e.contains("__tail_gap"))
    Ok(_) => fail("multi-interval tail geometry must be rejected")
  }
}

///|
test "single suffix geometry still encodes byte-exactly" {
  let layout = tg_layout()
  match
    tg_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,10]]}",
    ) {
    Err(e) => fail("single-suffix geometry must still encode: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 10)
      assert_eq(b[6].to_int(), 0xFF)
      assert_eq(b[7].to_int(), 0xEE)
      assert_eq(b[8].to_int(), 0xF7)
      assert_eq(b[9].to_int(), 0xF8)
    }
  }
}

///|
test "decode keeps emitting exactly one tail interval" {
  let layout = tg_layout()
  let row = decode_record(
    layout,
    bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE, 0xF7, 0xF8]),
  ).unwrap()
  assert_true(render_jsonl(layout, [row]).contains("\"__tail_gap\":[[6,10]]"))
}
