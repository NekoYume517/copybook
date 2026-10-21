// ============================================================================
// fidelity_test.mbt — 字节保真（byte fidelity）回归
//
// 这一组测试回答审阅意见里最关键的一条：
//
//   「逐字节无损往返也缺少原始表示的信息保留说明」
//   「用……同值不同符号字节的输入输出案例说明数值正确性与字节保真如何成立」
//
// 核心事实：**同一个数值在 COBOL 存储里有多种合法字节写法**。
// 若 decode 丢掉了「原始字节长什么样」的信息，encode 就只能按自己的偏好
// 重写一遍 —— 数值相同、字节不同，「无损往返」就退化成「数值往返」。
//
// 本项目保留的信息有两类：
//   1. 符号半字节  `sign_nibble`：packed 的末字节低半字节 / zoned 的符号位
//      —— 0xC 与 0xF 都是正号，0xD 是负号
//   2. packed 填充半字节 `pad_nibble`：数字位数为奇数时末字节高半字节
//      —— 0x0 与 0xF 都合法
//
// 两条路径各有测试：
//   · **有字节来源**（decode 出来的值）→ 必须逐字节还原，见下面各 test
//   · **无字节来源**（调用方 new 出来的值）→ 用文档化的默认写法，见末尾
// ============================================================================

// ---------------------------------------------------------------------------
// 1. packed decimal（COMP-3）：正号 C / F，负号 D
// ---------------------------------------------------------------------------

///|
// S9(3) COMP-3 占 2 字节：3 位数字 + 符号 = 4 个半字节。
// 同一个 +123 的两种合法写法，各自必须原样往返。
test "fidelity: COMP-3 正号 0xC 与 0xF 都逐字节还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC S9(3) COMP-3.\n"),
  )
  // 写法 A：0xC 正号（最常见）
  let as_c : Bytes = b"\x12\x3C"
  let m_c = decode_record(layout, as_c).unwrap()
  match m_c.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_true(!d.negative)
      // decode 必须**记住**读到的是 0xC
      assert_eq(d.sign_nibble, Some(0xC))
    }
    _ => fail("expected Decimal")
  }
  let back_c = encode_record(layout, m_c).unwrap()
  assert_eq(back_c[0].to_int(), 0x12)
  assert_eq(back_c[1].to_int(), 0x3C)
  // 写法 B：0xF 正号（IBM 对未符号化字段写的，同样合法）
  let as_f : Bytes = b"\x12\x3F"
  let m_f = decode_record(layout, as_f).unwrap()
  match m_f.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_true(!d.negative)
      assert_eq(d.sign_nibble, Some(0xF))
    }
    _ => fail("expected Decimal")
  }
  // 关键断言：0xF 不能被改写成 0xC
  let back_f = encode_record(layout, m_f).unwrap()
  assert_eq(back_f[0].to_int(), 0x12)
  assert_eq(back_f[1].to_int(), 0x3F)
}

///|
// 负号只有 0xD 一种写法，但它必须与正号严格区分（同值不同符号的对照）。
test "fidelity: COMP-3 负号 0xD 与正号 0xC 数值相反、字节各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC S9(3) COMP-3.\n"),
  )
  let pos : Bytes = b"\x12\x3C"
  let neg : Bytes = b"\x12\x3D"
  let mp = decode_record(layout, pos).unwrap()
  let mn = decode_record(layout, neg).unwrap()
  // 数值：+123 / -123
  match mp.get("R.V") {
    Some(Decimal(d)) => assert_true(!d.negative)
    _ => fail("expected Decimal")
  }
  match mn.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_true(d.negative)
      assert_eq(d.sign_nibble, Some(0xD))
    }
    _ => fail("expected Decimal")
  }
  // 往返：两个 1 字节差异必须保留（C vs D）
  let bp = encode_record(layout, mp).unwrap()
  let bn = encode_record(layout, mn).unwrap()
  assert_eq(bp[1].to_int(), 0x3C)
  assert_eq(bn[1].to_int(), 0x3D)
}

///|
// 无符号字段（PIC 9(n) COMP-3）：IBM 规定正号是 0xF。
// 记录里若出现 0xC（某些工具这么写）也要能读，且读完后原样写回。
test "fidelity: 无符号 COMP-3 的 0xF 与 0xC 都能读且各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC 9(3) COMP-3.\n"),
  )
  for pair in [(b"\x12\x3F", 0x3F), (b"\x12\x3C", 0x3C)] {
    let (rec, want_byte) = pair
    let m = decode_record(layout, rec).unwrap()
    match m.get("R.V") {
      Some(Decimal(d)) => assert_eq(d.coefficient, 123L)
      _ => fail("expected Decimal")
    }
    let back = encode_record(layout, m).unwrap()
    assert_eq(back[1].to_int(), want_byte)
  }
}

