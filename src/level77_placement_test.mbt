// CB-B11（2026-11-10 审计）：77 层级被当普通数据项静默挂进前面的组。
//
// ## 缺陷形态（修复前）
//
// `_probe/p09c_l77.cpy`：
//
//     01 R.
//        05 G.
//        77 C PIC X(1).
//
// exit 0，布局里出现叶子 `R.G.C` —— 77 是**独立独立项**（standalone item），
// 不参与层级号建树，COBOL 规定它必须是顶层项、不能出现在任何组内。旧实现
// 只按 `level > parent_level` 判子树，77 自然成了 `05 G` 的子项。
//
// ## 为什么必须报错而不是「当作兄弟」
//
// 一条记录里 77 出现在组内时，作者的意图无法判定（是想写成两个独立项？
// 还是缩进/层级号写错了？）。本实现把多个顶层项**并列拼接**（见
// `compile_layout`），若把 77 提升成顶层会静默改变记录长度与偏移；若留在
// 组内则给出 `R.G.C` 这种 COBOL 里不存在的路径。两者都是静默修正，
// 所以按项目第一原则显式报错。
//
// 顶层 77（`77 WS-FLAG PIC X(1).` 与 `01` 并列）保持既有行为 ——
// `parser_test.mbt` 的「tree: 77 独立项」锁定了它。

///|
fn l77_err(cb : String) -> String {
  try {
    let _ = compile_layout(parse_copybook(cb))
    "ok"
  } catch {
    e => e.to_display()
  } noraise {
    _ => "ok"
  }
}

///|
test "CB-B11: 组内出现 77 被拒绝（p09c）" {
  let msg = l77_err("01 R.\n    05 G.\n    77 C PIC X(1).\n")
  assert_true(msg != "ok")
  // 报错点名 77 与字段名，并说明 77 必须是顶层项
  assert_true(msg.contains("77"))
  assert_true(msg.contains("'C'"))
}

///|
test "CB-B11: 77 出现在 01 组内同样被拒绝" {
  let msg = l77_err("01 R.\n    77 A PIC X(1).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("77"))
}

///|
test "CB-B11: 顶层 77 的既有行为不变（p09 / p09b 仍被拒绝）" {
  // 基线实测（_probe/p09_l77.layout.err、p09b_l77.layout.err）：77 跟在
  // 01 之后时，本实现按层级号把它当上一项的子项 —— 两者都 exit 1，
  // 报「基本项 'A'/'X' 带 PIC 子句，不能有下级项」。
  //
  // 修复后两者**仍然被拒绝**（行为不变），文案换成指向真因的那条：
  // 「77 级项 'B'/'C' 不能出现在组内」。旧文案把根因说成 A / X 带 PIC
  // （两者本身完全合法），属误导，随语义修正一并更新 —— 这是本提交唯一
  // 的对外可见文案变更，已在 commit 正文写明。
  let p09 = l77_err("01 R.\n    05 A PIC X(1).\n    77 B PIC X(1).\n")
  assert_true(p09 != "ok")
  assert_true(p09.contains("77"))
  assert_true(p09.contains("'B'"))

  let p09b = l77_err(
    "01 R.\n    05 G.\n        10 X PIC X(1).\n    77 C PIC X(1).\n",
  )
  assert_true(p09b != "ok")
  assert_true(p09b.contains("77"))
  assert_true(p09b.contains("'C'"))

  // 单独一个 77 文件（真正的独立项用法）保持既有行为，exit 0
  let only = compile_layout(parse_copybook("77 WS-FLAG PIC X(1).\n"))
  inspect(only.byte_length, content="1")
  inspect(only.name, content="WS-FLAG")
}
