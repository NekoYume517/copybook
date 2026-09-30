// Copybook 词法测试
//
// 覆盖：自由格式 / 固定列格式 / 第 7 列注释 / 关键字大小写不敏感 /
// PIC 模式串边界 / 标识符连字符 / 级别号 vs 普通数字 / 错误行列号

///|
/// 取第 i 个 token 的 kind 文本
fn kind_of(src : StringView, i : Int32) -> String raise {
  let toks = @src.tokenize(src)
  if i < toks.length() {
    toks[i].kind.describe()
  } else {
    "<越界>"
  }
}

///|
/// 取第 i 个 token 的行列号 "行:列"
fn pos_of(src : StringView, i : Int32) -> String raise {
  let toks = @src.tokenize(src)
  if i < toks.length() {
    "\{toks[i].line}:\{toks[i].column}"
  } else {
    "<越界>"
  }
}

///|
/// 从 token 数组直接拼出 kind 文本
fn kinds_text(toks : Array[@src.Token]) -> String {
  let sb = StringBuilder()
  for i, t in toks {
    if i > 0 {
      sb.write_string("|")
    }
    sb.write_string(t.kind.describe())
  }
  sb.to_string()
}

///|
/// 执行并返回错误描述，无错返回 "<无错误>"
fn err_of(src : StringView) -> String {
  try {
    let _ = @src.tokenize(src)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
}

///|
test "lexer: 自由格式最简单的 01 记录" {
  let src = "01  CUSTOMER-RECORD."
  // 级别号 01、标识符、句点、EOF
  assert_eq(kind_of(src, 0), "级别号 '1'")
  assert_eq(kind_of(src, 1), "标识符 'CUSTOMER-RECORD'")
  assert_eq(kind_of(src, 2), "'.'")
  assert_eq(kind_of(src, 3), "文件结束")
}

///|
test "lexer: 关键字大小写不敏感" {
  // pic / Pic / PIC 都识别成同一个 Keyword("PIC") + 模式串
  assert_eq(kind_of("05 A pic 9(8).", 2), "关键字 'PIC'")
  assert_eq(kind_of("05 A Pic 9(8).", 2), "关键字 'PIC'")
  assert_eq(kind_of("05 A PICTURE 9(8).", 2), "关键字 'PIC'")
  assert_eq(kind_of("05 A pic 9(8).", 3), "PIC 模式串 '9(8)'")
  // 关键字本体也大小写不敏感
  assert_eq(kind_of("05 A PIC 9(8) comp-3.", 4), "关键字 'COMP-3'")
  assert_eq(kind_of("05 A PIC 9(8) COMP-3.", 4), "关键字 'COMP-3'")
}

///|
test "lexer: PIC 模式串整体成 token" {
  // S9(7)V99 —— 符号、位数、隐含小数点都在同一个 token 里
  assert_eq(kind_of("05 B PIC S9(7)V99 COMP-3.", 3), "PIC 模式串 'S9(7)V99'")
  assert_eq(kind_of("05 N PIC X(30).", 3), "PIC 模式串 'X(30)'")
  assert_eq(kind_of("05 D PIC 9(8).", 3), "PIC 模式串 '9(8)'")
  // 编辑型
  assert_eq(kind_of("05 E PIC ZZ,ZZ9.99.", 3), "PIC 模式串 'ZZ,ZZ9.99'")
  assert_eq(kind_of("05 F PIC $9,999.99.", 3), "PIC 模式串 '$9,999.99'")
  assert_eq(kind_of("05 G PIC 9(5)CR.", 3), "PIC 模式串 '9(5)CR'")
}

///|
test "lexer: PIC 模式串末尾句点归 Dot" {
  // `PIC X(30).` 里的 `.` 必须是 Dot，不是模式串的一部分
  let src = "05 N PIC X(30)."
  let toks = @src.tokenize(src)
  assert_eq(toks.length(), 6) // 05 N PIC X(30) . EOF
  assert_eq(toks[3].kind.describe(), "PIC 模式串 'X(30)'")
  assert_eq(toks[4].kind.describe(), "'.'")
}

///|
test "lexer: PIC 模式串带空格的续接（S9(7) V99）" {
  // 少见但合法：隐含小数点被空格隔开
  assert_eq(
    kind_of("05 B PIC S9(7) V99 COMP-3.", 3),
    "PIC 模式串 'S9(7)V99'",
  )
  // VALUE 不能被当成续接吞掉
  let src = "05 X PIC X VALUE 'A'."
  assert_eq(kind_of(src, 3), "PIC X")
  assert_eq(kind_of(src, 4), "关键字 'VALUE'")
  assert_eq(kind_of(src, 5), "字面量 'A'")
}

///|
test "lexer: 裸 X / N 的 PIC 用专用变体" {
  assert_eq(kind_of("05 A PIC X.", 3), "PIC X")
  assert_eq(kind_of("05 A PIC N.", 3), "PIC N")
  assert_eq(kind_of("05 A PIC X(1).", 3), "PIC 模式串 'X(1)'")
}

///|
test "lexer: 标识符允许连字符" {
  assert_eq(kind_of("05 CUST-ID PIC 9(8).", 1), "标识符 'CUST-ID'")
  assert_eq(kind_of("05 A-B-C PIC 9(8).", 1), "标识符 'A-B-C'")
  // 下划线也接受（COBOL 2014）
  assert_eq(kind_of("05 A_B PIC 9(8).", 1), "标识符 'A_B'")
}

///|
test "lexer: 标识符不能以连字符结尾" {
  // `CUST- PIC X.` 是笔误，必须报错而不是切成 CUST 和 -
  let e = err_of("05 CUST- PIC X.")
  assert_true(e.contains("不能以连字符结尾"))
  assert_true(e.contains("1:"))
}

///|
test "lexer: 标识符统一转大写" {
  assert_eq(kind_of("05 cust-id PIC 9(8).", 1), "标识符 'CUST-ID'")
  assert_eq(kind_of("05 Cust-Id PIC 9(8).", 1), "标识符 'CUST-ID'")
}

///|
test "lexer: OCCURS 里的数字是 Number 不是 Level" {
  let src = "05 LINES OCCURS 5 TIMES."
  assert_eq(kind_of(src, 2), "关键字 'OCCURS'")
  assert_eq(kind_of(src, 3), "数字 '5'")
  assert_eq(kind_of(src, 4), "关键字 'TIMES'")
}

///|
test "lexer: 语句起点之后的数字不是 Level" {
  // OCCURS 10 TO 20 TIMES 里的数字
  let src = "05 T OCCURS 10 TO 20 TIMES."
  assert_eq(kind_of(src, 3), "数字 '10'")
  assert_eq(kind_of(src, 4), "关键字 'TO'")
  assert_eq(kind_of(src, 5), "数字 '20'")
}

///|
test "lexer: 合法级别号 01..49 66 77 88" {
  for lvl in [1, 5, 10, 49, 66, 77, 88].iter() {
    let src = if lvl < 10 {
      "0\{lvl} X PIC 9(1)."
    } else {
      "\{lvl} X PIC 9(1)."
    }
    assert_eq(kind_of(src, 0), "级别号 '\{lvl}'")
  }
}

///|
test "lexer: 非法级别号 50..65 被当普通数字" {
  // 50 不在 01..49/66/77/88 里，按 Number 处理（解析器随后会报错）
  assert_eq(kind_of("50 X PIC 9(1).", 0), "数字 '50'")
  assert_eq(kind_of("65 X PIC 9(1).", 0), "数字 '65'")
}

///|
test "lexer: 句点重置语句起点" {
  // 第一个语句的 `05` 是 Level；句点之后 `05` 仍是 Level
  let src = "05 A PIC 9(1).\n05 B PIC 9(1)."
  let toks = @src.tokenize(src)
  assert_eq(toks[0].kind.describe(), "级别号 '5'")
  assert_eq(toks[4].kind.describe(), "'.'")
  assert_eq(toks[5].kind.describe(), "级别号 '5'")
  assert_eq(toks[6].kind.describe(), "标识符 'B'")
}

///|
test "lexer: 第 7 列星号整行注释（定长格式）" {
  // 前 6 列是序号 → 判定为定长格式；这行第 7 列是 `*`，整行注释
  let src = "000100 01  R.\n000200*   注释行\n000300     05  A  PIC 9(8)."
  let toks = @src.tokenize(src)
  // 01 R . 05 A PIC 9(8) . EOF
  assert_eq(toks.length(), 9)
  assert_eq(
    kinds_text(toks),
    "级别号 '1'|标识符 'R'|'.'|级别号 '5'|标识符 'A'|关键字 'PIC'|PIC 模式串 '9(8)'|'.'|文件结束",
  )
}

///|
test "lexer: 自由格式下代码区开头星号也是注释" {
  let src = "* leading comment\n05 A PIC 9(8)."
  let toks = @src.tokenize(src)
  assert_eq(toks[0].kind.describe(), "级别号 '5'")
  assert_eq(toks[1].kind.describe(), "标识符 'A'")
}

///|
test "lexer: 固定列格式（带 6 位序号区）" {
  // 前 6 列是序号，第 7 列空格，代码从第 8 列开始
  let src = "000100 01  REC.\n000200     05  A PIC 9(8)."
  let toks = @src.tokenize(src)
  assert_eq(toks[0].kind.describe(), "级别号 '1'")
  assert_eq(toks[1].kind.describe(), "标识符 'REC'")
  assert_eq(toks[2].kind.describe(), "'.'")
  assert_eq(toks[3].kind.describe(), "级别号 '5'")
  assert_eq(toks[4].kind.describe(), "标识符 'A'")
}

///|
test "lexer: 固定列格式截断第 72 列之后" {
  // 第 73 列起是标识区，必须忽略。这里塞一段会被误识别的文本。
  // 构造：代码区从第 8 列开始，"000100 01  REC." 占 15 列，
  // 补齐到第 72 列，然后接非法字符（若未截断会报"无法识别的字符"）。
  let line1 = "000100 01  REC." + String::make(57, ' ') + "999 不该出现"
  // 只截前 72 列：68 之前的内容有效
  let toks = @src.tokenize(line1)
  // 01 REC . EOF（999 在第 73 列之后被截掉）
  assert_eq(kinds_text(toks), "级别号 '1'|标识符 'REC'|'.'|文件结束")
}

///|
test "lexer: REDEFINES / VALUE / USAGE IS COMP-3" {
  let src = "05 ALT REDEFINES LIMIT-AMT VALUE 0 USAGE IS COMP-3."
  let toks = @src.tokenize(src)
  assert_eq(
    kinds_text(toks),
    "级别号 '5'|标识符 'ALT'|关键字 'REDEFINES'|标识符 'LIMIT-AMT'|关键字 'VALUE'|数字 '0'|关键字 'USAGE'|关键字 'IS'|关键字 'COMP-3'|'.'|文件结束",
  )
}

///|
test "lexer: SIGN IS LEADING SEPARATE" {
  let src = "05 A PIC S9(5) SIGN IS LEADING SEPARATE."
  assert_eq(kind_of(src, 4), "关键字 'SIGN'")
  assert_eq(kind_of(src, 5), "关键字 'IS'")
  assert_eq(kind_of(src, 6), "关键字 'LEADING'")
  assert_eq(kind_of(src, 7), "关键字 'SEPARATE'")
}

///|
test "lexer: FILLER 是关键字不是字段名" {
  assert_eq(kind_of("05 FILLER PIC X(10).", 1), "关键字 'FILLER'")
}

///|
test "lexer: 字符串字面量与双写引号转义" {
  assert_eq(kind_of("05 A PIC X VALUE 'A'.", 5), "字面量 'A'")
  // 'O''Brien' 里的双引号是转义的一个引号
  let toks = @src.tokenize("05 A PIC X VALUE 'O''Brien'.")
  assert_eq(toks[5].kind.describe(), "字面量 'O''Brien'")
  assert_eq(toks[6].kind.describe(), "'.'")
}

///|
test "lexer: 字符串字面量缺结束引号报错" {
  let e = err_of("05 A PIC X VALUE 'A.")
  assert_true(e.contains("缺少结束引号"))
}

///|
test "lexer: 行列号准确（自由格式）" {
  // `05` 在第 1 列，`A` 在第 5 列
  assert_eq(pos_of("05  A PIC 9(8).", 0), "1:1")
  assert_eq(pos_of("05  A PIC 9(8).", 1), "1:5")
  // 第 2 行的字段：4 空格 + 05 → 05 在第 5 列
  let src = "01  R.\n    05 A PIC 9(1)."
  assert_eq(pos_of(src, 3), "2:5")
}

///|
test "lexer: 空输入只有 Eof" {
  let toks = @src.tokenize("")
  assert_eq(toks.length(), 1)
  assert_eq(toks[0].kind.describe(), "文件结束")
}

///|
test "lexer: 纯注释文件只有 Eof" {
  let toks = @src.tokenize("* a\n* b\n")
  assert_eq(toks.length(), 1)
  assert_eq(toks[0].kind.describe(), "文件结束")
}

///|
test "lexer: CRLF 换行不产生多余字符" {
  let src = "01  R.\r\n    05 A PIC 9(1).\r\n"
  let toks = @src.tokenize(src)
  assert_eq(toks.length(), 9)
  assert_eq(toks[3].line, 2)
  assert_eq(toks[3].kind.describe(), "级别号 '5'")
}

///|
test "lexer: 不可识别字符报错并带位置" {
  // `@` 在 PIC 子句之后、模式串之外，属于语句级非法字符
  let e = err_of("05 A PIC 9(8) @.")
  assert_true(e.contains("无法识别的字符"))
  assert_true(e.contains("1:15"))
}

///|
test "lexer: PIC 缺模式串报错" {
  let e = err_of("05 A PIC.")
  assert_true(e.contains("PIC 子句缺少模式串"))
}

///|
test "lexer: PIC 模式串含非法字符报错" {
  let e = err_of("05 A PIC 9#(8).")
  assert_true(e.contains("PIC 模式串中出现非法字符"))
}

///|
test "lexer: 三个 examples 都能完整词法化" {
  // customer.cpy
  let customer = "01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n    05  CUST-NAME      PIC X(30).\n    05  BALANCE        PIC S9(7)V99 COMP-3.\n    05  OPEN-DATE      PIC 9(8).\n    05  FLAGS.\n        10  ACTIVE     PIC X(1).\n        10  TIER       PIC 9(2).\n"
  let t1 = @src.tokenize(customer)
  assert_eq(t1[t1.length() - 1].kind.describe(), "文件结束")
  // 8 个数据项，每项至少 4 个 token
  assert_true(t1.length() > 30)

  // order.cpy
  let order = "01  ORDER-LINES.\n    05  ORDER-ID       PIC 9(10).\n    05  LINE-COUNT     PIC 9(3).\n    05  LINES OCCURS 5 TIMES.\n        10  SKU        PIC X(12).\n        10  QTY        PIC S9(4) COMP.\n        10  PRICE      PIC S9(5)V99 COMP-3.\n"
  let t2 = @src.tokenize(order)
  assert_eq(t2[t2.length() - 1].kind.describe(), "文件结束")
  // OCCURS 5 TIMES 必须是 Number 而非 Level
  let mut has_occurs5 = false
  for t in t2 {
    if t.kind.describe() == "数字 '5'" {
      has_occurs5 = true
    }
  }
  assert_true(has_occurs5)

  // redefines.cpy
  let redef = "01  ACCOUNT-MASTER.\n    05  ACCT-NO        PIC 9(12).\n    05  ACCT-TYPE      PIC X(2).\n    05  LIMIT-AMT      PIC S9(9)V99 COMP-3.\n    05  ALT-VIEW REDEFINES LIMIT-AMT.\n        10  RAW-BYTE   PIC X(6).\n    05  SSN            PIC 9(9).\n"
  let t3 = @src.tokenize(redef)
  assert_eq(t3[t3.length() - 1].kind.describe(), "文件结束")
}

///|
test "lexer: 88 条件名与 66 RENAMES 能词法化" {
  let src = "05 A PIC 9(1).\n    88 IS-OK VALUE 1.\n    66 ALT RENAMES A."
  let toks = @src.tokenize(src)
  assert_eq(toks[5].kind.describe(), "级别号 '88'")
  assert_eq(toks[6].kind.describe(), "标识符 'IS-OK'")
  assert_eq(toks[10].kind.describe(), "级别号 '66'")
  assert_eq(toks[12].kind.describe(), "关键字 'RENAMES'")
}
