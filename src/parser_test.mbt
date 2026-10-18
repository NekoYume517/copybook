// PIC 子句与 copybook 语法树测试
//
// 覆盖：PIC 各类别与 digits/scale/signed、USAGE 各变体、
// OCCURS/REDEFINES/VALUE、层级建树、88/66 剔除、错误行列号

///|
/// 便捷构造并解析一个 PIC 串
fn pic(text : String) -> @src.PicClause raise {
  @src.parse_pic_clause(text, 1, 1)
}

///|
/// "类别/digits/scale/signed" 四元组的文本形式，便于断言
fn pic_shape(c : @src.PicClause) -> String {
  let signed = if c.signed { "S" } else { "-" }
  "\{c.category.name()}/\{c.digits}/\{c.scale}/\{signed}"
}

///|
/// PIC + USAGE 的文本形式
fn pic_usage(c : @src.PicClause) -> String {
  "\{pic_shape(c)}/\{c.usage.name()}"
}

///|
/// 解析单个 PIC 串并返回四元组文本
fn shape(text : String) -> String raise {
  pic_shape(pic(text))
}

///|
/// 解析单个 PIC 串并返回带 USAGE 的文本
fn shape_u(text : String) -> String raise {
  pic_usage(pic(text))
}

///|
test "pic: pic_usage 文本形式" {
  assert_eq(shape_u("S9(7)V99"), "NUMERIC/7/2/S/DISPLAY")
}

