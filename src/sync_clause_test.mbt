// SYNC / SYNCHRONIZED 的显式声明回归（2026-11-04 对抗性审计 NEW-4）。
//
// ## 缺陷形态（修复前）
//
// `parser.mbt` 对 `SYNC` / `SYNCHRONIZED` 子句的处理是「advance 之后丢弃」，
// 布局按无填充计算。而 IBM 上 SYNC 是**对齐要求**：
//
// ```cobol
// 01  R.
//     05  A  PIC X(1).
//     05  B  PIC S9(4) COMP SYNC.
//     05  C  PIC X(1).
// ```
//
// IBM 布局：A@0、`B@2`（对齐到偶偏移，A 后补 1 字节 slack）、C@4 → **5 字节**。
// 修复前本实现给出：A@0、B@1、C@3 → **4 字节**，exit 0，无任何提示。
//
// 危害：拿这份布局去解码真实主机数据，`B` 会从错误的偏移读 2 字节，
// 每个 COMP 数值都是错位的错误值。而 `verify` **抓不到**——布局自洽，
// decode→encode 当然逐字节一致。这是「看起来成功、内容是错的」那一类。
//
// ## 本轮修复的范围（诚实说明）
//
// **不实现 IBM 对齐**。理由：对齐会改变全部现有布局语义与偏移（半字/全字、
// COMP-1/2/3 各不相同，还牵涉组项边界），是一个独立的功能级改动，在
// 「修 bug」的范畴里做等于悄悄改变公开契约。
//
// 本轮做的是**让缺陷可见**：
//   1. `SYNC` 不再被静默吞掉，而是记录到 `FieldLayout.is_synced`；
//   2. `layout` 输出对每个 SYNC 字段逐行标注，并在末尾给出汇总警告；
//   3. 用户文档（README 的「已声明的简化」清单）写明这条限制。
//
// 这样使用者在同一条命令的输出里就能看到「这份 copybook 有 SYNC，偏移与
// IBM 不同」，而不是等到数值算错才怀疑工具。

///|
fn sync_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  A  PIC X(1).\n    05  B  PIC S9(4) COMP SYNC.\n    05  C  PIC X(1).\n",
    ),
  )
}

///|
fn sync_layout_abbrev() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01  R.\n    05  A  PIC X(1).\n    05  B  PIC S9(4) COMP SYNCHRONIZED.\n    05  C  PIC X(1).\n",
    ),
  )
}

///|
test "NEW-4: SYNC 被记录到 FieldLayout.is_synced，不再静默丢弃" {
  let layout = sync_layout()
  let b = layout.find("R.B").unwrap()
  assert_true(b.is_synced)
  let a = layout.find("R.A").unwrap()
  assert_false(a.is_synced)
  let c = layout.find("R.C").unwrap()
  assert_false(c.is_synced)
  // SYNCHRONIZED 与 SYNC 是同一子句的两种拼写
  let layout2 = sync_layout_abbrev()
  assert_true(layout2.find("R.B").unwrap().is_synced)
}

///|
test "NEW-4: layout 输出逐行标注 SYNC 并给出汇总警告" {
  let layout = sync_layout()
  let text = render_layout(layout)
  // 逐行标注：B 那行带标记
  assert_true(
    text.contains("[SYNC: alignment not implemented, offsets differ from IBM]"),
  )
  // 汇总警告
  assert_true(text.contains("WARNING:"))
  assert_true(text.contains("SYNC/SYNCHRONIZED"))
  // 布局本身仍是「不对齐」的旧口径（记录 4 字节），这是**已知限制**而非回归：
  // 若将来实现对齐，这条断言会红，届时同步更新为 IBM 的 5 字节。
  inspect(layout.byte_length, content="4")
}

///|
test "NEW-4: 没有 SYNC 的 copybook 输出保持不变（不加任何警告）" {
  let layout = compile_layout(
    parse_copybook("01  R.\n    05  A  PIC X(4).\n    05  B  PIC 9(3).\n"),
  )
  let text = render_layout(layout)
  assert_false(text.contains("SYNC"))
  assert_false(text.contains("WARNING"))
}
