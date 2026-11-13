// 审计回归（2026-11-13）：带几何的空洞快照可以把「字节 + 区间」一起截断
// 或重叠，剩下的空洞被静默填成 0x40。
//
// ## 缺陷形态（修复前，CLI 实测，copybook 见下）
//
//     01 R.
//        05 A  PIC X(2).
//        05 M  PIC X(2).
//        05 V2 REDEFINES M PIC X(4).
//        05 V3 REDEFINES M PIC X(6).
//        05 V4 REDEFINES M PIC X(8).
//     data：C1 C2 C3 C4 C5 C6 FF EE F7 F8（10 字节）
//     decode -> __tail_hex "ffeef7f8"，__tail_gap [[6,10]]
//
//   a) 把快照与几何**同时截断**：`"__tail_hex":"ffee","__tail_gap":[[6,8]]`
//      -> exit 0，输出 `c1..c6 ff ee 40 40` —— [8,10) 的 F7 F8 静默变空格
//   b) 区间**重叠**：`"__tail_hex":"ffeef7f8","__tail_gap":[[6,8],[6,8]]`
//      -> exit 0，输出 `c1..c6 f7 f8 40 40` —— 字节被写到错误位置且尾部丢失
//
// 两种形态在 B1 之前都走长度校验分支（`__tail_hex must be exactly 4 byte(s)
// ... got 2`）而报错；几何旁路把「字节数对、位置不对」的判定交给了用户提供的
// 区间，于是**损坏从「报错」降级成「静默改字节」**——正是 NEW-6 拒绝的形态。
//
// ## 判据（两条都能从 decode 的输出形状证明）
//
// 1. **尾部空洞恒为记录的某个后缀**：尾部区间是 `[主视图结束, byte_length)`，
//    而其中写字节的只有重定义视图（它们都从目标起点开始，即覆盖该区间的
//    前缀），所以空洞恒等于 `[max(写者结束), byte_length)` —— 一个**结束于
//    记录末尾**的区间。几何不结束于记录末尾 ⇒ 不可能是 decode 的输出。
// 2. **区间必须升序且不相交**：`complement_gaps` 产出的永远是极大不相交区间，
//    重叠区间的「总字节数」会重复计数，`__tail_hex` 的字节被错位消费。
//
// 两条都只收紧「不可能是 decode 输出」的形态，不动 B1 锁定的合法编辑：
// 前缀扩张（视图变 null 让空洞向前长）与尾部收缩都仍然通过。

///|
fn gs_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 M PIC X(2).\n  05 V2 REDEFINES M PIC X(4).\n  05 V3 REDEFINES M PIC X(6).\n  05 V4 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
fn gs_encode_result(
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
test "truncated tail snapshot (bytes and geometry together) must be rejected" {
  let layout = gs_layout()
  match
    gs_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffee\",\"__tail_gap\":[[6,8]]}",
    ) {
    Err(e) => assert_true(e.contains("__tail_gap"))
    Ok(b) =>
      fail(
        "truncated tail geometry must be rejected, got \{b.length()} byte(s)",
      )
  }
}

///|
test "overlapping tail intervals must be rejected" {
  let layout = gs_layout()
  match
    gs_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,8],[6,8]]}",
    ) {
    Err(e) => assert_true(e.contains("__tail_gap"))
    Ok(_) => fail("overlapping tail intervals must be rejected")
  }
}

///|
test "overlapping filler intervals must be rejected" {
  // 中部空洞同样只可能是极大不相交区间
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(4).\n  05 B PIC X(2).\n",
    ),
  )
  match
    gs_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.B\":\"EF\",\"__filler_hex\":\"c3c4c3c4\",\"__filler_gap\":[[2,4],[2,4]]}",
    ) {
    Err(e) => assert_true(e.contains("__filler_gap"))
    Ok(_) => fail("overlapping filler intervals must be rejected")
  }
}

///|
test "the B1 contracts still hold: full geometry, prefix widening, shrink" {
  let layout = gs_layout()
  // 1) decode 的原样快照（[6,10)，结束于记录末尾）逐字节往返
  match
    gs_encode_result(
      layout, "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V3\":null,\"R.V4\":null,\"__tail_hex\":\"ffeef7f8\",\"__tail_gap\":[[6,10]]}",
    ) {
    Err(e) => fail("the decoded snapshot must still encode: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 10)
      assert_eq(b[8].to_int(), 0xF7)
      assert_eq(b[9].to_int(), 0xF8)
    }
  }
  // 2) 前缀扩张：V3 变 null 让空洞向前长，快照仍从 [6,10) 绝对映射
  let widened = compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(4).\n  05 V2 REDEFINES M PIC X(6).\n  05 V3 REDEFINES M PIC X(8).\n",
    ),
  )
  match
    gs_encode_result(
      widened, "{\"R.M\":\"ABCD\",\"R.V2\":null,\"R.V3\":null,\"__tail_hex\":\"ffee\",\"__tail_gap\":[[6,8]]}",
    ) {
    Err(e) => fail("B1 shape 2 must still encode: \{e}")
    Ok(b) => {
      assert_eq(b.length(), 8)
      assert_eq(b[4].to_int(), 0x40)
      assert_eq(b[6].to_int(), 0xFF)
      assert_eq(b[7].to_int(), 0xEE)
    }
  }
}

///|
test "decode keeps emitting the canonical suffix geometry" {
  // 判据的来源：decode 写出的尾部区间恒以记录末尾结束
  let layout = gs_layout()
  let row = decode_record(
    layout,
    bs([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xFF, 0xEE, 0xF7, 0xF8]),
  ).unwrap()
  assert_true(render_jsonl(layout, [row]).contains("\"__tail_gap\":[[6,10]]"))
}
