// 审计回归（2026-11-11）：组项上的 JUSTIFIED / BLANK WHEN ZERO 被静默吞掉。
//
// IBM Enterprise COBOL：
//   - JUSTIFIED 只能用于基本项，且类别为 alphabetic / alphanumeric / national；
//   - BLANK WHEN ZERO 只能用于基本数值项（numeric / numeric-edited）。
//
// 旧解析器对无 PIC 的项照收这两个子句，然后**原地丢弃**：布局/编码完全
// 不生效，也没有任何提示。用户以为 `05 G JUSTIFIED RIGHT.` 会让组内字符
// 右对齐，实际仍是左对齐 —— 与「绝不静默修正」冲突。
//
// 组级 USAGE 与 SIGN 是合法且已实现的继承（`group_usage` / `group_sign`），
// 本测试同时锁定它们不被误伤。

///|
fn gcl_err(cb : String) -> String {
  try {
    let _ = parse_copybook(cb)
    ""
  } catch {
    e => e.to_display()
  }
}

///|
test "group-level JUSTIFIED is rejected (elementary-only clause)" {
  let msg = gcl_err("01 R.\n  05 G JUSTIFIED RIGHT.\n    10 A PIC X(3).\n")
  assert_true(msg.contains("JUSTIFIED"))
  assert_true(msg.contains("G"))
  let msg2 = gcl_err("01 R.\n  05 G JUST RIGHT.\n    10 A PIC X(3).\n")
  assert_true(msg2.contains("JUSTIFIED") || msg2.contains("JUST"))
}

///|
test "group-level BLANK WHEN ZERO is rejected (elementary numeric-only)" {
  let msg = gcl_err("01 R.\n  05 G BLANK WHEN ZERO.\n    10 A PIC 9(3).\n")
  assert_true(msg.contains("BLANK WHEN ZERO"))
  assert_true(msg.contains("G"))
}

///|
test "elementary JUSTIFIED / BLANK WHEN ZERO and group USAGE/SIGN still work" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(3) JUSTIFIED RIGHT.\n  05 B PIC 9(3) BLANK WHEN ZERO.\n",
    ),
  )
  assert_true(layout.find("R.A").unwrap().pic.justified_right)
  assert_true(layout.find("R.B").unwrap().pic.blank_when_zero)
  // 组级 USAGE / SIGN 继承不受影响
  let g = compile_layout(
    parse_copybook(
      "01 R.\n  05 G USAGE COMP-3.\n    10 A PIC 9(3).\n  05 H SIGN IS LEADING.\n    10 B PIC S9(3).\n",
    ),
  )
  inspect(g.find("R.G.A").unwrap().byte_length, content="2")
  assert_true(g.find("R.H.B").unwrap().pic.sign_leading)
}
