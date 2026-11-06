// 组委会验收意见（2026-11-06）的回归：HFP 零的位级身份（RJ-1）。
//
// ## 缺陷形态（修复前）
//
// IBM HFP 的零由「尾数为 0」定义，**特征值（exponent field）不属于数值**：
// `41 00 00 00`（特征值 65）与 `00 00 00 00`（特征值 0）都是 +0，但字节不同。
// IBM 编译器写零时保留当时的特征位（未赋值存储区惯例），主机数据里两种
// 形态都真实存在。
//
// 修复前 `41 00 00 00` 解出 +0.0，encode 走 `hfp_encode_short` 写回**规范零**
// `00 00 00 00` —— 字节变了，`verify` 直接报 byte mismatch（exit 1）：
//
//     $ copybook verify --copybook hfp0.cpy --data hfp0.dat
//     verify: record 0: byte mismatch at offset 0        exit 1
//
// 「L1 字节级往返」在 HFP 零上被证伪 —— 组委会驳回意见第一条的
// 「HFP 的 41000000 变为 00000000」正是这个。
//
// ## 修复
//
// 与 CB-21 / NEW-2 同构：非规范零挂 `FloatRaw` 原始字节旁路。
// **规范零**（`00 00 00 00` 与 `80 00 00 00`）不挂旁路 —— CB-17 承诺它们
// 经数值列（`0` / `-0`）往返，普通记录的 JSONL 输出保持不变。

///|
fn hfp0_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  F  COMP-1.\n"))
}

///|
fn hfp0_layout8() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01  R.\n    05  F  COMP-2.\n"))
}

///|
test "RJ-1: HFP 零的非规范特征值经 JSONL 逐字节还原（41 00 00 00）" {
  let layout = hfp0_layout()
  let rec = bs([0x41, 0x00, 0x00, 0x00])
  // decode：数值是 0，但字节身份由旁路携带
  let row = decode_record(layout, rec).unwrap()
  match row.get("R.F") {
    Some(FloatRaw(f, raw)) => {
      // 数值仍是 +0
      assert_true(f == 0.0)
      inspect(raw.length(), content="4")
      assert_eq(raw[0].to_int(), 0x41)
    }
    Some(Float(_)) => fail("non-canonical HFP zero must carry FloatRaw")
    _ => fail("expected a float cell")
  }
  // 文本路径往返逐字节一致（修复前得到 00 00 00 00）
  let text = render_jsonl(layout, [row])
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), rec)
  // 内存路径（verify 核心）
  assert_eq(roundtrip_check(layout, rec).unwrap(), None)
}

///|
test "RJ-1: 多种非规范特征值都逐字节还原" {
  let layout = hfp0_layout()
  // 特征值 66、127、以及负零族的非规范形态
  for head in [0x42, 0x7F, 0xC1, 0xFF] {
    let rec = bs([head, 0x00, 0x00, 0x00])
    let row = decode_record(layout, rec).unwrap()
    let text = render_jsonl(layout, [row])
    let parsed = parse_jsonl_row(layout, text).unwrap()
    assert_eq(encode_record(layout, parsed).unwrap(), rec)
  }
}

///|
test "RJ-1: 规范正零不挂旁路（普通记录的 JSONL 输出不变）" {
  let layout = hfp0_layout()
  let rec = bs([0x00, 0x00, 0x00, 0x00])
  let row = decode_record(layout, rec).unwrap()
  match row.get("R.F") {
    Some(Float(_)) => assert_true(true)
    Some(FloatRaw(_, _)) => fail("canonical +0 must stay plain Float")
    _ => fail("expected a float cell")
  }
  let text = render_jsonl(layout, [row])
  assert_false(text.contains("__float_hex"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    rec,
  )
}

///|
test "RJ-1: 规范负零不挂旁路（CB-17 契约不变）" {
  let layout = hfp0_layout()
  let rec = bs([0x80, 0x00, 0x00, 0x00])
  let row = decode_record(layout, rec).unwrap()
  match row.get("R.F") {
    Some(Float(f)) => assert_true(f == 0.0)
    Some(FloatRaw(_, _)) => fail("canonical -0 must stay plain Float (CB-17)")
    _ => fail("expected a float cell")
  }
  // CB-17：JSONL 里必须是 -0，往返字节一致
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("-0"))
  assert_eq(
    encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap(),
    rec,
  )
}

///|
test "RJ-1: COMP-2 的非规范零同样保字节" {
  let layout = hfp0_layout8()
  let rec = bs([0x41, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
  let row = decode_record(layout, rec).unwrap()
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("4100000000000000"))
  let parsed = parse_jsonl_row(layout, text).unwrap()
  assert_eq(encode_record(layout, parsed).unwrap(), rec)
}

///|
test "RJ-1: verify 对全部零形态给出 OK" {
  // 组委会复现的命令形态：verify 必须承认这份主机数据是完好的
  let layout = hfp0_layout()
  for head in [0x00, 0x41, 0x42, 0x7F, 0x80, 0xC1] {
    let rec = bs([head, 0x00, 0x00, 0x00])
    match roundtrip_check(layout, rec) {
      Ok(None) => ()
      Ok(Some(off)) => fail("roundtrip diff at \{off} for 0x\{head}")
      Err(_) => fail("roundtrip error for 0x\{head}")
    }
  }
}