///|
/// 错误文本（无错返回 "<无错误>"）
fn pic_err(text : String) -> String {
  try {
    let _ = @src.parse_pic_clause(text, 3, 7)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
}

// ============================================================================
// PIC 子句
// ============================================================================

///|
test "pic: 数字型 9(8)" {
  assert_eq(shape("9(8)"), "NUMERIC/8/0/-")
}

///|
test "pic: 数字型不带括号 999" {
  assert_eq(shape("999"), "NUMERIC/3/0/-")
}

///|
test "pic: 带符号 S9(7)V99 —— digits 是整数位，scale 是小数位" {
  // 这是硬性契约：digits=7（不是 9），scale=2，总位=9
  assert_eq(shape("S9(7)V99"), "NUMERIC/7/2/S")
}

///|
test "pic: 纯小数 V99" {
  assert_eq(shape("V99"), "NUMERIC/0/2/-")
}

///|
test "pic: 整数带隐含小数点 S9(5)V9(3)" {
  assert_eq(shape("S9(5)V9(3)"), "NUMERIC/5/3/S")
}

///|
test "pic: 字符型 X(30) —— digits 是字符数" {
  assert_eq(shape("X(30)"), "ALPHANUMERIC/30/0/-")
  assert_eq(shape("X"), "ALPHANUMERIC/1/0/-")
  assert_eq(shape("XXX"), "ALPHANUMERIC/3/0/-")
}

///|
test "pic: 字母型 A(5)" {
  assert_eq(shape("A(5)"), "ALPHABETIC/5/0/-")
}

///|
test "pic: 国家字符 N(5) —— digits 是字符数，字节数由布局层 ×2" {
  assert_eq(shape("N(5)"), "NATIONAL/5/0/-")
}

///|
test "pic: 编辑型 ZZ,ZZ9.99" {
  // 有效数字位：ZZ ZZ 9 = 5 整数位 + 2 小数位
  assert_eq(shape("ZZ,ZZ9.99"), "EDITED/5/2/-")
  assert_eq(pic("ZZ,ZZ9.99").pic_text, "ZZ,ZZ9.99")
}

///|
test "pic: 编辑型 $9,999.99" {
  // 有效数字位 6（$ 和 , . 不占位）
  assert_eq(shape("$9,999.99"), "EDITED/4/2/-")
}

///|
test "pic: 编辑型 9(5)CR" {
  assert_eq(shape("9(5)CR"), "EDITED/5/0/-")
}

///|
test "pic: 编辑型带 +/- 符号位" {
  // 前导 + 是插入字符，不算数字位
  assert_eq(shape("+9(4)"), "EDITED/4/0/-")
  assert_eq(shape("9(4)-"), "EDITED/4/0/-")
}

///|
test "pic: 编辑型 **9(3)" {
  assert_eq(shape("**9(3)"), "EDITED/5/0/-")
}

///|
test "pic: 括号展开" {
  assert_eq(shape("9(3)V9(2)"), "NUMERIC/3/2/-")
  assert_eq(shape("X(1)"), "ALPHANUMERIC/1/0/-")
  assert_eq(shape("S9(18)"), "NUMERIC/18/0/S")
}

///|
test "pic: pic_text 保留原始大写串" {
  assert_eq(pic("S9(7)V99").pic_text, "S9(7)V99")
}

///|
test "pic: S 不在首位报错" {
  let e = pic_err("9S(3)")
  assert_true(e.contains("S 只能出现在首位"))
}

///|
test "pic: 编辑型 digits/scale 与 pic_storage_len 的分工" {
  // digits/scale 只数数字位；存储长度要另外算（含插入字符）
  let p = pic("ZZ,ZZ9.99")
  assert_eq(p.digits, 5) // ZZ ZZ 9
  assert_eq(p.scale, 2) // 99
  assert_eq(@src.pic_storage_len("ZZ,ZZ9.99"), 9) // Z Z , Z Z 9 . 9 9
  // 数字型：V 是隐含小数点，占一位但不是数字位
  assert_eq(pic("S9(7)V99").digits + pic("S9(7)V99").scale, 9)
  assert_eq(@src.pic_storage_len("S9(7)V99"), 11) // S + 7 个 9 + V + 2 个 9
  // 注意：Display 下 COBOL 的隐含 V 并不占存储，S 也不占；
  // 精确字节数由 layout 层按 PIC/USAGE 规则算，这里只给出"模式串展开字符数"。
}

///|
test "pic: 编辑型 CR/DB 后缀不占数字位但占存储" {
  let p = pic("9(5)CR")
  assert_eq(p.digits, 5)
  assert_eq(p.scale, 0)
  assert_eq(@src.pic_storage_len("9(5)CR"), 7)
  let q = pic("9(5)DB")
  assert_eq(q.digits, 5)
  assert_eq(@src.pic_storage_len("9(5)DB"), 7)
}

///|
test "pic: 括号不匹配报错" {
  assert_true(pic_err("9(8").contains("没有匹配的 ')'"))
  assert_true(pic_err("9)8").contains("多余的 ')'"))
}

///|
test "pic: 括号里非数字报错" {
  assert_true(pic_err("9(a)").contains("括号里出现非数字"))
}

///|
test "pic: 括号里次数为 0 报错" {
  assert_true(pic_err("9(0)").contains("重复次数必须 >= 1"))
}

///|
test "pic: 混用 X 与 9 报错" {
  assert_true(pic_err("X9").contains("混用"))
}

///|
test "pic: 纯 S 无数字位报错" {
  assert_true(pic_err("S").contains("没有任何数字位"))
}

///|
test "pic: pic_storage_len 给出展开后的存储字符数" {
  assert_eq(@src.pic_storage_len("X(30)"), 30)
  assert_eq(@src.pic_storage_len("9(5)CR"), 7)
  assert_eq(@src.pic_storage_len("ZZ,ZZ9.99"), 9)
}

// ============================================================================
// USAGE
// ============================================================================

///|
test "usage: COMP 族映射" {
  let src = "05 A PIC S9(4) COMP.\n05 B PIC S9(9) COMP-4.\n05 C PIC S9(9) BINARY.\n05 D PIC S9(9) COMPUTATIONAL."
  let roots = @src.parse_copybook(src)
  // 都是顶层同级，4 个
  assert_eq(roots.length(), 4)
  for r in roots {
    match r.pic {
      Some(p) => assert_eq(p.usage.name(), "COMP")
      None => fail("应为基本项")
    }
  }
}

///|
test "usage: COMP-3 / PACKED-DECIMAL" {
  let src = "05 A PIC S9(9)V99 COMP-3.\n05 B PIC S9(5) PACKED-DECIMAL."
  let roots = @src.parse_copybook(src)
  for r in roots {
    match r.pic {
      Some(p) => assert_eq(p.usage.name(), "COMP-3")
      None => fail("应为基本项")
    }
  }
}

///|
test "usage: COMP-1 / COMP-2 浮点" {
  let src = "05 A PIC S9(4) COMP-1.\n05 B PIC S9(9) COMP-2."
  let roots = @src.parse_copybook(src)
  assert_eq(usage_of(roots[0]), "COMP-1")
  assert_eq(usage_of(roots[1]), "COMP-2")
}

///|
fn usage_of(s : @src.FieldSpec) -> String {
  match s.pic {
    Some(p) => p.usage.name()
    None => "NONE"
  }
}

///|
test "usage: USAGE IS COMP-3 写法" {
  let src = "05 A PIC S9(9)V99 USAGE IS COMP-3."
  let roots = @src.parse_copybook(src)
  assert_eq(usage_of(roots[0]), "COMP-3")
}

///|
test "usage: 未写 USAGE 时默认 DISPLAY" {
  let src = "05 A PIC X(10)."
  let roots = @src.parse_copybook(src)
  assert_eq(usage_of(roots[0]), "DISPLAY")
}

///|
test "usage: 组项上的 USAGE 记入 group_usage" {
  let src = "05 G COMP-3.\n    10 A PIC S9(4)."
  let roots = @src.parse_copybook(src)
  match roots[0].group_usage {
    Some(u) => assert_eq(u.name(), "COMP-3")
    None => fail("组项应有 group_usage")
  }
  // 组级 USAGE 在建树时即落到无自身 USAGE 的基本项（C5 修复）：
  // `10 A PIC S9(4).` 没写 USAGE，继承组的 COMP-3。
  // 继承发生在 parser 构造 FieldSpec 时 —— FieldSpec 不可变，构造期
  // 注入是唯一可行时机，布局层拿到的是已继承的最终形态。
  assert_eq(usage_of(roots[0].children[0]), "COMP-3")
}

///|
test "usage: 不认识的 USAGE 值报错" {
  let e = parse_err("05 A PIC 9(4) USAGE IS BOGUS.")
  assert_true(
    e.contains("USAGE 的取值不认识") ||
    e.contains("意料之外") ||
    e.contains("USAGE 后面"),
  )
}

// ============================================================================
// 层级建树
// ============================================================================

///|
fn parse_err(src : StringView) -> String {
  try {
    let _ = @src.parse_copybook(src)
    "<无错误>"
  } catch {
    e => e.to_display()
  }
}

///|
/// 树的形状文本：每行 "级别 名字"，子项缩进两格
fn tree_text(specs : Array[@src.FieldSpec]) -> String {
  let sb = StringBuilder()
  render_into(specs, 0, sb)
  sb.to_string()
}

///|
fn render_into(
  specs : Array[@src.FieldSpec],
  depth : Int32,
  sb : StringBuilder,
) -> Unit {
  for s in specs {
    for _i = 0; _i < depth; _i = _i + 1 {
      sb.write_string("  ")
    }
    sb.write_string("\{s.level} \{s.name}")
    sb.write_string("\n")
    render_into(s.children, depth + 1, sb)
  }
}

///|
test "tree: customer.cpy 的层级结构" {
  let src = "01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n    05  CUST-NAME      PIC X(30).\n    05  BALANCE        PIC S9(7)V99 COMP-3.\n    05  OPEN-DATE      PIC 9(8).\n    05  FLAGS.\n        10  ACTIVE     PIC X(1).\n        10  TIER       PIC 9(2).\n"
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 1)
  assert_eq(
    tree_text(roots),
    "1 CUSTOMER-RECORD\n  5 CUST-ID\n  5 CUST-NAME\n  5 BALANCE\n  5 OPEN-DATE\n  5 FLAGS\n    10 ACTIVE\n    10 TIER\n",
  )
}

