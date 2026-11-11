// 审计回归（2026-11-11）：P（缩放位）出现在数字位中间。
//
// IBM Enterprise COBOL「P symbol」：
//   "The symbol P can be specified only as a continuous string of Ps in the
//    leftmost or rightmost digit positions within a PICTURE character-string."
//
// 也就是说 P 只能是一段连续的 Ps，并且所有数字位都在它的同一侧。
// `PIC 9(3)PPV99`（P 夹在整数位与小数位之间）和 `PIC 9PP9` 都不是合法
// PICTURE；旧实现照收，并按「尾随 P 把 scale 取负」的公式给出一个
// 静默错误的量级：
//
//     PIC 9(3)PPV99  存储 5 位、实现算成 scale=-2（= 系数 ×100），
//                    而 P 的语义要求小数位 V99 参与 —— 值域完全变了。
//
// 按「绝不静默修正」，P 不在两端时在解析期报错。

///|
fn psp_err(pic : String) -> String {
  try {
    let _ = parse_copybook("01 R.\n  05 A PIC \{pic}.\n")
    ""
  } catch {
    e => e.to_display()
  }
}

///|
test "P between digit positions is rejected" {
  for pic in ["9(3)PPV99", "9PP9", "P9P", "PP9PP"] {
    let msg = psp_err(pic)
    assert_true(msg.contains("P"))
    assert_true(
      msg.contains("最左") || msg.contains("最右") || msg.contains("连续"),
    )
  }
}

///|
test "P at the leftmost/rightmost digit positions is still accepted" {
  for pic in ["9(3)PP", "PP9(3)", "PP9(3)V99", "9(3)V99PP", "PPV99"] {
    let msg = psp_err(pic)
    inspect(msg, content="")
  }
  let a = parse_pic_clause("9(3)PP", 1, 1)
  inspect(a.storage_digits, content="3")
  inspect(a.scale, content="-2")
  let b = parse_pic_clause("PP9(3)V99", 1, 1)
  inspect(b.storage_digits, content="5")
  inspect(b.scale, content="7")
}
