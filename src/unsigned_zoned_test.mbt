// P1-3 回归：无符号 zoned（PIC 9(3)）末字节高半字节为 C（正号区号）时，
// decode / encode / verify 三命令必须给出一致的结论，且字节往返保真。
//
// 复现（修复前三命令矛盾）：`9(3)` 无符号，数据 F1 F2 C3 ——
//   decode 接受输出 123 exit 0（decode_zoned 对末字节接受 C/F 记 nibble），
//   但 Int 分支丢 nibble（decode.mbt `pic.scale == 0 && !pic.signed` 走 Int），
//   encode 默认写 F → 往返变 F1 F2 F3，
//   verify exit 1（byte mismatch at offset 2）。
//
// 主机实务里无符号字段写 C 区号很常见（同一程序把字段按 S9 与 9 两种
// copybook 解释），因此选「承载 nibble 往返」（方案 a，与 __nibbles 旁路
// 同一先例），而不是把 C 报 invalid numeric（那会让合法主机数据被拒收）。
// docs/ebcdic-notes.md「Signs are overpunched」一节只定义 D=负、
// C/F=正，未区分有无符号字段，两种区号对无符号字段都是合法字节。

///|
test "unsigned zoned: C zone in the last byte roundtrips byte-identically (P1-3)" {
  let layout = compile_layout(parse_copybook("01 R.\n  05 N PIC 9(3).\n"))
  let record = b"\xF1\xF2\xC3"
  // 1) 宽容解码：值 123，且必须保留 sign_nibble=C（Int 承载、Decimal 承载
  //    两种形态都不能丢——encode 依赖它写回 C）
  let row = decode_record(layout, record).unwrap()
  match row.get("R.N") {
    Some(Decimal(d)) => {
      inspect(d.to_string(), content="123")
      inspect(d.sign_nibble, content="Some(12)")
    }
    Some(Int(i)) => {
      inspect(i.to_string(), content="123")
      fail("unsigned integer zoned must carry the nibble via Decimal (P1-3)")
    }
    _ => fail("R.N must decode")
  }
  // 2) JSONL：__nibbles 必须带出 {"sign":12}，encode 还原 C3
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__nibbles\":{\"R.N\":{\"sign\":12}}"))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  // 3) 内存往返（verify 核心）
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    Ok(Some(off)) => fail("unsigned zoned C roundtrip diff at \{off}")
    Err(_) => fail("unsigned zoned C roundtrip must not error")
  }
}

///|
test "unsigned zoned: F zone stays the default and still roundtrips (P1-3)" {
  // F 区号（未符号化的标准形态）行为不变：仍走 Int 承载（无 nibble 旁路，
  // JSONL 不出现 __nibbles），默认写法也是 F，往返天然一致。
  let layout = compile_layout(parse_copybook("01 R.\n  05 N PIC 9(3).\n"))
  let record = b"\xF1\xF2\xF3"
  let row = decode_record(layout, record).unwrap()
  match row.get("R.N") {
    Some(Int(i)) => inspect(i.to_string(), content="123")
    _ => fail("R.N must decode as Int for F zones")
  }
  let text = render_jsonl(layout, [row])
  assert_false(text.contains("__nibbles"))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), record)
  match roundtrip_check(layout, record) {
    Ok(None) => ()
    _ => fail("F-zone roundtrip must stay byte-identical")
  }
}

///|
test "unsigned zoned: hand-written integer value encodes as all-F zones (P1-3)" {
  // 手写 JSON（无 __nibbles）：默认写法仍是全 F 区（契约不变）。
  let layout = compile_layout(parse_copybook("01 R.\n  05 N PIC 9(3).\n"))
  let values : Map[String, CellValue] = Map([])
  values["R.N"] = Int(123L)
  let encoded = encode_record(layout, values).unwrap()
  assert_eq(encoded, b"\xF1\xF2\xF3")
}