///|
test "tree: order.cpy 的 OCCURS 组" {
  let src = "01  ORDER-LINES.\n    05  ORDER-ID       PIC 9(10).\n    05  LINE-COUNT     PIC 9(3).\n    05  LINES OCCURS 5 TIMES.\n        10  SKU        PIC X(12).\n        10  QTY        PIC S9(4) COMP.\n        10  PRICE      PIC S9(5)V99 COMP-3."
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 1)
  let lines = roots[0].children[2]
  assert_eq(lines.name, "LINES")
  assert_eq(lines.occurs, 5)
  assert_eq(lines.children.length(), 3)
  assert_eq(lines.children[0].name, "SKU")
  // 子项的 occurs 保持 1
  assert_eq(lines.children[0].occurs, 1)
}

///|
test "tree: redefines.cpy 的 REDEFINES 组" {
  let src = "01  ACCOUNT-MASTER.\n    05  ACCT-NO        PIC 9(12).\n    05  ACCT-TYPE      PIC X(2).\n    05  LIMIT-AMT      PIC S9(9)V99 COMP-3.\n    05  ALT-VIEW REDEFINES LIMIT-AMT.\n        10  RAW-BYTE   PIC X(6).\n    05  SSN            PIC 9(9)."
  let roots = @src.parse_copybook(src)
  let acct = roots[0]
  assert_eq(acct.children.length(), 5)
  let alt = acct.children[3]
  assert_eq(alt.name, "ALT-VIEW")
  assert_eq(alt.redefines, Some("LIMIT-AMT"))
  assert_eq(alt.children.length(), 1)
  assert_eq(alt.children[0].name, "RAW-BYTE")
  // 组项本身没有 PIC
  assert_true(alt.pic is None)
}

