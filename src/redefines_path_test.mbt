// 审计回归（2026-11-11）：REDEFINES 的组 id 按**裸字段名**注册，任何
// 同名但无关的字段都会被错误地算进同一个重定义组，于是
// `check_redefine_overlap` 把它们当成"同一段存储的视图"直接跳过 ——
// 视图吞掉另一个字段的字节也能编译通过。
//
// 形态（修复前 exit 0、布局自洽、verify 报 byte-identical）：
//
//     01 R.
//        05 A PIC X(2).
//        05 G.
//           10 Y PIC X(2).
//        05 Y REDEFINES A PIC X(6).
//
// `collect_redefine_groups` 把名字 "y" 登记为组 1，于是 `R.G.Y`（一个
// 完全无关的字段）也拿到组 1；`R.Y` 的 6 字节覆盖 `R.G.Y` 的 2 字节时，
// 重叠检查看到 `other.redefine_group == view.redefine_group` 就 continue。
// 实际后果：decode 得到两个互相矛盾的视图，encode 后写者覆盖先写者，
// 用户的编辑被静默丢弃。

///|
fn rp_layout_err(src : String) -> String {
  try {
    let _ = compile_layout(parse_copybook(src))
    ""
  } catch {
    e => e.to_display()
  }
}

///|
test "redefines path: same-named field in another group must not hide an overlap" {
  let msg = rp_layout_err(
    "01 R.\n  05 A PIC X(2).\n  05 G.\n    10 Y PIC X(2).\n  05 Y REDEFINES A PIC X(6).\n",
  )
  assert_true(msg.contains("overlaps"))
  assert_true(msg.contains("R.G.Y"))
}

///|
test "redefines path: two unrelated groups with the same leaf name stay separate" {
  // G1.A / G2.A 是 COBOL 常态；G2.B 只重定义 G2.A，不能因为名字撞上
  // G1.A 就把 G1.A 也拖进同一个组。
  let src = "01 R.\n  05 G1.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(4).\n  05 G2.\n    10 A PIC X(2).\n    10 C REDEFINES A PIC X(2).\n"
  let layout = compile_layout(parse_copybook(src))
  let g1a = layout.find("R.G1.A").unwrap()
  let g1b = layout.find("R.G1.B").unwrap()
  let g2a = layout.find("R.G2.A").unwrap()
  let g2c = layout.find("R.G2.C").unwrap()
  assert_eq(g1a.offset, 0)
  assert_eq(g1b.offset, 0)
  assert_eq(g2a.offset, 4)
  assert_eq(g2c.offset, 4)
  inspect(g1a.redefine_group, content=g1b.redefine_group.to_string())
  inspect(g2a.redefine_group, content=g2c.redefine_group.to_string())
  assert_true(g1a.redefine_group != g2a.redefine_group)
}

///|
test "redefines path: target is the sibling, not a nested same-named item" {
  // `B` 里也有一个 `A`。COBOL 的 REDEFINES 目标是**同一父项下的兄弟**，
  // 所以 C 必须落在 R.G.A（offset 0），不是 R.G.B.A（offset 2）。
  let src = "01 R.\n  05 G.\n    10 A PIC X(2).\n    10 B.\n      15 A PIC X(2).\n    10 C REDEFINES A PIC X(2).\n"
  let layout = compile_layout(parse_copybook(src))
  assert_eq(layout.find("R.G.A").unwrap().offset, 0)
  assert_eq(layout.find("R.G.B.A").unwrap().offset, 2)
  assert_eq(layout.find("R.G.C").unwrap().offset, 0)
  assert_eq(layout.byte_length, 4)
}

///|
test "redefines path: top-level target is not a later same-named child" {
  // 顶层 A 在 offset 0；G.A 在 offset 2。B 的裸名查询若命中后者的偏移，
  // 这个完全合法的 copybook 会被布局层自己判成"视图重叠"而拒绝。
  let src = "01 R.\n  05 A PIC X(2).\n  05 G.\n    10 A PIC X(2).\n  05 B REDEFINES A PIC X(2).\n"
  let layout = compile_layout(parse_copybook(src))
  assert_eq(layout.find("R.A").unwrap().offset, 0)
  assert_eq(layout.find("R.B").unwrap().offset, 0)
  assert_eq(layout.find("R.G.A").unwrap().offset, 2)
  assert_eq(layout.byte_length, 4)
}
