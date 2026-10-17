// 对抗性审查回归测试（audit）
//
// 每个 test 对应一个审查发现的真实缺陷，先红后绿。

// ============================================================================
// 1. SIGN SEPARATE：zoned 字段的独立符号字节此前既不被编码写出、也不被解码
//    接受 —— 编码出的记录长度对但第 4 字节是 0x00，回读必然 InvalidNumeric。
// ============================================================================

///|
test "audit: SIGN SEPARATE zoned 编码写入独立符号字节且可解码" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3) SIGN IS TRAILING SEPARATE.\n"),
  )
  // 3 位数字 + 1 个独立符号字节
  inspect(layout.byte_length, content="4")
  // 正数：F1 F2 F3 4E（EBCDIC '+'）
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Decimal(Decimal::from_parts(123L, 0, false))
  let bytes = encode_record(layout, m).unwrap()
  assert_eq(bytes[0].to_int(), 0xF1)
  assert_eq(bytes[1].to_int(), 0xF2)
  assert_eq(bytes[2].to_int(), 0xF3)
  assert_eq(bytes[3].to_int(), 0x4E)
  match decode_record_ordered(layout, bytes) {
    Ok(v) =>
      match v[0] {
        Decimal(d) => {
          assert_true(d.coefficient == 123L)
          assert_true(!d.negative)
        }
        _ => fail("expected Decimal")
      }
    Err(e) => fail(e.to_display())
  }
  // 负数：F1 F2 F3 60（EBCDIC '-'）
  let m2 : Map[String, CellValue] = Map([])
  m2["R.A"] = Decimal(Decimal::from_parts(123L, 0, true))
  let bytes2 = encode_record(layout, m2).unwrap()
  assert_eq(bytes2[3].to_int(), 0x60)
  match decode_record_ordered(layout, bytes2) {
    Ok(v) =>
      match v[0] {
        Decimal(d) => {
          assert_true(d.coefficient == 123L)
          assert_true(d.negative)
        }
        _ => fail("expected Decimal")
      }
    Err(e) => fail(e.to_display())
  }
  // 直接解码外部字节：正/负/非法符号
  let pos : Bytes = b"\xF1\xF2\xF3\x4E"
  match decode_record_ordered(layout, pos) {
    Ok(v) =>
      match v[0] {
        Decimal(d) => assert_true(!d.negative && d.coefficient == 123L)
        _ => fail("expected Decimal")
      }
    Err(e) => fail(e.to_display())
  }
  let neg : Bytes = b"\xF1\xF2\xF3\x60"
  match decode_record_ordered(layout, neg) {
    Ok(v) =>
      match v[0] {
        Decimal(d) => assert_true(d.negative && d.coefficient == 123L)
        _ => fail("expected Decimal")
      }
    Err(e) => fail(e.to_display())
  }
  let bad : Bytes = b"\xF1\xF2\xF3\xC3"
  match decode_record_ordered(layout, bad) {
    Ok(_) => fail("expected error")
    Err(InvalidNumeric(_, detail)) =>
      assert_true(detail.contains("separate sign"))
    Err(_) => fail("expected InvalidNumeric")
  }
}

// ============================================================================
// 2. FILLER：COBOL 语义是「占字节但不进输出」。此前 FILLER 作为普通叶子
//    字段出现在 layout.fields 与解码结果里，多个 FILLER 还会撞同一个
//    map 键。
// ============================================================================

///|
test "audit: FILLER 占字节但不进入解码输出" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(2).\n  05 FILLER PIC X(3).\n  05 B PIC 9(2).\n",
    ),
  )
  // FILLER 的 3 字节必须占位：B 在 offset 5，总长 7
  inspect(layout.byte_length, content="7")
  inspect(layout.find("B").unwrap().offset, content="5")
  // FILLER 不出现在可解码叶子列表里
  let mut has_filler = false
  for f in layout.fields {
    if f.name == "FILLER" {
      has_filler = true
    }
  }
  inspect(has_filler, content="false")
  // 解码结果里没有 FILLER 键
  let rec : Bytes = b"\xC1\xC2\x40\x40\x40\xF4\xF2"
  let m = decode_record(layout, rec).unwrap()
  assert_true(m.get("R.FILLER") is None)
  inspect(m.length(), content="2")
  match m.get("R.A") {
    Some(Text(s)) => inspect(s, content="AB")
    _ => fail("R.A")
  }
  match m.get("R.B") {
    Some(Int(i)) => inspect(i, content="42")
    _ => fail("R.B")
  }
}

///|
test "audit: 多个 FILLER 字段不互相干扰" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 FILLER PIC X(2).\n  05 A PIC 9(2).\n  05 FILLER PIC X(1).\n  05 B PIC X(1).\n",
    ),
  )
  inspect(layout.byte_length, content="6")
  inspect(layout.find("A").unwrap().offset, content="2")
  inspect(layout.find("B").unwrap().offset, content="5")
  let rec : Bytes = b"\x40\x40\xF1\xF2\x40\xC3"
  let m = decode_record(layout, rec).unwrap()
  assert_true(m.get("R.FILLER") is None)
  inspect(m.length(), content="2")
  match m.get("R.B") {
    Some(Text(s)) => inspect(s, content="C")
    _ => fail("R.B")
  }
}

// ============================================================================
// 3. 输入健壮性：UTF-8 BOM 会让 tokenize 直接抛「无法识别的字符」；
//    只有 \r 没有换行的文件同理。
// ============================================================================

///|
test "audit: UTF-8 BOM 开头的 copybook 可解析" {
  let bom = Char::from_int(0xFEFF).to_string()
  let src = bom + "01 R.\n  05 A PIC X(2)."
  let roots = parse_copybook(src)
  assert_eq(roots.length(), 1)
  assert_eq(roots[0].name, "R")
  assert_eq(roots[0].children.length(), 1)
}

///|
test "audit: 只有 CR 没有换行的 copybook 可解析" {
  let src = "01 R.\r  05 A PIC X(2).\r  05 B PIC 9(2)."
  let roots = parse_copybook(src)
  assert_eq(roots.length(), 1)
  assert_eq(roots[0].children.length(), 2)
}