///|
test "tree: 同级连续不误嵌套" {
  let src = "01 R.\n  05 A PIC 9(1).\n  05 B PIC 9(1).\n  05 C PIC 9(1)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children.length(), 3)
}

///|
test "tree: 深层嵌套 05 > 10 > 15" {
  let src = "01 R.\n  05 A.\n    10 B.\n      15 C PIC 9(1)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children.length(), 1)
  assert_eq(roots[0].children[0].children.length(), 1)
  assert_eq(roots[0].children[0].children[0].children.length(), 1)
  assert_eq(roots[0].children[0].children[0].children[0].name, "C")
}

///|
test "tree: 多个 01 记录是兄弟不是嵌套" {
  let src = "01 A.\n  05 X PIC 9(1).\n01 B.\n  05 Y PIC 9(1)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 2)
  assert_eq(roots[0].name, "A")
  assert_eq(roots[1].name, "B")
}

///|
test "tree: 基本项带子项报错" {
  let src = "01 R.\n  05 A PIC 9(1).\n    10 B PIC 9(1)."
  let e = parse_err(src)
  assert_true(e.contains("不能有下级项"))
}

///|
test "tree: 77 独立项" {
  let src = "77 WS-FLAG PIC X(1)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 1)
  assert_eq(roots[0].level, 77)
  assert_eq(roots[0].name, "WS-FLAG")
}

///|
test "tree: 缺名字时填 FILLER" {
  let src = "01 R.\n  05 PIC X(10)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].name, "FILLER")
}

// ============================================================================
// 子句
// ============================================================================

///|
test "clause: OCCURS 5 TIMES" {
  let src = "01 R.\n  05 T OCCURS 5 TIMES PIC X(2)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].occurs, 5)
  assert_eq(roots[0].children[0].occurs_min, 5)
}

///|
test "clause: OCCURS 1 TO 5 TIMES 取上界并记录下界" {
  let src = "01 R.\n  05 T OCCURS 1 TO 5 TIMES PIC X(2)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].occurs, 5)
  assert_eq(roots[0].children[0].occurs_min, 1)
}

