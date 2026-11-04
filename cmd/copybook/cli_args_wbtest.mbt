// CLI 数值参数解析的回归（2026-11-04 对抗性审计 NEW-3）。
//
// ## 缺陷形态（修复前）
//
// `parse_positive_int` 逐位 `v = v * 10 + digit`，没有溢出检查。于是：
//
//     --record-length 4294967300   -> 回绕成 4（恰好等于布局长度）
//     --record-length 9999999999   -> 回绕成 1410065407
//
// 第一条尤其危险：`decode` **静默成功 exit 0**、零提示，用户要求的记录长度
// 与实际使用的完全不同。更坏的情形是回绕成大于布局的值，把大文件按错误
// 边界切分。
//
// 项目里已有同类先例：`src/lexer.mbt` 的 `parse_digits` 用「超过 9 位直接
// 拒绝」防 OCCURS 回绕，并在注释里写明踩过这个坑。CLI 侧漏了同一防护。
//
// 修复：位数 > 9 一律拒绝（记录长度不可能到这个量级，Int32 的 10 位上限
// 2147483647 也远超任何真实记录），判定放在乘之前。

///|
test "NEW-3: --record-length 不接受会回绕 Int32 的超长数字" {
  // 回绕成 4 的那一条（4 = 4294967300 mod 2^32）
  assert_eq(parse_positive_int("4294967300"), None)
  // 回绕成 1410065407 的那一条
  assert_eq(parse_positive_int("9999999999"), None)
  // 纯位数上限：9 位以内仍接受
  assert_eq(parse_positive_int("123456789"), Some(123456789))
  assert_eq(parse_positive_int("4"), Some(4))
  // 10 位一律拒绝（Int32 上限 2147483647 是 10 位，但记录长度到不了）
  assert_eq(parse_positive_int("2147483647"), None)
  // 原有拒绝面保持不变：空串 / 0 / 负数 / 杂字符
  assert_eq(parse_positive_int(""), None)
  assert_eq(parse_positive_int("0"), None)
  assert_eq(parse_positive_int("-2"), None)
  assert_eq(parse_positive_int("12a"), None)
}
