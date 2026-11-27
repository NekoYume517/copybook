// CB-22-1（2026-11-27 第二十二轮审计）：**SYNC 空声明警告有两套文案**。
//
// ## 缺陷形态
//
// CB-21-2 把「受 SYNC 影响的字段数」收敛成唯一权威 `RecordLayout::sync_summary`，
// 但同一份 `SyncSummary` 的**另一半**（`inert_groups`，你写了 SYNC 却什么都没
// 影响）没有跟上：`output.mbt` 侧有 `layout_sync_inert_warning(paths)`，注释写着
// 「`render_layout` 的报告共用它」；CLI 侧却在 `warn_sync_layout` 里**手写了一遍
// 字符串**，直接把 `layout_sync_inert_warning` 绕过。
//
// 两个实现当时就已经分叉了 —— 实测（native 二进制）：
//
// ```
// layout : WARNING: 1 group item(s) declare ... no basic item: R.G.
//          No offset changes; the declaration has no effect **on this layout**.
// decode : warning: 1 group item(s) declare ... no basic item: R.G.
//          No offset changes; the declaration has no effect.
// verify : warning: 1 group item(s) declare ... no basic item: R.G.
//          No offset changes; the declaration has no effect.
// ```
//
// 差 12 个字符（` on this layout`）。这正是 CB-21-2 那条教训的第二次复现：
// 「同一个结论在一个方向写了、另一个方向又写了一遍」。
//
// ## 判据（双向）
//
// 1. 正向：`layout_sync_inert_warning` 必须点名那个组、必须说「无影响」，
//    且 `render_layout` 必须**逐字包含**它（否则「相等」可以靠空串蒙过去）；
// 2. 反向：`affected_leaves` 必须为 0 —— 这条告警存在的**前提**是「一个基本项
//    都没被点亮」。若样本其实点亮了叶子，这条测试就测在另一条分支上了。

///|
fn inert_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 G SYNC.\n  05 A PIC X.\n"))
}

///|
test "inert SYNC warning has exactly one wording" {
  let layout = inert_layout()
  let sync = layout.sync_summary()
  // 反向判据：前提必须成立。
  assert_eq(sync.affected_leaves, 0)
  assert_eq(sync.inert_groups, ["R.G"])
  let canonical = layout_sync_inert_warning(sync.inert_groups)
  assert_true(canonical.contains("R.G"))
  assert_true(canonical.contains("no effect on this layout"))
  // render_layout 必须逐字用它，而不是再写一遍。
  let rendered = render_layout(layout)
  assert_true(rendered.contains(canonical))
}
