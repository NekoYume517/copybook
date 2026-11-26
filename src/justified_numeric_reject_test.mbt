// CB-19-2（2026-11-27 审计）：JUSTIFIED RIGHT 用在数值项与编辑型上被静默吞掉。
//
// ## 缺陷形态（修复前）
//
//     01 R.
//        05 A PIC S9(4) COMP-3 JUSTIFIED RIGHT.
//
// exit 0，LENGTH 3，布局里既没有警告也没有错误。同一子句写在**编辑型**上
// （`PIC ZZ9.99 JUSTIFIED RIGHT`）同样 exit 0。而写在**组项**上会被明确拒绝：
//
//     JUSTIFIED 只能用于基本字符项（alphabetic / alphanumeric / national），
//     不能用在组项 'R' 上（IBM 规则）
//
// 同一份声明在一种语法位置上报错、在另外两种上被静默丢弃 —— 这正是 CB-B12
// （编辑型 + SIGN SEPARATE）与 2026-11-13（字符项 + SIGN）要拦的形态。
//
// ## 为什么不是 bug 而是必须报错
//
// IBM 的 `JUSTIFIED`/`JUSTIFIED RIGHT` 子句只改变**字符类**基本项的填充方向：
// 值放在最右侧、左侧补空格。数值项（zoned / COMP 族）的存储是数字位与符号
// 半字节，没有「填充方向」可言；编辑型（numeric-edited）的每个字符位置由
// PICTURE 模式串（`ZZ9V99`、`$$$$9.99`、`CR`/`DB`）固定，右对齐会破坏小数点
// 与符号位置。标准因此不允许在数值项 / 编辑型上写这个子句。
//
// 本实现的既有行为是「照收声明、照旧按左对齐编码」：copybook 声明了一个
// 编码器完全不理会、也不告诉调用者的属性。`docs/implementation.md` 与
// `parser.mbt` 的注释把它写成「其余类别按原样透传、由编码路径忽略」——
// 「忽略」在这套契约里的字面含义就是**静默丢弃**，与「拒绝静默修正」冲突。
// 更糟的是 `verify` 因两侧用同一份被忽略的布局仍报 byte-identical，
// 缺陷在往返测试里也看不见。
//
// ## 修法
//
// 解析期把 `JUSTIFIED RIGHT` 的有效性收紧到字符类（与组项拒绝同一处判定权
// 威）：数值 / 编辑型 / NATIONAL 以外的类别显式抛 SyntaxError，点名规则。
// 可编程构造的 `PicClause`（`RecordLayout` 可公开手工构造）仍按旧语义由
// 编码路径忽略 —— 那条路径没有语法位置可报错，断言由 `layout` 层守。
//
// 不受影响：字符类（`X(n)` / `A(n)` / `N(n)`）的 JUSTIFIED RIGHT 照旧右对齐，
// 见 `justified_right_national_test.mbt` 与本节末尾的对照用例。

///|
fn jr_err(cb : String) -> String {
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
/// 单字段编码成十六进制串，便于整字节断言。
fn jnr_hex(layout : RecordLayout, v : CellValue) -> String raise {
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = v
  let bytes = match encode_record(layout, row) {
    Ok(bs) => bs
    Err(e) => fail("encode must succeed: \{e.to_display()}")
  }
  let digits = b"0123456789abcdef"
  let sb = StringBuilder()
  for b in bytes {
    let x = b.to_int()
    sb.write_char(digits[(x >> 4) & 0xF].to_int().unsafe_to_char())
    sb.write_char(digits[x & 0xF].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// 缺陷本体：编辑型 + JUSTIFIED RIGHT 必须被拒绝，而不是 exit 0 后静默忽略。
test "CB-19-2: 编辑型 PIC + JUSTIFIED RIGHT 被拒绝" {
  let msg = jr_err("01 R.\n    05 A PIC ZZ9.99 JUSTIFIED RIGHT.\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("JUSTIFIED"))
}

///|
/// 同族：数值项（zoned / COMP-3 / COMP）同样必须拒。
test "CB-19-2: 数值项 + JUSTIFIED RIGHT 被拒绝" {
  for pic in ["S9(4)", "S9(4) COMP", "S9(4) COMP-3", "9(3)V99"] {
    let msg = jr_err("01 R.\n    05 A PIC \{pic} JUSTIFIED RIGHT.\n")
    assert_true(msg != "ok")
    assert_true(msg.contains("JUSTIFIED"))
  }
}

///|
/// 裸 `JUSTIFIED`（不带 RIGHT）与 `JUSTIFIED IS RIGHT` 是同一子句，一并收紧。
test "CB-19-2: JUSTIFIED 的三种写法在数值项上都被拒绝" {
  for clauses in ["JUSTIFIED", "JUSTIFIED RIGHT", "JUSTIFIED IS RIGHT"] {
    let msg = jr_err("01 R.\n    05 A PIC S9(4) COMP-3 \{clauses}.\n")
    assert_true(msg != "ok")
  }
}

///|
/// 对照：字符类仍正常工作，且真的右对齐（不能为了修数值侧把字符侧打死）。
test "CB-19-2: 字符类 JUSTIFIED RIGHT 行为不变" {
  let x = compile_layout(
    parse_copybook("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n"),
  )
  inspect(x.byte_length, content="5")
  // 值 "123" 右对齐 → 前面 2 个 EBCDIC 空格
  assert_eq(jnr_hex(x, Text("123")), "4040f1f2f3")
  // 左对齐的对照组：同样的值写在前面
  let l = compile_layout(parse_copybook("01 R.\n    05 A PIC X(5).\n"))
  assert_eq(jnr_hex(l, Text("123")), "f1f2f34040")
}

///|
/// 对照：NATIONAL 的 JUSTIFIED RIGHT 也保持（UTF-16BE 补 0x0020）。
test "CB-19-2: NATIONAL JUSTIFIED RIGHT 行为不变" {
  let n = compile_layout(
    parse_copybook("01 R.\n    05 A PIC N(5) JUSTIFIED RIGHT.\n"),
  )
  inspect(n.byte_length, content="10")
  assert_eq(jnr_hex(n, Text("12")), "00200020002000310032")
}

///|
/// 对照：组项上的 JUSTIFIED 仍是原来的拒绝消息（不能把这条判据拆掉）。
test "CB-19-2: 组项 + JUSTIFIED 仍被拒绝" {
  let msg = jr_err("01 R JUSTIFIED RIGHT.\n    05 A PIC X(2).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("JUSTIFIED"))
}