///|
test "clause: OCCURS DEPENDING ON" {
  let src = "01 R.\n  05 N PIC 9(2).\n  05 T OCCURS 1 TO 5 TIMES DEPENDING ON N PIC X(2)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[1].occurs_depending_on, Some("N"))
}

///|
test "clause: OCCURS 下界大于上界报错" {
  let e = parse_err("01 R.\n  05 T OCCURS 5 TO 2 TIMES PIC X(1).")
  assert_true(e.contains("下界"))
}

///|
test "clause: OCCURS 次数为 0 报错" {
  let e = parse_err("01 R.\n  05 T OCCURS 0 TIMES PIC X(1).")
  assert_true(e.contains("必须 >= 1"))
}

///|
test "clause: REDEFINES 只存裸名字" {
  let src = "01 R.\n  05 X PIC X(4).\n  05 Y REDEFINES X PIC 9(4)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[1].redefines, Some("X"))
}

///|
test "clause: VALUE 数字字面量" {
  let src = "01 R.\n  05 A PIC 9(2) VALUE 42."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].value_literal, Some("42"))
}

///|
test "clause: VALUE 'A' 引号字面量" {
  let src = "01 R.\n  05 A PIC X(1) VALUE 'A'."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].value_literal, Some("'A'"))
}

///|
test "clause: VALUE IS ZERO" {
  let src = "01 R.\n  05 A PIC 9(2) VALUE IS ZERO."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].value_literal, Some("ZERO"))
}

///|
test "clause: VALUE SPACES" {
  let src = "01 R.\n  05 A PIC X(5) VALUE SPACES."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children[0].value_literal, Some("SPACES"))
}

///|
test "clause: SIGN IS LEADING SEPARATE" {
  let src = "01 R.\n  05 A PIC S9(5) SIGN IS LEADING SEPARATE."
  let roots = @src.parse_copybook(src)
  match roots[0].children[0].pic {
    Some(p) => {
      assert_true(p.sign_separate)
      assert_true(p.signed)
    }
    None => fail("应为基本项")
  }
}

///|
test "clause: 无关修饰子句被接受（JUSTIFIED / SYNC / BLANK WHEN ZERO）" {
  let src = "01 R.\n  05 A PIC X(5) JUSTIFIED RIGHT.\n  05 B PIC 9(4) SYNC.\n  05 C PIC 9(4) BLANK WHEN ZERO."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children.length(), 3)
}

///|
test "clause: 意料之外的 token 报错并带行列号" {
  let e = parse_err("01 R.\n  05 A PIC 9(4) BOGUS.")
  assert_true(e.contains("意料之外"))
  assert_true(e.contains("2:"))
}

// ============================================================================
// 88 / 66
// ============================================================================

///|
test "88: 条件名不进主树" {
  let src = "01 R.\n  05 STATUS PIC X(1).\n     88 IS-ACTIVE VALUE 'Y'.\n     88 IS-CLOSED VALUE 'N'."
  let roots = @src.parse_copybook(src)
  // 主树里只有 STATUS 一项
  assert_eq(roots[0].children.length(), 1)
  assert_eq(roots[0].children[0].name, "STATUS")
}

///|
test "88: 条件名被单独收集，挂到最近基本项" {
  let src = "01 R.\n  05 STATUS PIC X(1).\n     88 IS-ACTIVE VALUE 'Y'.\n     88 IS-CLOSED VALUE 'N'."
  let conds = @src.parse_copybook_conditions(src)
  assert_eq(conds.length(), 2)
  assert_eq(conds[0].name, "IS-ACTIVE")
  assert_eq(conds[0].parent, "STATUS")
  assert_eq(conds[0].values.length(), 1)
  assert_eq(conds[0].values[0], "'Y'")
  assert_eq(conds[1].name, "IS-CLOSED")
}

///|
test "88: 多个取值 VALUES 1, 2" {
  let src = "01 R.\n  05 CODE PIC 9(1).\n     88 OK-CODE VALUES 1 2 3."
  let conds = @src.parse_copybook_conditions(src)
  assert_eq(conds[0].values.length(), 3)
  assert_eq(conds[0].values[2], "3")
}

