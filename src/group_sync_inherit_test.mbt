// 审计回归（2026-11-13）：组级 `SYNC` / `SYNCHRONIZED` 被静默丢弃。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     000100 01 R.
//     000200    05 G SYNC.
//     000300       10 A PIC S9(4) COMP.
//     000400       10 B PIC X(2).
//     000500    05 C PIC X(1).
//
//     $ copybook layout --copybook gsync.cpy
//     RECORD: R                                        LENGTH: 5 bytes
//     OFFSET  LENGTH  OCCURS  TYPE              NAME
//          0       2       1  S9(4) COMP        R.G.A
//          2       2       1  X(2) DISPLAY      R.G.B
//          4       1       1  X(1) DISPLAY      R.C
//     exit 0，**零警告**
//
// 叶子级 `05 A PIC S9(4) COMP SYNC.` 会逐行标注
// `[SYNC: alignment not implemented, offsets differ from IBM]` 并在末尾给出
// 汇总警告；写在同一份 copybook 的**组项**上时，同一个 `SYNC` 一个字都不提。
//
// ## 为什么是缺陷
//
// 1. IBM 语义：`SYNCHRONIZED` 写在组项上时**等价于写在组内每个基本项上**
//    （Enterprise COBOL LR, SYNCHRONIZED clause），组内带 SYNC 的 COMP
//    字段同样要求半字/全字对齐、其前可能被填充。本实现既然不解对齐，就必须
//    如实告知 —— README「`SYNC` / `SYNCHRONIZED` 不实现 IBM 对齐」一节承诺
//    「`layout` 命令会对**每个 SYNC 字段**逐行标注并在末尾给出汇总警告」，
//    组级写法落在这个承诺之外，用户拿到一份看起来权威的错布局却没有任何信号。
// 2. 与同族历史一致：组级 `USAGE` / `SIGN` 已实现继承（CB-B6/R6），组级
//    `JUSTIFIED` / `BLANK WHEN ZERO` 因为「声明不生效」被显式拒绝（2026-11-11）。
//    组级 `SYNC` 是同类里唯一既不下传、也不报错的一种：声明被原地丢弃。
//
// ## 修法
//
// 与组级 USAGE/SIGN 同一手法：`build_children` 多带一个 `inherited_sync`，
// 自上而下 OR 进每个基本项的 `is_synced`。叶子级的 `FieldLayout.is_synced`
// 因此对组级与叶子级两种写法都成立，`render_layout` 的既有警告逻辑不用改。
//
// 不受影响：没有 SYNC 的 copybook 输出逐字不变（`is_synced` 恒 false）；
// 布局数字一个都不变（本子集本来就不做对齐填充，这里只补齐「如实告知」）。

///|
fn gsync_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
test "group-level SYNC reaches every elementary item" {
  let layout = gsync_layout(
    "01 R.\n    05 G SYNC.\n        10 A PIC S9(4) COMP.\n        10 B PIC X(2).\n    05 C PIC X(1).\n",
  )
  // 组内两个基本项都必须被标注
  assert_true(layout.find("R.G.A").unwrap().is_synced)
  assert_true(layout.find("R.G.B").unwrap().is_synced)
  // 组外的项不受影响
  assert_false(layout.find("R.C").unwrap().is_synced)
  // 布局数字不变（本子集不做对齐填充）
  inspect(layout.byte_length, content="5")
  inspect(layout.find("R.G.A").unwrap().offset, content="0")
}

///|
test "group-level SYNCHRONIZED spelling behaves the same" {
  let layout = gsync_layout(
    "01 R.\n    05 G SYNCHRONIZED.\n        10 A PIC S9(4) COMP.\n",
  )
  assert_true(layout.find("R.G.A").unwrap().is_synced)
}

///|
test "nested groups inherit SYNC from an outer group" {
  let layout = gsync_layout(
    "01 R.\n    05 G SYNC.\n        10 H.\n            15 A PIC S9(4) COMP.\n    05 C PIC X(1).\n",
  )
  assert_true(layout.find("R.G.H.A").unwrap().is_synced)
  assert_false(layout.find("R.C").unwrap().is_synced)
}

///|
test "layout report warns for group-level SYNC too" {
  let layout = gsync_layout(
    "01 R.\n    05 G SYNC.\n        10 A PIC S9(4) COMP.\n        10 B PIC X(2).\n",
  )
  let text = render_layout(layout)
  assert_true(text.contains("[SYNC: alignment not implemented"))
  assert_true(text.contains("WARNING: 2 field(s) declare SYNC/SYNCHRONIZED"))
}

///|
test "no SYNC anywhere: report and flags unchanged" {
  let layout = gsync_layout(
    "01 R.\n    05 A PIC S9(4) COMP.\n    05 B PIC X(2).\n",
  )
  assert_false(layout.find("R.A").unwrap().is_synced)
  assert_false(render_layout(layout).contains("SYNC"))
}

///|
test "leaf-level SYNC still works and does not leak to siblings" {
  let layout = gsync_layout(
    "01 R.\n    05 A PIC S9(4) COMP SYNC.\n    05 B PIC X(2).\n",
  )
  assert_true(layout.find("R.A").unwrap().is_synced)
  assert_false(layout.find("R.B").unwrap().is_synced)
}
