// CB-B8（2026-11-10 审计）：自由格式因「列 7 '-'」整文件翻成定长后，
// 前 7 列静默丢弃、报错指向无关位置。
//
// ## 缺陷形态（修复前）
//
// `_probe/p16_flip.cpy`：
//
//     01 R.
//       05 A PIC S9(4)V99 VALUE
//           -123.45.
//
// 第 3 行是「6 空格 + `-` 打头」，命中 `detect_fixed_format_ex` 的追加判定
// （无序号、列 7 为 `-`）→ 整文件翻成定长格式。于是每行前 7 列被当作
// 「序号区 + 指示符」切掉，`01` 的级别号、`05` 的级别号全被吃掉，报错变成：
//
//     2:8: 期望数据描述项（以级别号开头），得到 关键字 'PIC'
//
// 报错既不指向真正的第 3 行，也不说明「文件被判成定长」这个根因 —— 用户
// 会去改第 2 行，而问题在格式判定。
//
// ## CB-4 的遗留缺口
//
// CB-4 已经把「判定原因」写进报错，但只挂在**一条**错误路径上
// （`tokenize` 里「字符串字面量缺少结束引号」）。p16 走的是 parser 的
// 「期望数据描述项」，根本没有这条提示。
//
// ## 本轮修法
//
// 把「本文件被判定为定长格式，因为第 N 行第 7 列是 '-'」这条判定原因
// **附注到所有 Lex/SyntaxError 消息**上（`tokenize` 与 `parse_copybook`
// 统一在外层包装），措辞沿用 CB-4。选这条而不是收窄翻转信号：收窄会回退
// RJ-2 的无序号续行能力（`continuation_test` 与 `format_detect_guard_test`
// 的「真无序号定长续行」用例都锁定了它）。

///|
fn flip_msg(src : String) -> String {
  try {
    let _ = parse_copybook(src)
    "<无错误>"
  } catch {
    e => e.to_display()
  } noraise {
    _ => "<无错误>"
  }
}

// p16_flip.cpy 原文（VALUE 折行 + 6 空格缩进 + `-123.45.` 打头）

///|
fn p16_src() -> String {
  "01 R.\n  05 A PIC S9(4)V99 VALUE\n      -123.45.\n"
}

///|
test "CB-B8: p16 的报错必须带上「被判定为定长格式 + 第几行列 7 是 '-'」" {
  let msg = flip_msg(p16_src())
  // 仍然报错（本轮只改报错质量，不把非法输入变成合法）
  assert_true(msg != "<无错误>")
  // 必须点明判定原因与命中行号
  assert_true(msg.contains("定长格式"))
  assert_true(msg.contains("列 7"))
  assert_true(msg.contains("第 3 行") || msg.contains("3 行"))
}

///|
test "CB-B8: 正常自由格式 copybook 不带任何判定附注" {
  let msg = flip_msg("01 R.\n  05 A PIC X(5).\n")
  inspect(msg, content="<无错误>")
}

///|
test "CB-B8: 带序号文件的语法错误不带「列 7 '-'」附注（那是真定长）" {
  // 有真实序号区 → 定长判定成立但**依据不是** '-' 行，不该附注
  let msg = flip_msg("000100 01 R.\n000200    05 BAD BAD BAD X(2).\n")
  assert_true(msg != "<无错误>")
  assert_false(msg.contains("第 1 行列 7 为 '-'"))
}

///|
test "CB-B8: 词法错误路径的附注保持（CB-4 不回退）" {
  // CB-4 已覆盖的形态：长行被列 72 切断引号
  let long = "      -    spacer.\n"
  let src = "01 R.\n   05 A PIC X(60) VALUE 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'.\n" +
    long
  let msg = flip_msg(src)
  assert_true(msg != "<无错误>")
  assert_true(msg.contains("定长"))
  assert_true(msg.contains("列 7"))
}