///|
test "66: RENAMES 不进主树" {
  let src = "01 R.\n  05 A PIC X(2).\n  05 B PIC X(2).\n  66 AB RENAMES A THRU B."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children.length(), 2)
  let ren = @src.parse_copybook_renames(src)
  assert_eq(ren.length(), 1)
  assert_eq(ren[0].name, "AB")
  assert_eq(ren[0].from, "A")
  assert_eq(ren[0].thru, Some("B"))
}

///|
test "66: 不带 THRU 的 RENAMES" {
  let src = "01 R.\n  05 A PIC X(4).\n  66 A-ALIAS RENAMES A."
  let ren = @src.parse_copybook_renames(src)
  assert_eq(ren[0].from, "A")
  assert_true(ren[0].thru is None)
}

// ============================================================================
// 错误与边界
// ============================================================================

///|
test "err: 非法级别号报错并带行列号" {
  let e = parse_err("50 X PIC 9(1).")
  assert_true(e.contains("期望级别号"))
  assert_true(e.contains("1:1"))
}

///|
test "err: 空文件返回空数组" {
  let roots = @src.parse_copybook("")
  assert_eq(roots.length(), 0)
}

///|
test "err: 只有注释返回空数组" {
  let roots = @src.parse_copybook("* nothing here\n* nor here")
  assert_eq(roots.length(), 0)
}

///|
test "err: PIC 缺模式串报错" {
  let e = parse_err("01 R.\n  05 A PIC.")
  assert_true(e.contains("PIC 子句缺少模式串"))
}

///|
test "err: 行号正确（第 3 行的错误报 3）" {
  let e = parse_err("01 R.\n  05 A PIC 9(1).\n  50 B PIC 9(1).")
  assert_true(e.contains("3:"))
}

///|
test "err: InvalidLayout 无行列号" {
  let e = @src.ParseError::invalid_layout("记录长度不足")
  assert_eq(e.line(), 0)
  assert_eq(e.column(), 0)
  assert_eq(e.message(), "记录长度不足")
  assert_eq(e.to_display(), "记录长度不足")
}

///|
test "err: 语法错误行列号可单独取出" {
  let err = try {
    let _ = @src.parse_copybook("50 X PIC 9(1).")
    @src.ParseError::invalid_layout("不该走到这里")
  } catch {
    e => e
  }
  assert_eq(err.line(), 1)
  assert_eq(err.column(), 1)
}

// ============================================================================
// 三份 examples 的完整解析
// ============================================================================

///|
test "examples: customer.cpy 完整解析" {
  let src = "01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n    05  CUST-NAME      PIC X(30).\n    05  BALANCE        PIC S9(7)V99 COMP-3.\n    05  OPEN-DATE      PIC 9(8).\n    05  FLAGS.\n        10  ACTIVE     PIC X(1).\n        10  TIER       PIC 9(2).\n"
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 1)
  let rec = roots[0]
  assert_eq(rec.name, "CUSTOMER-RECORD")
  assert_eq(rec.children.length(), 5)

  // CUST-ID: 9(8)
  let id = rec.children[0]
  assert_eq(id.name, "CUST-ID")
  match id.pic {
    Some(p) => {
      assert_eq(p.category.name(), "NUMERIC")
      assert_eq(p.digits, 8)
      assert_eq(p.scale, 0)
      assert_true(!p.signed)
      assert_eq(p.usage.name(), "DISPLAY")
    }
    None => fail("CUST-ID 应为基本项")
  }

  // CUST-NAME: X(30)
  match rec.children[1].pic {
    Some(p) => {
      assert_eq(p.category.name(), "ALPHANUMERIC")
      assert_eq(p.digits, 30)
    }
    None => fail("CUST-NAME 应为基本项")
  }

  // BALANCE: S9(7)V99 COMP-3
  match rec.children[2].pic {
    Some(p) => {
      assert_eq(p.category.name(), "NUMERIC")
      assert_eq(p.digits, 7)
      assert_eq(p.scale, 2)
      assert_true(p.signed)
      assert_eq(p.usage.name(), "COMP-3")
    }
    None => fail("BALANCE 应为基本项")
  }

  // FLAGS 是组项
  assert_true(rec.children[4].pic is None)
  assert_eq(rec.children[4].children.length(), 2)
}

