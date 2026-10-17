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

// ============================================================================
// 4. COMP-1 / COMP-2：README 声称支持 ✅，此前 decode/encode 直接报
//    "not implemented"。实现为 IEEE 754 大端位模式。
// ============================================================================

///|
test "audit: COMP-1 单精度 IEEE 754 大端解码与编码" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-1.\n"),
  )
  inspect(layout.byte_length, content="4")
  // 1.5f32 的 binary32 位模式 = 0x3FC00000，大端存放
  let rec : Bytes = b"\x3F\xC0\x00\x00"
  let m = decode_record(layout, rec).unwrap()
  match m.get("R.A") {
    Some(Float(f)) => {
      let d = f - 1.5
      assert_true(d.abs() < 0.0000001)
    }
    _ => fail("expected Float")
  }
  // 编码回去必须逐字节还原
  let bytes = encode_record(layout, m).unwrap()
  assert_eq(bytes[0].to_int(), 0x3F)
  assert_eq(bytes[1].to_int(), 0xC0)
  assert_eq(bytes[2].to_int(), 0x00)
  assert_eq(bytes[3].to_int(), 0x00)
  // -2.5f32 = 0xC0200000
  let neg : Bytes = b"\xC0\x20\x00\x00"
  let m2 = decode_record(layout, neg).unwrap()
  match m2.get("R.A") {
    Some(Float(f)) => {
      let d = f + 2.5
      assert_true(d.abs() < 0.0000001)
    }
    _ => fail("expected Float")
  }
}

///|
test "audit: COMP-2 双精度 IEEE 754 大端解码与编码" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(9) COMP-2.\n"),
  )
  inspect(layout.byte_length, content="8")
  // 3.14 的 binary64 位模式大端 = 40 09 1E B8 51 EB 85 1F
  let rec : Bytes = b"\x40\x09\x1E\xB8\x51\xEB\x85\x1F"
  let m = decode_record(layout, rec).unwrap()
  match m.get("R.A") {
    Some(Float(f)) => {
      let d = f - 3.14
      assert_true(d.abs() < 0.000000001)
    }
    _ => fail("expected Float")
  }
  let bytes = encode_record(layout, m).unwrap()
  for i = 0; i < 8; i = i + 1 {
    assert_eq(bytes[i].to_int(), rec[i].to_int())
  }
  // 负数：-3.14 = 0xC0091EB851EB851F
  let neg : Bytes = b"\xC0\x09\x1E\xB8\x51\xEB\x85\x1F"
  let m2 = decode_record(layout, neg).unwrap()
  match m2.get("R.A") {
    Some(Float(f)) => {
      let d = f + 3.14
      assert_true(d.abs() < 0.000000001)
    }
    _ => fail("expected Float")
  }
}

///|
test "audit: COMP-1/COMP-2 编码接受数值文本（JSONL 路径）" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(9) COMP-2.\n"),
  )
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Text("2.5")
  let bytes = encode_record(layout, m).unwrap()
  // 2.5 的 binary64 = 0x4004000000000000
  let expect : Array[Int32] = [
    0x40, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]
  for i = 0; i < 8; i = i + 1 {
    assert_eq(bytes[i].to_int(), expect[i])
  }
  // 解码回来验证值
  let m2 = decode_record(layout, bytes).unwrap()
  match m2.get("R.A") {
    Some(Float(f)) => {
      let d = f - 2.5
      assert_true(d.abs() < 0.000000001)
    }
    _ => fail("expected Float")
  }
}

///|
test "audit: 数字位超过 18 的 PIC 在解析期报错" {
  let e1 = parse_err("01 R.\n  05 A PIC 9(19).")
  assert_true(e1.contains("18"))
  let e2 = parse_err("01 R.\n  05 A PIC S9(9)V9(10).")
  assert_true(e2.contains("18"))
  let e3 = parse_err("01 R.\n  05 A PIC 9(19) COMP-3.")
  assert_true(e3.contains("18"))
  // 18 位整是合法上界
  let ok = parse_copybook("01 R.\n  05 A PIC S9(17)V9(1).")
  assert_eq(ok.length(), 1)
}
test "audit: 无符号 COMP-3 的 -0 编码后必须仍可解码" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 A PIC 9(3) COMP-3.\n"))
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Decimal(Decimal::from_parts(0L, 0, true))
  let bytes = encode_record(layout, m).unwrap()
  // 解码必须成功（packed 符号半字节 0xD 出现在无符号字段会报错）
  match decode_record_ordered(layout, bytes) {
    Ok(v) =>
      match v[0] {
        Decimal(d) => {
          assert_true(d.coefficient == 0L)
        }
        _ => fail("expected Decimal")
      }
    Err(e) => fail(e.to_display())
  }
}
