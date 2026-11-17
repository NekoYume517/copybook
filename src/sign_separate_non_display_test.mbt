// 2026-11-17 审计 C2：`SIGN ... SEPARATE` 写在 COMP 族上时，文档与实现相反。
//
// ## 声明（三处一致）
//
//   API.md:173               `COMP`/`COMP-3`/`COMP-1`/`COMP-2` | `SIGN ... SEPARATE`
//                            | +0（符号在表示内部，**照 IBM 忽略该子句**）
//   README.md:183            同上（zoned 吃 +1 符号字节；COMP 族不加字节）
//   docs/implementation.md   同上（PICTURE 符号表）
//
// `src/sign_on_char_item_test.mbt:82-90` 只锁了**宽度**（2 / 4 字节）。
//
// ## 缺陷形态
//
// `parser.mbt` 的 `signed: pc.signed || sign_separate` 让这个"被忽略"的子句把
// 字段从无符号翻成有符号，于是**同一段字节的数值解释变了**：
//
//     PIC 9(2) COMP SIGN IS SEPARATE   喂 FF FF
//       声明是无符号 2 位（容量 99）→ 本应 InvalidNumeric
//       实际解出 -1（补码最高位当符号位）
//
//     PIC 9(3) COMP-3 SIGN IS SEPARATE  喂 12 3D
//       无符号 packed 的负号 → 本应 "unsigned packed decimal has negative sign"
//       实际解出 -123
//
// 这与 2026-11-13「字符项写 SIGN 在解析期显式拒绝」同族：加字节是凭空发明
// 存储，翻符号是凭空发明符号位。显式写了 `S` 的字段（`PIC S9(n) COMP`）不受
// 影响 —— 它本来就是有符号的。

///|
fn c2_decode(
  copybook : String,
  bytes : Bytes,
) -> Result[CellValue, String] raise ParseError {
  let layout = compile_layout(parse_copybook(copybook))
  match decode_record(layout, bytes) {
    Err(e) => Err(e.to_display())
    Ok(m) =>
      match m.get("R.A") {
        Some(v) => Ok(v)
        None => Err("no R.A")
      }
  }
}

///|
test "C2: SIGN SEPARATE must not make an unsigned COMP field signed" {
  // 子句被声明为「照 IBM 忽略」：宽度仍是 2，且 FF FF 仍是「超出 2 位声明容量」。
  match
    c2_decode(
      "01 R.\n  05 A PIC 9(2) COMP SIGN IS SEPARATE.\n",
      bs([0xFF, 0xFF]),
    ) {
    Err(e) => assert_true(e.contains("decimal digits"))
    Ok(v) =>
      fail("unsigned COMP must still reject FF FF, got \{v.to_display()}")
  }
}

///|
test "C2: SIGN SEPARATE must not make an unsigned COMP-3 field signed" {
  match
    c2_decode(
      "01 R.\n  05 A PIC 9(3) COMP-3 SIGN IS SEPARATE.\n",
      bs([0x12, 0x3D]),
    ) {
    Err(e) =>
      assert_true(e.contains("unsigned packed decimal has negative sign"))
    Ok(v) =>
      fail("unsigned COMP-3 must still reject a D sign, got \{v.to_display()}")
  }
}

///|
test "C2: an explicit S still makes COMP / COMP-3 signed" {
  // 显式 S 的有符号字段不受这条修复影响：FF FF 是 -1，12 3D 是 -123。
  match
    c2_decode(
      "01 R.\n  05 A PIC S9(2) COMP SIGN IS SEPARATE.\n",
      bs([0xFF, 0xFF]),
    ) {
    Ok(Decimal(d)) => {
      assert_eq(d.coefficient, 1L)
      assert_true(d.negative)
    }
    Ok(v) => fail("expected a Decimal, got \{v.to_display()}")
    Err(e) => fail("signed COMP must decode FF FF as -1: \{e}")
  }
  match
    c2_decode(
      "01 R.\n  05 A PIC S9(3) COMP-3 SIGN IS SEPARATE.\n",
      bs([0x12, 0x3D]),
    ) {
    Ok(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_true(d.negative)
    }
    Ok(v) => fail("expected a Decimal, got \{v.to_display()}")
    Err(e) => fail("signed COMP-3 must decode 12 3D as -123: \{e}")
  }
}

///|
test "C2: SIGN SEPARATE stays inert on COMP-1 / COMP-2" {
  // 浮点项没有符号字节也没有十进制容量，「忽略」的字面结果就是解析结果不变。
  let plain = compile_layout(parse_copybook("01 R.\n  05 A COMP-1.\n"))
  let sep = compile_layout(
    parse_copybook("01 R.\n  05 A COMP-1 SIGN IS SEPARATE.\n"),
  )
  inspect(plain.byte_length, content="4")
  inspect(sep.byte_length, content="4")
  assert_true(!sep.fields[0].pic.signed)
  let hfp = bs([0x41, 0x18, 0x00, 0x00]) // HFP 1.5
  match (decode_record(plain, hfp), decode_record(sep, hfp)) {
    (Ok(a), Ok(b)) =>
      match (a.get("R.A"), b.get("R.A")) {
        (Some(Float(x)), Some(Float(y))) => {
          assert_eq(x, 1.5)
          assert_eq(y, 1.5)
        }
        _ => fail("both layouts must decode to Float")
      }
    _ => fail("both layouts must decode the same HFP bytes")
  }
}

///|
test "C2: zoned SIGN SEPARATE keeps making the field signed" {
  // zoned（DISPLAY 数值）上 SIGN SEPARATE 是**真的**让字段带符号：符号独占
  // 一个字节，`F0 F0 F0 60` 是 -0。这条修复不能碰它。
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC 9(3) SIGN IS SEPARATE.\n"),
  )
  inspect(layout.fields[0].byte_length, content="4")
  assert_true(layout.fields[0].pic.signed)
  match decode_record(layout, bs([0xF0, 0xF0, 0xF0, 0x60])) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Decimal(d)) => {
          assert_eq(d.coefficient, 0L)
          assert_true(d.negative)
        }
        _ => fail("zoned SEPARATE must decode -0")
      }
    Err(e) => fail("zoned SEPARATE must decode: \{e.to_display()}")
  }
}