///|
test "examples: order.cpy 完整解析" {
  let src = "01  ORDER-LINES.\n    05  ORDER-ID       PIC 9(10).\n    05  LINE-COUNT     PIC 9(3).\n    05  LINES OCCURS 5 TIMES.\n        10  SKU        PIC X(12).\n        10  QTY        PIC S9(4) COMP.\n        10  PRICE      PIC S9(5)V99 COMP-3."
  let roots = @src.parse_copybook(src)
  let rec = roots[0]
  assert_eq(rec.name, "ORDER-LINES")
  assert_eq(rec.children.length(), 3)

  let lines = rec.children[2]
  assert_eq(lines.name, "LINES")
  assert_eq(lines.occurs, 5)
  assert_eq(lines.children.length(), 3)

  match lines.children[1].pic {
    Some(p) => {
      assert_eq(p.digits, 4)
      assert_true(p.signed)
      assert_eq(p.usage.name(), "COMP")
    }
    None => fail("QTY 应为基本项")
  }
  match lines.children[2].pic {
    Some(p) => {
      assert_eq(p.digits, 5)
      assert_eq(p.scale, 2)
      assert_eq(p.usage.name(), "COMP-3")
    }
    None => fail("PRICE 应为基本项")
  }
}

///|
test "examples: redefines.cpy 完整解析" {
  let src = "01  ACCOUNT-MASTER.\n    05  ACCT-NO        PIC 9(12).\n    05  ACCT-TYPE      PIC X(2).\n    05  LIMIT-AMT      PIC S9(9)V99 COMP-3.\n    05  ALT-VIEW REDEFINES LIMIT-AMT.\n        10  RAW-BYTE   PIC X(6).\n    05  SSN            PIC 9(9)."
  let roots = @src.parse_copybook(src)
  let rec = roots[0]
  assert_eq(rec.name, "ACCOUNT-MASTER")
  assert_eq(rec.children.length(), 5)
  assert_eq(rec.children[3].redefines, Some("LIMIT-AMT"))
  match rec.children[2].pic {
    Some(p) => {
      assert_eq(p.digits, 9)
      assert_eq(p.scale, 2)
      assert_eq(p.usage.name(), "COMP-3")
    }
    None => fail("LIMIT-AMT 应为基本项")
  }
}

///|
test "examples: 固定列格式（前 6 列序号）也能解析" {
  // 把 customer.cpy 改写成经典定长格式：6 位序号 + 第 7 列空格
  let src = "000100 01  CUSTOMER-RECORD.\n000200     05  CUST-ID        PIC 9(8).\n000300     05  CUST-NAME      PIC X(30).\n000400     05  BALANCE        PIC S9(7)V99 COMP-3.\n000500     05  OPEN-DATE      PIC 9(8).\n000600     05  FLAGS.\n000700         10  ACTIVE     PIC X(1).\n000800         10  TIER       PIC 9(2)."
  let roots = @src.parse_copybook(src)
  assert_eq(roots.length(), 1)
  assert_eq(roots[0].name, "CUSTOMER-RECORD")
  assert_eq(roots[0].children.length(), 5)
  assert_eq(roots[0].children[4].children.length(), 2)
}

///|
test "examples: 注释行混在数据行之间" {
  let src = "* 客户主档\n01  CUSTOMER-RECORD.\n    05  CUST-ID        PIC 9(8).\n* 下面是金额\n    05  BALANCE        PIC S9(7)V99 COMP-3."
  let roots = @src.parse_copybook(src)
  assert_eq(roots[0].children.length(), 2)
  assert_eq(roots[0].children[1].name, "BALANCE")
}