///|
// filled nibble：3 位数字占 2 字节时，末字节高半字节是**填充**。
// 0x0 和 0xF 都合法；`12 3C` 是 123，`F2 3C` 也是 123。
test "fidelity: COMP-3 符号半字节在末字节低 4 位（S9(5) 满容量）" {
  // S9(5) → 5 数字 + 符号 = 6 半字节 = 3 字节，**没有填充位**，
  // 是观察符号半字节最干净的形状。
  let l5 = compile_layout(parse_copybook("01 R.\n  05 V PIC S9(5) COMP-3.\n"))
  // 0xC 正号：01 23 4C
  let as_c : Bytes = b"\x01\x23\x4C"
  let mc = decode_record(l5, as_c).unwrap()
  match mc.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 1234L)
      assert_true(!d.negative)
      assert_eq(d.sign_nibble, Some(0xC))
    }
    _ => fail("expected Decimal")
  }
  assert_eq(encode_record(l5, mc).unwrap()[2].to_int(), 0x4C)
  // 0xF 正号：同一数值 1234，字节不同 → 必须原样还原
  let as_f : Bytes = b"\x01\x23\x4F"
  let mf = decode_record(l5, as_f).unwrap()
  match mf.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 1234L)
      assert_eq(d.sign_nibble, Some(0xF))
    }
    _ => fail("expected Decimal")
  }
  assert_eq(encode_record(l5, mf).unwrap()[2].to_int(), 0x4F)
  // 0xD 负号：同一数值、相反符号
  let as_d : Bytes = b"\x01\x23\x4D"
  let md = decode_record(l5, as_d).unwrap()
  match md.get("R.V") {
    Some(Decimal(d)) => assert_true(d.negative)
    _ => fail("expected Decimal")
  }
  assert_eq(encode_record(l5, md).unwrap()[2].to_int(), 0x4D)
}

// ---------------------------------------------------------------------------
// 1b. 同一数值的三种合法字节写法（驳回意见明确要求的那组案例）
// ---------------------------------------------------------------------------

///|
// `PIC 9(4) COMP-3` = 3 字节 = 5 个数字位 + 1 个符号位，声明只用 4 位数字，
// 所以末字节高半字节是**填充**。于是同一个 1234 有三种合法写法：
//
//   `12 34 0C`  填充 0 + 正号 C
//   `12 34 FC`  填充 F + 正号 C
//   `12 34 0F`  填充 0 + 正号 F
//
// 三种写法**数值都是 1234**，字节互不相同。逐字节往返要求各自还原成自己，
// 不能统一成某一种。
test "fidelity: 同一数值 1234 的三种合法 COMP-3 字节写法各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC 9(4) COMP-3.\n"),
  )
  let cases : Array[(Bytes, Int32, Int32)] = [
    (b"\x12\x34\x0C", 0x0, 0xC),
    (b"\x12\x34\xFC", 0xF, 0xC),
    (b"\x12\x34\x0F", 0x0, 0xF),
  ]
  for c in cases {
    let (rec, want_pad, want_sign) = c
    let m = decode_record(layout, rec).unwrap()
    match m.get("R.V") {
      Some(Decimal(d)) => {
        // 数值必须一致
        assert_eq(d.coefficient, 1234L)
        assert_true(!d.negative)
        // 但原始字节信息必须分别记住
        assert_eq(d.sign_nibble, Some(want_sign))
        assert_eq(d.pad_nibble, Some(want_pad))
      }
      _ => fail("expected Decimal")
    }
    let back = encode_record(layout, m).unwrap()
    for i = 0; i < 3; i = i + 1 {
      assert_eq(back[i].to_int(), rec[i].to_int())
    }
  }
}

// ---------------------------------------------------------------------------
// 1c. 负号与填充的组合：同一个 -1234 也只有 0xD 一种符号，但填充仍两种
// ---------------------------------------------------------------------------

///|
test "fidelity: 负数 -1234 的填充半字节 0 与 F 各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC S9(4) COMP-3.\n"),
  )
  for rec in [(b"\x12\x34\x0D", 0x0), (b"\x12\x34\xFD", 0xF)] {
    let (bytes, want_pad) = rec
    let m = decode_record(layout, bytes).unwrap()
    match m.get("R.V") {
      Some(Decimal(d)) => {
        assert_eq(d.coefficient, 1234L)
        assert_true(d.negative)
        assert_eq(d.pad_nibble, Some(want_pad))
      }
      _ => fail("expected Decimal")
    }
    let back = encode_record(layout, m).unwrap()
    for i = 0; i < 3; i = i + 1 {
      assert_eq(back[i].to_int(), bytes[i].to_int())
    }
  }
}

