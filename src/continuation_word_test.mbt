// P2-3 回归：续行断在**词中间**时，拼接必须补一个空格，不能把两个词
// 粘成一个新词。
//
// 复现（修复前）：`000200 05 A PIC` + `000300- X(10).` → 拼成 `PICX`
// 报「数据项 'A' 的子句里出现意料之外的 标识符 'PICX'」，错误无指向
// （真正的断行位置信息完全丢失）。字面量内拼接（'ABC + DEF'）保持
// 零相接——continuation_test.mbt 锁定的既有契约不受影响。

///|
test "续行：词间断行补空格，不粘词（P2-3）" {
  let src = "000100 01 R.\n000200 05 A PIC\n000300- X(10).\n"
  assert_eq(cont_field_len_p23(src), 10)
}

///|
test "续行：词间断行多段与 VALUE 断行（P2-3）" {
  // OCCURS 断在关键字与数字之间：`OCCURS` + `3` 若粘成 `OCCURS3` 会被
  // 当成一个标识符，布局直接报错
  let src = "000100 01 R.\n000200 05 A PIC X(2) OCCURS\n000300- 3 TIMES.\n"
  let layout = @src.compile_layout(@src.parse_copybook(src))
  inspect(layout.byte_length, content="6")
  inspect(layout.fields.length(), content="3")
}

///|
test "续行：字面量内拼接保持零相接（P2-3 回归锁定）" {
  // 'ABC + DEF' 必须仍是 'ABCDEF'（不带空格）——continuation_test 的
  // 契约在补空格修复后不得回退。
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
