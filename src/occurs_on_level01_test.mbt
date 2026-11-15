// 审计回归（2026-11-15）：OCCURS 子句写在 01 / 77 层被静默接受并展开。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     01 R OCCURS 3 TIMES.
//        05 A PIC X(2).
//     -> layout exit 0，RECORD LENGTH 6 bytes，A(1)/A(2)/A(3)
//     77 W OCCURS 2 TIMES PIC X(1).
//     -> layout exit 0，RECORD LENGTH 2 bytes，W(1)/W(2)
//
// ## 依据与裁定
//
// IBM Enterprise COBOL 明确规定「The OCCURS clause cannot be used in a
// level-01 description」（IGYDS1063-E，COBOL for Linux on xACE 同样报
// error）；level-77 同禁。GnuCOBOL 默认接受 level-01 OCCURS 属方言扩展
// （`-std=ibm-strict` 下同样拒绝）。本项目目标平台是 IBM z/OS，按 IBM
// 规则显式报错 —— 与 INDEXED BY 的「子集边界显式报错」同族，而不是
// 静默按方言扩展把记录展开成 n 份（那等于凭空发明一个 COBOL 不存在的
// 存储声明，且记录长度 ×n 无任何提示）。
//
// 02..49 层的 OCCURS（含组级与叶级、ODO、嵌套展开）不受影响。

///|
fn occ_err(cb : String) -> String {
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
test "OCCURS on level 01 must be a syntax error (IGYDS1063-E)" {
  let msg = occ_err("01 R OCCURS 3 TIMES.\n  05 A PIC X(2).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("OCCURS"))
  assert_true(msg.contains("01"))
  assert_true(msg.contains("'R'"))
}

///|
test "OCCURS on level 77 must be a syntax error" {
  let msg = occ_err("77 W OCCURS 2 TIMES PIC X(1).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("OCCURS"))
  assert_true(msg.contains("77"))
  assert_true(msg.contains("'W'"))
}

///|
test "OCCURS ... DEPENDING ON on level 01 is equally rejected" {
  let msg = occ_err(
    "01 R OCCURS 1 TO 5 TIMES DEPENDING ON CNT.\n  05 A PIC X(2).\n",
  )
  assert_true(msg != "ok")
  assert_true(msg.contains("OCCURS"))
}

///|
test "OCCURS 1 TIMES (explicit) on level 01 is still rejected" {
  // 子句本身非法，与次数无关 —— IBM 的规则约束的是子句，不是次数
  let msg = occ_err("01 R OCCURS 1 TIMES.\n  05 A PIC X(2).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("OCCURS"))
}

///|
test "OCCURS on 02..49 levels is untouched" {
  // 组级 + 叶级 + ODO 的既有行为不变（回归守卫）
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G OCCURS 2 TIMES.\n    10 A PIC X(2).\n  05 B PIC 9(2) OCCURS 3 TIMES.\n",
    ),
  )
  inspect(layout.byte_length, content="10")
  inspect(layout.fields.length(), content="5")
}
