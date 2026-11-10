// CB-B12（2026-11-10 审计）：SIGN SEPARATE 用在 Edited PIC 上被静默吞掉。
//
// ## 缺陷形态（修复前）
//
// `_probe/p05_edsep.cpy`：
//
//     01 R.
//        05 A PIC ZZ9.99 SIGN IS SEPARATE.
//
// exit 0，LENGTH 6（`ZZ9.99` 的显示宽度 6），**没有** +1 的独立符号字节。
//
// ## 为什么不是 bug 而是必须报错
//
// IBM 的编辑型（Edited / numeric-edited）PIC 自带符号位置：`+` `-` 浮动的
// 插入字符、`CR` / `DB` 后缀、以及 `S` 前缀都在**模式串内部**表达符号。
// 标准不允许在 edited item 上再叠加 `SIGN ... SEPARATE` —— 符号既已在
// 模式串里，独立符号字节没有归属。而本实现的既有行为是「悄悄接受声明、
// 悄悄不写那个字节」：copybook 说 7 字节、写出来 6 字节，与真实 IBM
// 编译器的布局不一致，且 `verify` 因两侧都用同一份错布局仍报
// byte-identical —— 正是「拒绝静默修正」要拦的形态。
//
// 修法：`parse_entry_clauses` 合并 SIGN 标志进 PIC 时，若
// `category == Edited` 且 `sign_separate`，显式抛 SyntaxError。
//
// 不受影响：无 SIGN 的编辑型（`PIC ZZ9.99`）、带 CR/DB 的编辑型、
// 数值型的 `SIGN ... SEPARATE`（只允许 Display 数值类吃 +1 字节，
// 见 layout.mbt 的 pic_byte_length）。

///|
fn edsep_err(cb : String) -> String {
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
test "CB-B12: 编辑型 PIC + SIGN IS SEPARATE 被拒绝（p05）" {
  let msg = edsep_err("01 R.\n    05 A PIC ZZ9.99 SIGN IS SEPARATE.\n")
  assert_true(msg != "ok")
  // 点名被违反的规则：编辑型不允许 SIGN SEPARATE
  assert_true(msg.contains("SEPARATE"))
  assert_true(msg.contains("Edit") || msg.contains("编辑"))
}

///|
test "CB-B12: 编辑型的其他 SIGN 写法同样被拒绝（LEADING/TRAILING SEPARATE）" {
  assert_true(
    edsep_err("01 R.\n    05 A PIC ZZ9.99 SIGN IS LEADING SEPARATE.\n") != "ok",
  )
  // 省略 SIGN IS 的裸 SEPARATE 也是同一子句
  assert_true(edsep_err("01 R.\n    05 A PIC ZZ9.99 SEPARATE.\n") != "ok")
}

///|
test "CB-B12: 无 SIGN 的编辑型与 CR/DB 编辑型行为不变" {
  let plain = compile_layout(parse_copybook("01 R.\n    05 A PIC ZZ9.99.\n"))
  inspect(plain.byte_length, content="6")

  let cr = compile_layout(parse_copybook("01 R.\n    05 A PIC 9(5)CR.\n"))
  inspect(cr.byte_length, content="7")

  let db = compile_layout(parse_copybook("01 R.\n    05 A PIC 9(5)DB.\n"))
  inspect(db.byte_length, content="7")
}

///|
test "CB-B12: 数值型的 SIGN SEPARATE 仍正常工作（只对编辑型收紧）" {
  // TRAILING SEPARATE：3 位数字 + 1 符号字节 = 4
  let trailing = compile_layout(
    parse_copybook("01 R.\n    05 A PIC S9(3) SIGN IS TRAILING SEPARATE.\n"),
  )
  inspect(trailing.byte_length, content="4")
  // LEADING SEPARATE 同理
  let leading = compile_layout(
    parse_copybook("01 R.\n    05 A PIC S9(3) SIGN IS LEADING SEPARATE.\n"),
  )
  inspect(leading.byte_length, content="4")
  // 且仍能解出 IBM 字节（0x60 = '-'，0xF1F2F3 = 123 -> -123）
  match decode_record(trailing, b"\xF1\xF2\xF3\x60") {
    Ok(row) =>
      match row.get("R.A") {
        Some(Decimal(d)) => {
          assert_eq(d.coefficient, 123L)
          assert_eq(d.negative, true)
        }
        _ => fail("R.A must be a Decimal")
      }
    Err(e) => fail("legal IBM bytes must decode: \{e.to_display()}")
  }
}
