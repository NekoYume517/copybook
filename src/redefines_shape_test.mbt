// CB-B10（2026-11-10 审计）：非法 REDEFINES 形态被静默接受。
//
// ## 缺陷形态（修复前）
//
// `layout` 对下面两份 copybook 都 exit 0，给出看起来权威的布局：
//
//   p07：`05 A X(2). 05 B X(2). 05 C REDEFINES A X(4).`
//        → C 的 4 字节覆盖 A(0..2) **和 B(2..4)**，记录 4 字节
//   p08：`01 A. 05 X X(2). 01 B. 05 Y REDEFINES X X(4).`
//        → **跨 01 重定义**也照做
//
// 两者在 COBOL 里都是无效的。p08 违反「重定义项与被重定义项必须同一父项」；
// p07 的危害是数据面静默损坏：`decode` 把同一段字节解两遍、`encode` 里后写的
// C 会盖掉 B 的值，而 `verify` 因布局自洽仍报 byte-identical。
//
// ## 本轮实现的两条硬校验
//
// 1. **同层同父**：视图与被重定义项必须同一父项（跨 01、跨组一律拒绝）。
// 2. **视图不得吞掉其他字段的字节**：视图跨度不得与任何一个「已就位、且不在
//    同一重定义组」的可解码叶子重叠，01 层除外。
//
// 第 2 条是审计要求的「视图长度 ≤ 目标长度」的**等价改写**，取舍见文件末尾
// 「为什么不是字面规则」。
//
// 不做「必须紧邻前项」：重定义链（D→A→B）合法且复杂，风险大于收益（Lead 已定）。

///|
fn redef_err(cb : String) -> String {
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
test "CB-B10: 视图吞掉兄弟字段的字节被拒绝（p07）" {
  // C X(4) 覆盖 A(0..2) + B(2..4)：B 的字节被 C 无声吃掉
  let msg = redef_err(
    "01 R.\n  05 A PIC X(2).\n  05 B PIC X(2).\n  05 C REDEFINES A PIC X(4).\n",
  )
  assert_true(msg.contains("REDEFINES"))
  // 报错必须指出是哪个视图、撞上了谁 —— 否则用户无从下手
  assert_true(msg.contains("R.C"))
  assert_true(msg.contains("R.B"))
}

///|
test "CB-B10: 跨 01 重定义被拒绝（必须同一父项，p08）" {
  let msg = redef_err(
    "01 A.\n  05 X PIC X(2).\n01 B.\n  05 Y REDEFINES X PIC X(4).\n",
  )
  assert_true(msg.contains("REDEFINES"))
  assert_true(msg.contains("'Y'"))
  assert_true(msg.contains("'X'"))
  // 说明违反的是「父项」这条规则
  assert_true(msg.contains("same parent") || msg.contains("父"))
}

///|
test "CB-B10: 跨组（兄弟组之间）重定义同样被拒绝" {
  let msg = redef_err(
    "01 R.\n  05 G1.\n    10 X PIC X(2).\n  05 G2.\n    10 Y REDEFINES X PIC X(2).\n",
  )
  assert_true(msg.contains("REDEFINES"))
  assert_true(msg.contains("same parent") || msg.contains("父"))
}

///|
test "CB-B10: 合法 REDEFINES 形态全部不受影响" {
  // 等长
  inspect(
    redef_err("01 R.\n  05 A PIC X(4).\n  05 B REDEFINES A PIC X(4).\n"),
    content="ok",
  )
  // 视图短于目标（部分重定义）
  inspect(
    redef_err("01 R.\n  05 A PIC X(4).\n  05 B REDEFINES A PIC X(2).\n"),
    content="ok",
  )
  // 组视图、组内求和等于目标
  inspect(
    redef_err(
      "01 R.\n  05 M PIC S9(3) COMP-3.\n  05 V REDEFINES M.\n    10 RAW PIC X(2).\n",
    ),
    content="ok",
  )
  // 同组的多个视图（A 被 B、C 同时重定义）
  inspect(
    redef_err(
      "01 R.\n  05 A PIC X(2).\n  05 B REDEFINES A PIC X(2).\n  05 C REDEFINES A PIC X(2).\n",
    ),
    content="ok",
  )
}

///|
test "CB-B10: 视图长于目标但落在记录尾部空洞的形态保持合法（CB-9 契约）" {
  // 既有锁定契约：视图比主视图长、超出部分只覆盖「没有别的字段」的尾部，
  // 由 __tail_hex / __filler_hex 保真。本轮修复不能误杀它。
  let cb = "01 R.\n  05 M PIC S9(3) COMP-3.\n  05 A REDEFINES M.\n    10 RAW PIC X(4).\n"
  inspect(redef_err(cb), content="ok")
  let layout = compile_layout(parse_copybook(cb))
  inspect(layout.byte_length, content="4")
}

///|
test "CB-B10: examples/redefines.cpy 的权威 29 字节布局保持" {
  let layout = compile_layout(
    parse_copybook(
      "01  ACCOUNT-MASTER.\n    05  ACCT-NO        PIC 9(12).\n    05  ACCT-TYPE      PIC X(2).\n    05  LIMIT-AMT      PIC S9(9)V99 COMP-3.\n    05  ALT-VIEW REDEFINES LIMIT-AMT.\n        10  RAW-BYTE   PIC X(6).\n    05  SSN            PIC 9(9).\n",
    ),
  )
  inspect(layout.byte_length, content="29")
  inspect(layout.find("LIMIT-AMT").unwrap().offset, content="14")
  inspect(layout.find("RAW-BYTE").unwrap().offset, content="14")
}

// ## 为什么不是字面规则「视图长度 ≤ 目标长度」
//
// 字面规则会打掉 6 条既有锁定测试，它们正是 CB-9 / CB-15 / CB-16 建立的
// **尾部保真机制**（README 与 FIDELITY.md 都把它列为受支持形态）：
//
//   redefines_tail_test   05 M COMP-3(3) ← 05 A REDEFINES M { RAW X(4) }
//   gap_combo_test        ……同款视图更长的形态，验中部 FILLER + 尾部空洞
//   view_gap_test         05 M 9(2) ← 05 V REDEFINES M X(3) / 05 M X(2) ← V X(4)
//   jsonl_gap_len_test    05 A X(4) ← 05 V REDEFINES A X(6)
//
// 这些视图的超出部分只覆盖「该处没有其他字段」的区间，字节由旁路键保真，
// 数据面没有歧义。而 p07 的危害恰恰不同：C 的超出部分**压在 B 身上**。
// 所以本轮把规则收敛为「视图不得与同层其他字段的字节重叠」——
// 它精确命中 p07（C 撞 B）与 p08（跨父项），又不误伤上述 6 条契约。
