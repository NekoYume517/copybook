// CB-B6（2026-11-10 审计）：组级 SIGN 子句被静默丢弃。
//
// ## 缺陷形态（修复前）
//
// COBOL 允许把 SIGN 写在**组项**上（`05 G SIGN IS LEADING.`），作用于组内
// 全部带符号数值项。旧实现只在叶子上合并 sign 标志，组项（pic == None）
// 的那份被原地丢弃：
//
//   p04：`05 G SIGN IS LEADING.` + `10 A PIC S9(3).`，IBM 字节 C1F2F3
//        （= +123，符号区号 C 覆盖首字节）→ decode 报
//        "zoned zone nibble is 0xC, expected F"：**合法主机数据被拒**。
//   p26：`05 G SIGN IS LEADING SEPARATE.` + `10 A PIC S9(3).`
//        → 布局 3 字节（IBM 应 4，多一个独立符号字节），4 字节的真实
//        记录报 "not a multiple of record length 3"。
//
// ## 修复
//
// 照组级 USAGE 的既有继承手法加组级 SIGN 传播（私有 `RawEntry.group_sign`
// → `build_children` 的 `inherited_sign` → 落到叶子 PIC 的
// `sign_leading` / `sign_separate`）。SEPARATE 的 +1 字节由既有叶子级
// `sign_separate` 布局规则自然生效，不新增任何长度逻辑。
//
// 边界（IBM 规则）：组级 SIGN **不**把无符号字段变成有符号（PIC 必须自带
// `S`）；叶子自己写了 SIGN 时叶子优先；只作用于数值项。

///|
fn gsign_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
/// 取一个字段的 Decimal；解不出时用 `abort` 直接失败。
///
/// 不用 `fail()`：本函数签名带 `raise DecodeError`，而 `fail` 抛的是
/// `Failure`，类型对不上（4118）。`abort` 是终止性失败，不走 error 通道。
fn dec_of(layout : RecordLayout, record : Bytes, key : String) -> Decimal {
  let row = match decode_record(layout, record) {
    Ok(r) => r
    Err(e) => abort("\{key}: decode failed: \{e.to_display()}")
  }
  match row.get(key) {
    Some(Decimal(d)) => d
    _ => abort("\{key} must decode to a Decimal")
  }
}

///|
test "CB-B6: 组级 SIGN IS LEADING 让叶子解出首位符号区号（p04）" {
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING.\n        10 A PIC S9(3).\n",
  )
  inspect(layout.byte_length, content="3")
  // C1 F2 F3 = +123（LEADING：符号区号在第一个数字字节上）
  let d = dec_of(layout, b"\xC1\xF2\xF3", "R.G.A")
  assert_eq(d.coefficient, 123L)
  assert_eq(d.negative, false)
  // 负号：D1 F2 F3 = -123
  let neg = dec_of(layout, b"\xD1\xF2\xF3", "R.G.A")
  assert_eq(neg.coefficient, 123L)
  assert_eq(neg.negative, true)
}

///|
test "CB-B6: 组级 SIGN IS LEADING 的记录逐字节往返（p04）" {
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING.\n        10 A PIC S9(3).\n",
  )
  for rec in [b"\xC1\xF2\xF3", b"\xD1\xF2\xF3", b"\xF1\xF2\xF3"] {
    match roundtrip_check(layout, rec) {
      Ok(None) => ()
      Ok(Some(off)) => fail("roundtrip must be byte-identical, diff at \{off}")
      Err(e) => fail("roundtrip must not error: \{e.to_display()}")
    }
  }
}

///|
test "CB-B6: 组级 SIGN IS LEADING SEPARATE 计入额外符号字节（p26）" {
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING SEPARATE.\n        10 A PIC S9(3).\n",
  )
  // IBM：独立符号字节（0x4E = '+'）+ 3 个数字字节 = 4 字节
  inspect(layout.byte_length, content="4")
  let pos = dec_of(layout, b"\x4E\xF1\xF2\xF3", "R.G.A")
  assert_eq(pos.coefficient, 123L)
  assert_eq(pos.negative, false)
  // 0x60 = '-'，0xF4F5F6 = 456
  let neg = dec_of(layout, b"\x60\xF4\xF5\xF6", "R.G.A")
  assert_eq(neg.coefficient, 456L)
  assert_eq(neg.negative, true)
  // 往返逐字节一致
  for rec in [b"\x4E\xF1\xF2\xF3", b"\x60\xF4\xF5\xF6"] {
    match roundtrip_check(layout, rec) {
      Ok(None) => ()
      Ok(Some(off)) => fail("roundtrip must be byte-identical, diff at \{off}")
      Err(e) => fail("roundtrip must not error: \{e.to_display()}")
    }
  }
}

