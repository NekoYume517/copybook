// 审计回归（2026-11-11）：numeric-edited 的 PIC 里出现了 `S`。
//
// IBM Enterprise COBOL「Data categories and PICTURE rules / Numeric-edited
// items」把 numeric-edited 的符号集限定为：
//
//     B  P  V  Z  9  0  /  ,  .  +  -  CR  DB  *  cs
//
// 没有 `S`。`S` 只用于 numeric 项（"For all numeric fields, the PICTURE
// character-string can contain only the symbols 9, P, S, and V"），且在
// numeric 项里「Not counted in the size ... unless SIGN SEPARATE」。
//
// 旧实现把 `S` 收进 Edited 且不计入 digits，等于把一份**不符合标准**的
// copybook 静默当成合法输入：字段被当成无符号显示文本，`signed` 标志
// 也没有任何落盘形态。按项目「绝不静默修正」的原则，这里显式报
// SyntaxError，并点名正确的编辑符号。

///|
fn es_err(src : String) -> String {
  try {
    let _ = parse_copybook(src)
    ""
  } catch {
    e => e.to_display()
  }
}

///|
test "numeric-edited rejects the numeric-only S symbol" {
  for pic in ["S$9,999.99", "S9(3).99", "SZZ9", "S9(5)CR"] {
    let msg = es_err("01 R.\n  05 A PIC \{pic}.\n")
    assert_true(msg.contains("S"))
    assert_true(msg.contains("numeric-edited"))
  }
}

///|
test "S in a numeric item still works and still occupies no byte" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3).\n  05 B PIC S9(7)V99 COMP-3.\n"),
  )
  inspect(layout.find("R.A").unwrap().byte_length, content="3")
  inspect(layout.find("R.B").unwrap().byte_length, content="5")
  // SIGN SEPARATE 才加一个独立符号字节
  let sep = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3) SIGN SEPARATE.\n"),
  )
  inspect(sep.find("R.A").unwrap().byte_length, content="4")
}

///|
test "numeric-edited without S keeps working" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC $9,999.99.\n"))
  inspect(layout.find("R.A").unwrap().byte_length, content="9")
}