// ---------------------------------------------------------------------------
// 2. zoned decimal（DISPLAY 数值）：符号覆盖末位 / 首位的高半字节
// ---------------------------------------------------------------------------

///|
// zoned 的 `S9(3)`：末字节高半字节是符号。
// `F1 F2 C3` 与 `F1 F2 F3` 都是 123，但字节不同。
test "fidelity: zoned 末位符号 0xC 与 0xF 都逐字节还原" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 V PIC S9(3).\n"))
  // 0xC 正号（最常见）
  let as_c : Bytes = b"\xF1\xF2\xC3"
  let mc = decode_record(layout, as_c).unwrap()
  match mc.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_eq(d.sign_nibble, Some(0xC))
    }
    _ => fail("expected Decimal")
  }
  let bc = encode_record(layout, mc).unwrap()
  assert_eq(bc[2].to_int(), 0xC3)
  // 0xF 正号（未符号化写法，同一数值）
  let as_f : Bytes = b"\xF1\xF2\xF3"
  let mf = decode_record(layout, as_f).unwrap()
  match mf.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_eq(d.sign_nibble, Some(0xF))
    }
    _ => fail("expected Decimal")
  }
  let bf = encode_record(layout, mf).unwrap()
  assert_eq(bf[2].to_int(), 0xF3)
}

///|
// zoned 负号 0xD，与正号 0xC 只差一个半字节。
test "fidelity: zoned 负号 0xD 与正号 0xC 只差一个半字节且各自还原" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 V PIC S9(3).\n"))
  let pos : Bytes = b"\xF1\xF2\xC3"
  let neg : Bytes = b"\xF1\xF2\xD3"
  let mp = decode_record(layout, pos).unwrap()
  let mn = decode_record(layout, neg).unwrap()
  match mn.get("R.V") {
    Some(Decimal(d)) => assert_true(d.negative)
    _ => fail("expected Decimal")
  }
  assert_eq(encode_record(layout, mp).unwrap()[2].to_int(), 0xC3)
  assert_eq(encode_record(layout, mn).unwrap()[2].to_int(), 0xD3)
}

///|
// SIGN SEPARATE：符号独占一字节（EBCDIC 0x4E '+' / 0x60 '-'），
// 数字字节一律 F 区。与内嵌符号是完全不同的字节布局。
test "fidelity: SIGN SEPARATE 的正负号字节各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC S9(3) SIGN IS TRAILING SEPARATE.\n"),
  )
  // 4 字节：3 数字 + 1 符号
  let pos : Bytes = b"\xF1\xF2\xF3\x4E"
  let neg : Bytes = b"\xF1\xF2\xF3\x60"
  let mp = decode_record(layout, pos).unwrap()
  let mn = decode_record(layout, neg).unwrap()
  match mp.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 123L)
      assert_true(!d.negative)
    }
    _ => fail("expected Decimal")
  }
  match mn.get("R.V") {
    Some(Decimal(d)) => assert_true(d.negative)
    _ => fail("expected Decimal")
  }
  let bp = encode_record(layout, mp).unwrap()
  let bn = encode_record(layout, mn).unwrap()
  assert_eq(bp[3].to_int(), 0x4E)
  assert_eq(bn[3].to_int(), 0x60)
}

// ---------------------------------------------------------------------------
// 3. 负零：COBOL 区分 +0 与 -0，字节必须区分
// ---------------------------------------------------------------------------

///|
// `-0` 在 COBOL 里是合法的独立值（比较语义上与 +0 不同），
// 存储上靠符号半字节区分：`00 0C` 是 +0、`00 0D` 是 -0。
test "fidelity: COMP-3 的 +0 与 -0 符号字节不同且各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 V PIC S9(2) COMP-3.\n"),
  )
  let pos_zero : Bytes = b"\x00\x0C"
  let neg_zero : Bytes = b"\x00\x0D"
  let mp = decode_record(layout, pos_zero).unwrap()
  let mn = decode_record(layout, neg_zero).unwrap()
  match mp.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 0L)
      assert_true(!d.negative)
    }
    _ => fail("expected Decimal")
  }
  match mn.get("R.V") {
    Some(Decimal(d)) => {
      assert_eq(d.coefficient, 0L)
      assert_true(d.negative)
    }
    _ => fail("expected Decimal")
  }
  assert_eq(encode_record(layout, mp).unwrap()[1].to_int(), 0x0C)
  assert_eq(encode_record(layout, mn).unwrap()[1].to_int(), 0x0D)
}

// ---------------------------------------------------------------------------
// 4. 无原始字节来源的值：默认写法是**文档化的契约**
// ---------------------------------------------------------------------------

