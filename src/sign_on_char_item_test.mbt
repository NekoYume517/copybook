// 审计回归（2026-11-13）：`SIGN ... SEPARATE` 落在**字符项**上时，布局白给
// 一个符号字节，把后面每个字段整体推后一位。
//
// ## 缺陷形态（修复前，CLI 实测）
//
//     000100 01 R.
//     000200    05 A PIC X(5) SIGN IS SEPARATE.
//     000300    05 B PIC X(1).
//
//     $ copybook layout --copybook xsep.cpy
//     RECORD: R                                        LENGTH: 7 bytes
//     OFFSET  LENGTH  OCCURS  TYPE              NAME
//          0       6       1  X(5) DISPLAY      R.A
//          6       1       1  X(1) DISPLAY      R.B
//     exit 0（`X(5)` 报成 6 字节，`R.B` 从 5 被推到 6）
//
// `PIC X(5)` 是字符类，**没有任何符号位置**：COBOL 的 SIGN 子句只能用于
// 数值项（符号要么覆盖末位区号、要么独占一字节）。同一份输入在 `N(3)` 上
// 却是 6 字节（不加），在 `S9(3) COMP` 上也是 2 字节（不加）—— 只有
// `X/A` 白拿一个字节，这本身就说明该分支没有依据。
//
// ## 为什么必须拒绝而不是「悄悄不加」
//
// 立项原则是「绝不静默修正」，同族先例：编辑型 `SIGN ... SEPARATE` 在
// CB-B12 被显式拒绝（理由同样是「符号没有归属」），组级 `JUSTIFIED` /
// `BLANK WHEN ZERO` 在 2026-11-11 被显式拒绝（理由同样是「声明不生效」）。
// 字符项上的 SIGN 两条都占：既没有符号位置，也不会产生任何语义。给它加一
// 个字节是**凭空发明存储**，悄悄不加则是**声明被吞**。按先例在解析期点名
// 拒绝，并指明正确用法。
//
// ## 不受影响
//
// - 数值项的 `SIGN ... SEPARATE`（zoned 的 +1 符号字节，CB-B12 锁定）；
// - 组级 `SIGN` 继承（CB-B6：只作用于带符号数值叶子，字符叶子本来就不吃）；
// - `COMP` / `COMP-3` / `COMP-1` / `COMP-2` 上的 SIGN：符号在表示内部，
//   照 IBM 忽略（不产生字节，也不报错），API.md 已如实写明。

///|
fn soc_err(cb : String) -> String {
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
test "SIGN on a character item is rejected instead of inventing a sign byte" {
  for
    cb in [
      "01 R.\n    05 A PIC X(5) SIGN IS SEPARATE.\n", "01 R.\n    05 A PIC X(5) SIGN IS LEADING SEPARATE.\n",
      "01 R.\n    05 A PIC X(5) SIGN IS LEADING.\n", "01 R.\n    05 A PIC A(4) SIGN SEPARATE.\n",
      "01 R.\n    05 A PIC N(3) SIGN SEPARATE.\n", "01 R.\n    05 A PIC X(5) SEPARATE.\n",
    ] {
    let msg = soc_err(cb)
    assert_true(msg != "ok")
    // 点名「SIGN 只能用于数值项」
    assert_true(msg.contains("SIGN"))
    assert_true(msg.contains("数值") || msg.contains("numeric"))
  }
}

///|
test "character width is unaffected once SIGN is gone" {
  let layout = compile_layout(
    parse_copybook("01 R.\n    05 A PIC X(5).\n    05 B PIC N(3).\n"),
  )
  inspect(layout.find("R.A").unwrap().byte_length, content="5")
  inspect(layout.find("R.B").unwrap().byte_length, content="6")
  inspect(layout.byte_length, content="11")
}

///|
test "numeric SIGN ... SEPARATE still adds exactly one sign byte" {
  let zoned = compile_layout(
    parse_copybook("01 R.\n    05 A PIC S9(3) SIGN IS TRAILING SEPARATE.\n"),
  )
  inspect(zoned.find("R.A").unwrap().byte_length, content="4")
  // COMP / COMP-3 / COMP-1 的符号在表示内部：SIGN 不产生额外字节（照 IBM 忽略）
  let packed = compile_layout(
    parse_copybook("01 R.\n    05 A PIC S9(3) COMP-3 SIGN IS SEPARATE.\n"),
  )
  inspect(packed.find("R.A").unwrap().byte_length, content="2")
  let float = compile_layout(
    parse_copybook("01 R.\n    05 A PIC S9(4) COMP-1 SIGN IS SEPARATE.\n"),
  )
  inspect(float.find("R.A").unwrap().byte_length, content="4")
}

///|
test "group-level SIGN still reaches signed numeric leaves only" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n    05 G SIGN IS LEADING SEPARATE.\n        10 A PIC S9(3).\n        10 B PIC X(2).\n",
    ),
  )
  // 数值叶子吃 +1 符号字节；字符叶子不受影响
  inspect(layout.find("R.G.A").unwrap().byte_length, content="4")
  inspect(layout.find("R.G.B").unwrap().byte_length, content="2")
  inspect(layout.byte_length, content="6")
}