///|
test "CB-B6: 组级裸 SEPARATE 写法也生效（SIGN IS 省略）" {
  // p17_gsep.cpy 的写法 `05 G SIGN IS SEPARATE LEADING.` 在词法/语法层
  // 被拒（LEADING 出现在 SEPARATE 之后不是合法子句顺序），这是**既有**
  // 行为，与组级 SIGN 继承无关，本轮不改。换成标准顺序的等价形态：
  let a = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING SEPARATE.\n        10 A PIC S9(3).\n",
  )
  inspect(a.byte_length, content="4")
  let d = dec_of(a, b"\x4E\xF1\xF2\xF3", "R.G.A")
  assert_eq(d.coefficient, 123L)

  // SIGN IS 省略、只写 SEPARATE 的形态同样按「组级声明」继承
  let b = gsign_layout(
    "01 R.\n    05 G SEPARATE.\n        10 A PIC S9(3).\n",
  )
  inspect(b.byte_length, content="4")
  let e = dec_of(b, b"\xF1\xF2\xF3\x4E", "R.G.A")
  assert_eq(e.coefficient, 123L)
}

///|
test "CB-B6: 组级 SIGN 不把无符号字段变成有符号（IBM 语义）" {
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING.\n        10 A PIC 9(3).\n",
  )
  // 无符号 PIC 没有 S：组级 SIGN 不生效，3 字节照旧、仍按 TRAILING 解。
  // 未符号化 zoned（末字节区号 F）按既有契约解成 Int，不是 Decimal。
  inspect(layout.byte_length, content="3")
  let row = decode_record(layout, b"\xF1\xF2\xF3").unwrap()
  match row.get("R.G.A") {
    Some(Int(i)) => assert_eq(i, 123L)
    _ => fail("unsymbolized zoned must decode to Int")
  }
}

///|
test "CB-B6: 叶子级 SIGN 优先于组级（既有 p15 组合不回归）" {
  // 组声明 LEADING，叶子显式写 TRAILING → 以叶子为准
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING.\n        10 A PIC S9(3) SIGN IS TRAILING.\n",
  )
  inspect(layout.byte_length, content="3")
  let d = dec_of(layout, b"\xF1\xF2\xC3", "R.G.A")
  assert_eq(d.coefficient, 123L)

  // p15_sepl.cpy 原样：组 OCCURS 内叶子 SIGN IS LEADING SEPARATE
  let p15 = gsign_layout(
    "01 R.\n    05 G OCCURS 2 TIMES.\n        10 A PIC S9(3) SIGN IS LEADING SEPARATE.\n    05 H REDEFINES G.\n        10 B OCCURS 2 TIMES PIC 9(2).\n",
  )
  // 2 元素 × (1 符号 + 3 数字) = 8 字节
  inspect(p15.byte_length, content="8")
  let rec = b"\x4E\xF1\xF2\xF3\x60\xF4\xF5\xF6"
  match roundtrip_check(p15, rec) {
    Ok(None) => ()
    Ok(Some(off)) => fail("p15 roundtrip diff at \{off}")
    Err(e) => fail("p15 roundtrip must not error: \{e.to_display()}")
  }
}

///|
test "CB-B6: 组级 SIGN 对组内多个数值叶同时生效" {
  let layout = gsign_layout(
    "01 R.\n    05 G SIGN IS LEADING.\n        10 A PIC S9(3).\n        10 B PIC S9(2).\n",
  )
  inspect(layout.byte_length, content="5")
  let row = decode_record(layout, b"\xC1\xF2\xF3\xD4\xF5").unwrap()
  match row.get("R.G.A") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_eq(d.negative, false)
    }
    _ => fail("R.G.A must decode")
  }
  match row.get("R.G.B") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 45L)
      assert_eq(d.negative, true)
    }
    _ => fail("R.G.B must decode")
  }
}
