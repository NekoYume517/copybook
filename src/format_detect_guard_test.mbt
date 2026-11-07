// CB-4（2026-11-08 审计）：detect_fixed_format 的「列 7 '-' 追加判定」
// 会把自由格式文件劫持成定长格式。
//
// ## 缺陷形态（修复前）
//
// 自由格式文件里只要有一行的第 7 列恰好是 `-`（例如顶格 6 空格 +
// 连字符开头的普通内容），整份文件就被判定为定长格式：
//
//   - 长行（>72 列）在列 72 被硬切，VALUE 字面量断在中间 →
//     "字符串字面量缺少结束引号"（报错位置指向错误根因）；
//   - 自由格式内容从列 8 起被错位解析 → "期望数据描述项"。
//
// 而列 7 的 `-` 在自由格式里本有**更准确的**自有报错
// （「续行符 '-' 只在固定格式的列 7 有效」），被格式翻转吞掉了。
//
// ## 修复
//
// 列 7 `-` 单独不足以翻转格式：它必须与**另一个独立的定长信号**
// （存在序号行）同时出现才翻转。真正的无序号定长 copybook（IBM 手写
// 带续行）通常还有 `*` 注释列或整片列 7 指示符区；单独一个 `-` 行
// 更可能是自由格式里的巧合。真正的无序号+续行文件（无序号定长、
// 无其他信号）仍由 continuation_test 的无序号用例锁定 —— 那类文件
// 本身除续行行外与自由格式不可区分，旧判定对它返回 false 的行为
// 保持不变（自由格式下报「续行符只在固定格式列 7 有效」的准确错误）。
//
// 等等 —— 上面最后一句与 RJ-2 的动机冲突。重新裁决（见实现注释）：
// 追加判定保留，但**只在文件没有任何序号行时**仍翻转（RJ-2 场景），
// 且翻转只影响续行/列界解析；本修复针对的是「自由格式文件 + 巧合
// `-` 行」的次生报错质量：拼接错误发生时，报错文案必须提示
// 「文件被判定为定长格式（第 N 行列 7 为 '-'），长行可能被列 72 截断」，
// 让根因可发现。若需要绝对安全，用户可用无序号定长或加序号。
// 这里取「保留翻转 + 报错提示判定原因」的折中（与代理建议一致）。

///|
test "CB-4: 自由格式长行 + 巧合 - 行的报错必须提示格式判定原因" {
  // 无序号、长 VALUE 行（>72 列）、一行列 7 恰为 '-'
  let long = "      -    spacer.\n"
  let src = "01 R.\n   05 A PIC X(60) VALUE 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'.\n" +
    long
  let msg = try {
    let _ = tokenize(src)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
  // 修复前：报 "字符串字面量缺少结束引号"，不提格式判定；
  // 修复后：报错必须提到「定长格式」判定与 '-' 行，根因可发现
  assert_true(msg.contains("定长"))
  assert_true(msg.contains("列 7"))
}

///|
test "CB-4: 真无序号定长续行不受影响（RJ-2 不回退）" {
  let src = "      01  REC.\n          05 A PIC X(\n      -        5).\n"
  let layout = compile_layout(parse_copybook(src))
  assert_eq(layout.byte_length, 5)
}

///|
test "CB-4: 带序号文件的续行不受影响（主判定不回退）" {
  let src = "000100 01 R.\n000200    05 A PIC X(\n000300-        5).\n"
  let layout = compile_layout(parse_copybook(src))
  assert_eq(layout.byte_length, 5)
}

///|
test "CB-4: 自由格式 '-' 行的自有报错保持准确" {
  let msg = try {
    let _ = tokenize("-   05 A PIC X(2).")
    "<无错误>"
  } catch {
    e => e.to_display()
  }
  assert_true(msg.contains("续行符"))
}
