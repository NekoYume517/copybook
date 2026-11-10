// CB-B7（2026-11-10 审计）：BLANK WHEN ZERO 被静默接受，全空格零记录解不出。
//
// ## 缺陷形态（修复前）
//
// `_probe/p03_bz.cpy`：
//
//     01 R.
//         05 A PIC 9(3) BLANK WHEN ZERO.
//
// IBM 语义：值为 0 时该字段落盘是**全空格**（`40 40 40`）。`_probe/p03_bz.dat`
// 正是这三个字节，而 `decode` 报
//
//     invalid numeric at offset 0: zoned zone nibble is 0x4, expected F (byte 0x40)
//
// —— 一条完全合法的 IBM 记录被拒，报错内容还与 copybook 的声明直接矛盾
// （copybook 明明说「零就是空格」）。`parser.mbt` 的 BLANK 分支把子句整段
// 吃掉、什么也不记。
//
// ## 本轮修法（Lead 已定：实现语义）
//
// 1. 解析期记录 `blank_when_zero`（照 `is_synced` / `justified_right` 的
//    既有做法，逐层带到 `PicClause`）。
// 2. `decode_zoned`：该标志的字段若**全为 0x40** → 值 0（正号）。
// 3. `encode`：值为 0 时写回**全空格**，否则 `decode → JSONL → encode`
//    不闭环（全空格读进 0、写回 `F0 F0 F0`，字节变了）。非零数据不受影响。
// 4. COMP / COMP-3 上的 BWZ 按 IBM 规范是 no-op（只对 DISPLAY 数值有效）：
//    不报错、也不生效，代码里写明。

///|
fn bz_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
test "CB-B7: 解析期记录 BLANK WHEN ZERO（p03）" {
  let layout = bz_layout("01 R.\n    05 A PIC 9(3) BLANK WHEN ZERO.\n")
  assert_true(layout.find("R.A").unwrap().pic.blank_when_zero)
  let plain = bz_layout("01 R.\n    05 A PIC 9(3).\n")
  assert_false(plain.find("R.A").unwrap().pic.blank_when_zero)
  // 缩写形式 BLANK WHEN ZEROS / BLANK WHEN ZEROES 同样是该子句
  assert_true(
    bz_layout("01 R.\n    05 A PIC 9(3) BLANK WHEN ZEROS.\n")
    .find("R.A")
    .unwrap().pic.blank_when_zero,
  )
}

///|
test "CB-B7: 全空格零记录解出 0（p03 的 40 40 40）" {
  let layout = bz_layout("01 R.\n    05 A PIC 9(3) BLANK WHEN ZERO.\n")
  match decode_record(layout, b"\x40\x40\x40") {
    Err(e) => fail("IBM all-blank zero must decode: \{e.to_display()}")
    Ok(row) =>
      match row.get("R.A") {
        Some(Int(i)) => assert_eq(i, 0L)
        Some(Decimal(d)) => assert_eq(d.coefficient, 0L)
        _ => fail("R.A must be a numeric zero")
      }
  }
}

///|
test "CB-B7: 全空格零记录 decode → JSONL → encode 逐字节一致" {
  let layout = bz_layout("01 R.\n    05 A PIC 9(3) BLANK WHEN ZERO.\n")
  let rec = b"\x40\x40\x40"
  let row = decode_record(layout, rec).unwrap()
  let jsonl = render_jsonl(layout, [row])
  let back = parse_jsonl_row(layout, jsonl).unwrap()
  match encode_record(layout, back) {
    Err(e) => fail("re-encode must succeed: \{e.to_display()}")
    // 必须写回全空格，而不是 F0 F0 F0
    Ok(bs) => assert_eq(bs, rec)
  }
  // 内存路径（verify 的核心）同样逐字节一致
  match roundtrip_check(layout, rec) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(e) => fail("roundtrip must not error: \{e.to_display()}")
  }
}

///|
test "CB-B7: 非零数据行为不变（含往返）" {
  let layout = bz_layout("01 R.\n    05 A PIC 9(3) BLANK WHEN ZERO.\n")
  for rec in [b"\xF1\xF2\xF3", b"\xF1\xF2\xC3", b"\xF0\xF0\xF1"] {
    match roundtrip_check(layout, rec) {
      Ok(None) => ()
      Ok(Some(off)) => fail("roundtrip diff at \{off}")
      Err(e) => fail("roundtrip must not error: \{e.to_display()}")
    }
  }
  let row = decode_record(layout, b"\xF1\xF2\xF3").unwrap()
  match row.get("R.A") {
    Some(Int(i)) => assert_eq(i, 123L)
    _ => fail("non-zero zoned must decode to Int")
  }
}

///|
test "CB-B7: 无 BWZ 声明的字段见到全空格仍然报错（不静默放宽）" {
  let layout = bz_layout("01 R.\n    05 A PIC 9(3).\n")
  match decode_record(layout, b"\x40\x40\x40") {
    Err(_) => ()
    Ok(_) => fail("all-blank zoned without BLANK WHEN ZERO must be rejected")
  }
}

///|
test "CB-B7: COMP / COMP-3 上的 BWZ 是 no-op（不报错、也不生效）" {
  // IBM：BLANK WHEN ZERO 只对 DISPLAY 数值有效，其余 usage 上被忽略
  let comp3 = bz_layout("01 R.\n    05 A PIC S9(3) COMP-3 BLANK WHEN ZERO.\n")
  inspect(comp3.byte_length, content="2")
  // 打包的零是 00 0C，解出 0；不会因为 BWZ 就要求全空格
  match decode_record(comp3, b"\x00\x0C") {
    Err(e) => fail("packed zero must decode: \{e.to_display()}")
    Ok(row) =>
      match row.get("R.A") {
        Some(Decimal(d)) => assert_eq(d.coefficient, 0L)
        _ => fail("R.A must decode")
      }
  }
  // 编码零仍按 packed 默认写法（不写全空格）
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(0L)
  match encode_record(comp3, row) {
    Err(e) => fail("packed encode must succeed: \{e.to_display()}")
    Ok(bs) => assert_eq(bs, b"\x00\x0C")
  }
}
