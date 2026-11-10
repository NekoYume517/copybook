// CB-B5（2026-11-10 审计）：JUSTIFIED RIGHT 被静默忽略，编码恒左对齐。
//
// ## 缺陷形态（修复前）
//
// `_probe/p02_just.cpy`：
//
//     01 R.
//         05 A PIC X(5) JUSTIFIED RIGHT.
//
// `encode --json '{"R.A":"AB"}'` → `C1 C2 40 40 40`（左对齐 + 右侧补空格）。
// IBM 的 JUSTIFIED RIGHT 语义是**右对齐、左侧补空格**：应为
// `40 40 40 C1 C2`。
//
// 更糟的是 `verify` 抓不到：布局自洽，同一份 copybook 上 decode→encode
// 当然往返一致，于是「字节级保真」的结论对这份 copybook 是错的 ——
// 写出去的数据主机按右对齐解读时值是 `"  AB"`，与本意 `AB` 不同。
//
// ## 本轮修法（Lead 已定：实现 IBM 语义，不做警告了事）
//
// 1. 解析期记录 `is_justified`（照 `is_synced` 的既有做法：`parse_entry_clauses`
//    记录 → `RawEntry` → `FieldSpec` → `PicClause`）。
// 2. `encode_text` 对 justified 字段右对齐（左侧补 0x40）。
// 3. 关键不变量：`decode → JSONL → encode` 逐字节一致 —— 见下一条测试，
//    decode 侧**不 trim 前导空格**（既有行为），所以右对齐字段解出的
//    `"  AB"` 回写时正好落回同样的字节。

///|
fn just_layout(cb : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(cb))
}

///|
test "CB-B5: 解析期记录 JUSTIFIED RIGHT（p02）" {
  let layout = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let f = layout.find("R.A").unwrap()
  assert_true(f.pic.justified_right)
  // JUST / JUSTIFIED、带或不带 RIGHT 的写法都识别
  let abbrev = just_layout("01 R.\n    05 A PIC X(5) JUST RIGHT.\n")
  assert_true(abbrev.find("R.A").unwrap().pic.justified_right)
  let bare = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED.\n")
  assert_true(bare.find("R.A").unwrap().pic.justified_right)
  // LEFT（默认）不置标志
  let left = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED LEFT.\n")
  assert_false(left.find("R.A").unwrap().pic.justified_right)
  let plain = just_layout("01 R.\n    05 A PIC X(5).\n")
  assert_false(plain.find("R.A").unwrap().pic.justified_right)
}

///|
test "CB-B5: JUSTIFIED RIGHT 编码右对齐、左侧补 0x40（p02）" {
  let layout = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("AB")
  match encode_record(layout, row) {
    Err(e) => fail("encode must succeed: \{e.to_display()}")
    Ok(bs) =>
      // IBM 语义：右对齐 -> 40 40 40 C1 C2
      assert_eq(bs, b"\x40\x40\x40\xC1\xC2")
  }
}

///|
test "CB-B5: JUSTIFIED RIGHT 的 decode → JSONL → encode 逐字节一致" {
  let layout = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  // 右对齐形态（左侧空格是有效内容）
  let right_aligned = b"\x40\x40\x40\xC1\xC2"
  let jsonl = render_jsonl(layout, [
    decode_record(layout, right_aligned).unwrap(),
  ])
  let parsed = parse_jsonl_row(layout, jsonl).unwrap()
  match encode_record(layout, parsed) {
    Err(e) => fail("re-encode must succeed: \{e.to_display()}")
    Ok(bs) => assert_eq(bs, right_aligned)
  }
  // 内存路径（verify 的核心）同样逐字节一致
  match roundtrip_check(layout, right_aligned) {
    Ok(None) => ()
    Ok(Some(off)) => fail("roundtrip diff at \{off}")
    Err(e) => fail("roundtrip must not error: \{e.to_display()}")
  }
  // 满宽（无填充）与全空格两种边界形态也各自往返
  for rec in [b"\xC1\xC2\xC3\xC4\xC5", b"\x40\x40\x40\x40\x40"] {
    match roundtrip_check(layout, rec) {
      Ok(None) => ()
      Ok(Some(off)) =>
        fail("roundtrip diff at \{off} for \{rec.length()} bytes")
      Err(e) => fail("roundtrip must not error: \{e.to_display()}")
    }
  }
}

///|
test "CB-B5: 未声明 JUSTIFIED 的字段仍左对齐（不伤既有行为）" {
  let layout = just_layout("01 R.\n    05 A PIC X(5).\n")
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text("AB")
  match encode_record(layout, row) {
    Err(e) => fail("encode must succeed: \{e.to_display()}")
    Ok(bs) => assert_eq(bs, b"\xC1\xC2\x40\x40\x40")
  }
  // 数值 / 编辑型即便写了 JUSTIFIED RIGHT 也按原样（COBOL 只对字符项有意义）
  let num = just_layout("01 R.\n    05 A PIC 9(3) JUSTIFIED RIGHT.\n")
  assert_true(num.find("R.A").unwrap().pic.justified_right)
  let nrow : Map[String, CellValue] = Map([])
  nrow["R.A"] = Int(42L)
  match encode_record(num, nrow) {
    Err(e) => fail("numeric encode must succeed: \{e.to_display()}")
    // 3 位 zoned，未符号化：F0 F4 F2（左对齐语义在此不适用）
    Ok(bs) => assert_eq(bs, b"\xF0\xF4\xF2")
  }
}

///|
test "CB-B5: JUSTIFIED RIGHT 的文本往返经 JSONL 保持前导空格" {
  let layout = just_layout("01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n")
  let rec = b"\x40\x40\xC1\xC2\xC3"
  let row = decode_record(layout, rec).unwrap()
  // decode 侧不 trim 前导空格（既有行为，本轮不改）
  match row.get("R.A") {
    Some(Text(s)) => inspect(s, content="  ABC")
    _ => fail("R.A must decode to Text")
  }
  let jsonl = render_jsonl(layout, [row])
  let back = parse_jsonl_row(layout, jsonl).unwrap()
  assert_eq(encode_record(layout, back).unwrap(), rec)
}
