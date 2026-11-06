// P2-3 → RJ-2b：本文件的两条「词间断行补空格」测试是 2026-10-30 轮加的，
// 它锁定的是**补空格**行为。2026-11-06 组委会验收指出该行为违反 IBM 标准：
//
//   列 7 的 `-` 续行在 IBM 里的定义就是「把本行区 B 内容**无空格地**接到
//   上一条逻辑行尾」——这是分裂词续行（`CUSTOM` + `ER` → `CUSTOMER`）
//   的唯一实现手段。补空格把 `05 CUST` + `-    OUNTER PIC 9(3).` 拆成
//   `CUSTOM ER` 两个词，报「意料之外的 标识符 'OUNTER'」——组委会
//   的「固定格式续行识别错误」正是栽在这里。
//
//   P2-3 想防的「`PIC` + `X(10)` 粘成 `PICX`」在 IBM 语义下本来就该粘：
//   那确实是断行错误，粘出来的报错才指向真正的断行位置；补空格把错误
//   输入洗成了另一个错误。
//
// 2026-11-07 起拼接恢复 IBM 语义（直接相接），本文件相应改为锁定：
//   1. 分裂词续行拼成一个标识符（组委会的形态，修复前报错）；
//   2. 断在子句中间的 PIC 模式仍能拼回（`X(10)` 断成 `X(` + `10).`）；
//   3. 字面量内拼接保持零相接（continuation_test 的既有契约不回退）。

///|
test "RJ-2b: 分裂词续行拼成一个标识符（CUSTOM + ER → CUSTOMER）" {
  // 修复前：`CUSTOM ER` 被当成两个词，报「意料之外的 标识符 'OUNTER'」
  let src = "000100 01  R.\n000200     05  CUSTOM\n000300-           ER PIC 9(3).\n"
  let layout = @src.compile_layout(@src.parse_copybook(src))
  inspect(layout.byte_length, content="3")
  // 字段名必须是拼起来的 CUSTOMER，不是两个词
  let f = layout.find("R.CUSTOMER")
  assert_true(f is Some(_))
}

///|
test "RJ-2b: PIC 模式断在 ( 后仍能拼回（直接相接）" {
  // `PIC X(` + `10).` → `X(10).`（continuation_test 既有契约，锁定不回退）
  let src = "000100 01 R.\n000200    05 B PIC X(\n000300-        10).\n"
  assert_eq(cont_field_len_p23(src), 10)
}

///|
test "RJ-2b: 关键字与参数断行直接相接（OCCURS + 3 → OCCURS3 是用户断行错误）" {
  // P2-3 时代 `OCCURS` + `3` 被补空格救成 `OCCURS 3`；IBM 语义下它粘成
  // `OCCURS3` 报错 —— 那才是对断行错误的忠实报告。锁定报错形态。
  let src = "000100 01 R.\n000200 05 A PIC X(2) OCCURS\n000300- 3 TIMES.\n"
  let r = try {
    let _ = @src.compile_layout(@src.parse_copybook(src))
    "no error"
  } catch {
    _ => "error"
  }
  inspect(r, content="error")
}

///|
test "RJ-2b: 字面量内拼接保持零相接（不回退）" {
  // 'ABC + DEF' 必须仍是 'ABCDEF'（不带空格）——continuation_test 的
  // 契约在拼接语义改回 IBM 后不得回退。
  let src = "000100 01 R.\n000200 05 A PIC X(10) VALUE 'ABC\n000300-        DEF'.\n"
  assert_eq(cont_value_literal_p23(src), "'ABCDEF'")
}

///|
/// 编译 copybook 并返回唯一叶子字段的字节长度
fn cont_field_len_p23(src : StringView) -> Int32 raise {
  let layout = @src.compile_layout(@src.parse_copybook(src))
  layout.byte_length
}

///|
/// 取第一个字段的 VALUE 字面量原文（含引号）
fn cont_value_literal_p23(src : StringView) -> String raise {
  let specs = @src.parse_copybook(src)
  match specs[0].children[0].value_literal {
    Some(v) => v
    None => fail("字段没有 VALUE 字面量")
  }
}
