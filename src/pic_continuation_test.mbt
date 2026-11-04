// PIC 续接段收尾形态的回归（2026-11-04 对抗性审计 NEW-7）。
//
// ## 缺陷形态（修复前）
//
// `05 N PIC S9(3) V99.` —— V 段是 PIC 的最后一段，紧跟语句终止符 `.`：
//
//     parse error: 2:22: 数据项 'N' 的子句里出现意料之外的 标识符 'V99'
//
// 而 `lexer.mbt` 的注释（第 60-67 行）明确声称支持 `PIC S9(7) V99` 这种
// 带空格的写法 —— **它自己举的例子作为语句末尾即失败**。
//
// 相邻形态看起来都正常，所以这个退化很隐蔽：
//   `PIC S9(3) V99 COMP-3.`  -> OK（句点在更后面）
//   `PIC 9(3) P(2).`         -> 修复前同样失败
//
// 根因：`is_pic_continuation` 要求续接段的每个字符都是数字/`P`/括号，
// 末尾那个 `.` 让它整段被判「不是续接段」，于是被当成普通标识符交给语法层。
//
// 修复：判定前剥掉尾随单句点，并入模式串后把扫描位置退回一格让外层发
// Dot token。只剥一个句点（`V99..` 第二个点仍由外层报错）。

///|
fn pic_v_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  N  PIC S9(3) V99.\n"))
}

///|
fn pic_p_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  N  PIC 9(3) P(2).\n"))
}

///|
test "NEW-7: PIC 的 V 段作为语句收尾时正常解析" {
  let layout = pic_v_layout()
  // S9(3)V99：3 位整数 + 2 位小数 = 5 字节（zoned，一位一字节）
  inspect(layout.byte_length, content="5")
  let f = layout.find("R.N").unwrap()
  inspect(f.byte_length, content="5")
}

///|
test "NEW-7: PIC 的 P 段作为语句收尾时正常解析" {
  let layout = pic_p_layout()
  // 9(3)P(2)：P 不占存储
  inspect(layout.byte_length, content="3")
  let f = layout.find("R.N").unwrap()
  inspect(f.byte_length, content="3")
}

///|
test "NEW-7: 句点在更后面的既有写法不受影响" {
  // `PIC S9(3) V99 COMP-3.` 修复前就是好的，锁定不许回退
  let layout = compile_layout(
    parse_copybook("01  R.\n    05  N  PIC S9(3) V99 COMP-3.\n"),
  )
  inspect(layout.byte_length, content="3")
}

///|
test "NEW-7: 双句点仍是语法错误（不因为放宽而吞掉多余点）" {
  // 只剥一个尾随句点：`V99..` 里第二个点不会被当模式内容吞掉，外层报错。
  // （别拿「合法语句后面再跟一个点」当样本——那是空语句，本来就合法。）
  let r = try {
    let _ = compile_layout(
      parse_copybook("01  R.\n    05  N  PIC S9(3) V99..\n"),
    )
    "no error"
  } catch {
    _ => "error"
  }
  inspect(r, content="error")
}
