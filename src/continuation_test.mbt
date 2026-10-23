// 列 7 `-` 续行（COBOL 固定格式的 continuation line）。
//
// 背景（CB-4）：`src/lexer.mbt` 头部注释从第一版起就写着「`-`=续行」，
// 但实现里第 7 列的 `-` 只是被当作指示符跳过，接续内容被当成**新语句**，
// 于是长 PIC / VALUE 跨行直接报错（自由格式下则报「无法识别的字符 '-'」）。
//
// 真实主机 copybook 里 `PIC` 与 `VALUE` 跨行很常见，所以这里实现续行：
// 把续行行的代码区（列 8-72）接到上一条逻辑行后面再统一做词法。
// 拼接规则见 lexer.mbt 的 `collect_code_lines`：续接段去掉两端空白后直接
// 相接，因此 `'ABC` + `DEF'` 得到 `'ABCDEF'`、`X(` + `5)` 得到 `X(5)`。

///|
/// 编译 copybook 并返回唯一叶子字段的字节长度。
fn cont_field_len(src : StringView) -> Int32 raise {
  let layout = @src.compile_layout(@src.parse_copybook(src))
  layout.byte_length
}

///|
/// 取第一个字段的 VALUE 字面量原文（含引号）。
fn cont_value_literal(src : StringView) -> String raise {
  let specs = @src.parse_copybook(src)
  match specs[0].children[0].value_literal {
    Some(v) => v
    None => fail("字段没有 VALUE 字面量")
  }
}

///|
/// 断言 tokenize 抛出的错误文本包含指定片段。
fn cont_err(src : StringView, needle : String) -> Unit raise {
  let msg = try {
    let _ = @src.tokenize(src)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
  assert_true(msg.contains(needle))
}

///|
test "续行：列 7 的 - 把 VALUE 字面量跨行拼接（CB-4）" {
  // 第 1 行的字面量没有收尾引号，第 2 行把它接上
  let src = "000100 01 R.\n000200    05 A PIC X(10) VALUE 'ABC\n000300-        DEF'.\n"
  assert_eq(cont_value_literal(src), "'ABCDEF'")
  assert_eq(cont_field_len(src), 10)
}

///|
test "续行：列 7 的 - 把 PIC 模式串跨行拼接（CB-4）" {
  // `PIC X(` 与 `5).` 拼成 `PIC X(5).`
  let src = "000100 01 R.\n000200    05 B PIC X(\n000300-        5).\n"
  assert_eq(cont_field_len(src), 5)
}

///|
test "续行：连续多行续行（CB-4）" {
  // 一条逻辑行跨三条物理行：PIC X(1 / 2 / ). → X(12)
  let pic_src = "000100 01 R.\n000200    05 C PIC X(1\n000300-        2\n000400-        ).\n"
  assert_eq(cont_field_len(pic_src), 12)
  // VALUE 跨三条物理行：'AB / CD / EF' → 'ABCDEF'
  let value_src = "000100 01 R.\n000200    05 E PIC X(6) VALUE 'AB\n000300-        CD\n000400-        EF'.\n"
  assert_eq(cont_value_literal(value_src), "'ABCDEF'")
  assert_eq(cont_field_len(value_src), 6)
}

///|
test "续行：续行后面还能继续写正常语句（CB-4）" {
  let src = "000100 01 R.\n000200    05 B PIC X(\n000300-        5).\n000400    05 C PIC 9(3).\n"
  let layout = @src.compile_layout(@src.parse_copybook(src))
  assert_eq(layout.byte_length, 8)
  assert_eq(layout.fields.length(), 2)
  assert_eq(layout.fields[0].byte_length, 5)
  assert_eq(layout.fields[1].byte_length, 3)
}

///|
test "续行：自由格式下 '-' 不是续行符，必须明确报错（CB-4）" {
  cont_err("-   05 A PIC X(2).", "续行符")
  // 正常字段名里的连字符不受影响
  let ok = "01 R.\n  05 CUST-ID PIC 9(3).\n"
  assert_eq(@src.compile_layout(@src.parse_copybook(ok)).byte_length, 3)
}

///|
test "续行：列 7 的 - 前面没有可续接的逻辑行时报错（CB-4）" {
  cont_err("000100-    05 A PIC X(2).\n", "续行")
}
