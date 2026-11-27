// CB-22-3（2026-11-27 第二十二轮审计）：把 `API.md:503-505` 的**同源断言**写成测试。
//
// `API.md` 原话：
//
// > 判据与 `src/encode.mbt` 的 `filler_gaps` / `primary_tail_gaps` 同源
// > （`RecordLayout::layout_static_gaps` 只是把两者在 `values = None` 下的
// > 结果并起来），不新起一套区间逻辑。
//
// 这句是「`HOLES:` 行与编码器空洞判定不会分叉」的唯一论据，但此前只有人眼。
// 一旦有人给 `layout_static_gaps` 加个特例（比如滤掉某类区间），文档与实现就
// 悄悄分叉，而 `HOLES:` 会开始对外播报一个编码器不认的数字。
//
// 判据（双向）：
//
// 1. 正向：`layout_static_gaps(lay)` 必须**逐项等于**「尾部洞 + 中部洞、按起点
//    升序」的合并结果；
// 2. 反向：至少要有一份布局能产出**非空**的两侧（否则两个空数组总相等，
//    「相等」是假的 —— 驻点假绿）。

///|
/// 「尾部洞 + 中部洞」的参考合并（测试里的独立实现，不调被测函数）。
fn lsg_reference(layout : RecordLayout) -> Array[(Int32, Int32)] {
  let out : Array[(Int32, Int32)] = []
  for iv in primary_tail_gaps(layout, None) {
    out.push(iv)
  }
  for iv in filler_gaps(layout, None) {
    out.push(iv)
  }
  out.sort_by(fn(x, y) { x.0 - y.0 })
  out
}

///|
/// 布局样本：必须**两侧都非空**才有判别力。
fn lsg_samples() -> Array[String] {
  [
    // 中部 FILLER 洞 + 尾部视图洞同时存在
    "01 R.\n  05 A PIC X.\n  05 FILLER PIC X(2).\n  05 B PIC X.\n  05 V REDEFINES B PIC X(3).\n",
    // 只有中部洞
     "01 R.\n  05 A PIC X.\n  05 FILLER PIC X(3).\n  05 B PIC X.\n",
    // 只有尾部洞
     "01 R.\n  05 M PIC X(2).\n  05 V2 REDEFINES M PIC X(5).\n",
    // 没有洞
     "01 R.\n  05 A PIC X(2).\n  05 B PIC X(2).\n",
  ]
}

///|
test "layout_static_gaps is exactly filler_gaps + primary_tail_gaps at values=None" {
  for src in lsg_samples() {
    let lay = compile_layout(parse_copybook(src))
    assert_eq(layout_static_gaps(lay), lsg_reference(lay))
  }
}

///|
test "the reference merge is non-trivial (both sides actually contribute)" {
  // 反向判据：有一份布局能同时产出**中部**与**尾部**洞，且两者都非空。
  let lay = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X.\n  05 FILLER PIC X(2).\n  05 B PIC X.\n  05 V REDEFINES B PIC X(3).\n",
    ),
  )
  let mid = filler_gaps(lay, None)
  let tail = primary_tail_gaps(lay, None)
  assert_true(mid.length() > 0)
  assert_true(tail.length() > 0)
  // 合并结果两项都对得上
  let total = layout_static_gaps(lay)
  assert_eq(total.length(), mid.length() + tail.length())
}