///|
// 调用方自己造的 Decimal 没有原始字节信息，encode 按文档约定写：
//   · 有符号 packed 正号 → 0xC
//   · 无符号 packed 正号 → 0xF（IBM 标准）
//   · 负号 → 0xD
//   · zoned 正号 → 0xF、负号 → 0xD
test "fidelity: 新建值的默认符号写法符合文档契约" {
  let cb = compile_layout(parse_copybook("01 R.\n  05 V PIC S9(3) COMP-3.\n"))
  let m : Map[String, CellValue] = Map([])
  m["R.V"] = Decimal(Decimal::from_parts(123L, 0, false))
  // 有符号 → 0xC
  assert_eq(encode_record(cb, m).unwrap()[1].to_int(), 0x3C)
  m["R.V"] = Decimal(Decimal::from_parts(123L, 0, true))
  // 负号 → 0xD
  assert_eq(encode_record(cb, m).unwrap()[1].to_int(), 0x3D)
  let cu = compile_layout(parse_copybook("01 R.\n  05 V PIC 9(3) COMP-3.\n"))
  let mu : Map[String, CellValue] = Map([])
  mu["R.V"] = Decimal(Decimal::from_parts(123L, 0, false))
  // 无符号 → 0xF（IBM 标准约定，不是 0xC）
  assert_eq(encode_record(cu, mu).unwrap()[1].to_int(), 0x3F)
}

// ---------------------------------------------------------------------------
// 5. 浮点：HFP 没有 NaN / Infinity，必须显式报错而不是写垃圾字节
// ---------------------------------------------------------------------------

///|
test "fidelity: HFP 拒绝 NaN / Infinity（主机格式无这两种特殊值）" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-1.\n"),
  )
  let m : Map[String, CellValue] = Map([])
  m["R.A"] = Float(1.0 / 0.0)
  let r = encode_record(layout, m)
  assert_true(r is Err(_))
  m["R.A"] = Float(0.0 / 0.0)
  assert_true(encode_record(layout, m) is Err(_))
}

///|
// HFP 的 ±0 靠符号位区分（与 packed 的 -0 同理）。
test "fidelity: HFP 的 +0 与 -0 符号位不同且各自还原" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(4) COMP-1.\n"),
  )
  let pos : Bytes = b"\x00\x00\x00\x00"
  let neg : Bytes = b"\x80\x00\x00\x00"
  let bp = encode_record(layout, decode_record(layout, pos).unwrap()).unwrap()
  let bn = encode_record(layout, decode_record(layout, neg).unwrap()).unwrap()
  assert_eq(bp[0].to_int(), 0x00)
  assert_eq(bn[0].to_int(), 0x80)
}

// ---------------------------------------------------------------------------
// 6. 端到端：decode → JSONL → encode 也必须逐字节还原
// ---------------------------------------------------------------------------

///|
// `verify` 走内存内 decode→encode，不经过 JSON。但真实工作流往往要
// 「导出成 JSONL、编辑、再导回」—— 这条路径上 JSON 数字没有地方放符号
// 半字节，若不单独携带，`12 34 FC` 会被重编码成 `12 34 0C`。
//
// 本测试锁定旁路键 `__nibbles` 的存在与效果。
test "fidelity: decode → JSONL → encode 三者之后仍逐字节一致" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n" + "  05 PK PIC S9(4) COMP-3.\n" + "  05 ZN PIC S9(3).\n",
    ),
  )
  // PK: 1234 带填充 F + 正号 C（非默认写法）
  // ZN: 123 带正号 C（区别于默认的 F）
  let original : Bytes = b"\x12\x34\xFC\xF1\xF2\xC3"
  let decoded = decode_record(layout, original).unwrap()
  let jsonl = render_jsonl(layout, [decoded])
  assert_true(jsonl.contains("__nibbles"))
  let rows : Array[Map[String, CellValue]] = []
  for line in jsonl.split("\n") {
    if line.length() > 0 {
      rows.push(parse_jsonl_row(layout, line.to_owned()).unwrap())
    }
  }
  assert_eq(rows.length(), 1)
  let back = encode_record(layout, rows[0]).unwrap()
  assert_eq(back.length(), original.length())
  for i = 0; i < original.length(); i = i + 1 {
    assert_eq(back[i].to_int(), original[i].to_int())
  }
}

///|
// 没有十进制字段（无 nibble 信息）时，JSONL 不该多出 `__nibbles` 键。
test "fidelity: 无符号信息的记录不写 __nibbles 旁路键" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 T PIC X(4).\n"))
  let rec : Bytes = b"\xC1\xC2\xC3\xC4"
  let decoded = decode_record(layout, rec).unwrap()
  let jsonl = render_jsonl(layout, [decoded])
  assert_true(!jsonl.contains("__nibbles"))
}
