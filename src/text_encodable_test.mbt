// 2026-11-17 审计 C5：encode 能写出 decode 明确拒收的字节。
//
// ## 判据
//
// 2026-11-15 的 P3（`__nibbles` sign=13 落在无符号字段上）立的规则是：
// **encode 的输出必须落在 decode 的可接受集合里**。一处反例还没收口 ——
// 文本字段的可打印性只在一个方向强制：
//
//   decode（`decode_text`）  用 `ebcdic_is_printable` 逐字节校验，
//                            C0 / DEL / C1 / U+00AD 一律 InvalidEbcdic；
//   encode（`encode_text`）  用 `ebcdic_encode_strict`，只看"cp037 表里有没有"，
//                            而 cp037 是**全定义**表（8 位全有映射）。
//
// 于是 `PIC X(1)` 写 `"\u{0080}"` 得到 0x20、写 `"\u{00AD}"` 得到 0xCA，
// exit 0、零提示；这条记录随后 decode / verify 必然失败。
//
// `PIC X(n)` 的 UTF-8 文本 → 单字节 EBCDIC 是定时映射，没有任何合法用途需要
// 不可打印码点（控制符出现在文本字段里正是"字段边界算错了"的信号，decode 的
// 注释也这么写），所以在 encode 侧拒收，不动 decode 的既有契约。

///|
fn c5_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
}

///|
fn c5_encode_one(layout : RecordLayout, s : String) -> Result[Bytes, String] {
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text(s)
  match encode_record(layout, row) {
    Err(e) => Err(e.to_display())
    Ok(b) => Ok(b)
  }
}

///|
test "C5: a C1 control codepoint is rejected instead of encoded as 0x20" {
  let layout = c5_layout()
  // U+0080 在 cp037 里是 0x20；decode 判 InvalidEbcdic（C1 区）。
  match c5_encode_one(layout, "\u{0080}") {
    Err(e) => {
      assert_true(e.contains("R.A"))
      assert_true(e.contains("U+0080"))
    }
    Ok(b) =>
      fail("U+0080 must not encode, got 0x\{b[0].to_int().to_string(radix=16)}")
  }
}

///|
test "C5: the soft hyphen is rejected instead of encoded as 0xCA" {
  let layout = c5_layout()
  // U+00AD → 0xCA：cp037 里真实存在，但 decode 的 printable 判定把它排除
  // （Cf 类、不可见）。两边必须一致。
  match c5_encode_one(layout, "\u{00AD}") {
    Err(e) => assert_true(e.contains("U+00AD"))
    Ok(b) =>
      fail("U+00AD must not encode, got 0x\{b[0].to_int().to_string(radix=16)}")
  }
}

///|
test "C5: C0 control characters are rejected too" {
  let layout = c5_layout()
  for s in ["\u{0001}", "\u{0009}", "\u{007F}"] {
    match c5_encode_one(layout, s) {
      Err(_) => ()
      Ok(b) =>
        fail(
          "control character must not encode, got 0x\{b[0].to_int().to_string(radix=16)}",
        )
    }
  }
}

///|
test "C5: printable text still encodes and round-trips" {
  // 反向锁：普通文本（含空格、标点、扩展拉丁）不受影响。
  let layout = c5_layout()
  for s in ["AB", "A ", " A", "a1", "$ ", "\u{00A0} "] {
    match c5_encode_one(layout, s) {
      Ok(b) =>
        match decode_record(layout, b) {
          Ok(m) =>
            match m.get("R.A") {
              Some(Text(back)) =>
                assert_eq(back.trim_end().to_string(), s.trim_end().to_string())
              _ => fail("must decode back to Text")
            }
          Err(e) => fail("printable text must decode: \{e.to_display()}")
        }
      Err(e) => fail("printable text must encode: '\{s}' -> \{e}")
    }
  }
}

///|
test "C5: characters outside cp037 keep the existing not-encodable error" {
  // 另一条方向（表里没有）本来就报错，不能被新守卫抢走。
  let layout = c5_layout()
  match c5_encode_one(layout, "\u{4E2D}") {
    Err(e) => assert_true(e.contains("cp037"))
    Ok(_) => fail("a non-cp037 character must not encode")
  }
}
