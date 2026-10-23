// 负零（-0）在 decode → JSONL → encode 之后必须还是负零。
//
// 背景（CB-2）：zoned `F0 F0 D0` 与 packed `00 0D` 解出的都是
// `Decimal{coefficient: 0, negative: true, sign_nibble: 0xD}`。
// `render_jsonl` 也如实写出了 `{"R.A":-0,"__nibbles":{"R.A":{"sign":13}}}`。
// 但走完 JSONL 文本再编码，字节变回 `F0 F0 F0` / `00 0C`（正零）。
//
// 根因有两处，都在「JSON 文本没有符号位」这个缝隙里：
//   1. `@json` 的词法层对 `-0` 不保留原文（repr 只给超出 double 精确范围的
//      字面量），`format_json_number(-0.0)` 又把 `-0` 折叠成 `"0"`；
//   2. 旁路 `__nibbles.sign` 只被当作「写回哪个半字节」的提示，没有参与
//      符号判定 —— 系数为 0 时它救不回 `negative`。
//
// 而 `verify` 走内存路径（Decimal 对象里的 negative 没丢），于是报
// `byte-identical roundtrip`：它与 JSONL 工作流互相矛盾。这里同时锁定两者。

///|
/// zoned S9(3) + packed S9(3)：5 字节。
fn negzero_layout() -> RecordLayout raise {
  compile_layout(
    parse_copybook("01 R.\n  05 A PIC S9(3).\n  05 B PIC S9(3) COMP-3.\n"),
  )
}

///|
/// 从一条记录里取出某个字段的 Decimal。
fn negzero_decimal(
  layout : RecordLayout,
  key : String,
  rec : Bytes,
) -> Decimal raise {
  match decode_record(layout, rec.exact_view()) {
    Ok(m) =>
      match m.get(key) {
        Some(Decimal(d)) => d
        Some(other) =>
          fail("\{key} expected Decimal, got " + other.to_display())
        None => fail("missing \{key}")
      }
    Err(e) => fail("decode failed: " + e.to_display())
  }
}

///|
/// 走完整文本链路：记录 → JSONL 单行 → parse_jsonl_row → 记录。
///
/// 这就是 `copybook decode --format jsonl > out.jsonl` 再
/// `copybook encode --json out.jsonl` 的真实路径（不含磁盘 I/O）。
fn negzero_jsonl_roundtrip(layout : RecordLayout, rec : Bytes) -> Bytes raise {
  let values = match decode_record(layout, rec.exact_view()) {
    Ok(v) => v
    Err(e) => fail("decode failed: " + e.to_display())
  }
  let rows : Array[Map[String, CellValue]] = [values]
  let jsonl = render_jsonl(layout, rows)
  let lines = jsonl.split("\n").collect()
  if lines.length() == 0 {
    fail("render_jsonl produced no line")
  }
  // JSONL 行必须把符号写出来：`-0` 是合法的 JSON number 字面量
  let line = lines[0].to_owned()
  let parsed = match parse_jsonl_row(layout, line) {
    Ok(m) => m
    Err(msg) => fail("parse_jsonl_row failed: " + msg)
  }
  match encode_record(layout, parsed) {
    Ok(b) => b
    Err(e) => fail("encode failed: " + e.to_display())
  }
}

///|
test "负零：zoned F0F0D0 与 packed 000D 经 JSONL 后逐字节不变（CB-2）" {
  let layout = negzero_layout()
  let rec : Bytes = b"\xF0\xF0\xD0\x00\x0D"
  // 先确认输入本身是负零：zoned 末字节符号 D、packed 低半字节 D
  let zoned = negzero_decimal(layout, "R.A", rec)
  assert_eq(zoned.coefficient, 0L)
  assert_true(zoned.negative)
  assert_eq(zoned.sign_nibble, Some(13))
  let packed = negzero_decimal(layout, "R.B", rec)
  assert_eq(packed.coefficient, 0L)
  assert_true(packed.negative)
  assert_eq(packed.sign_nibble, Some(13))
  // 走文本链路后必须逐字节相同（修复前是 F0 F0 F0 00 0C）
  let back = negzero_jsonl_roundtrip(layout, rec)
  assert_eq(back, rec)
}

///|
test "负零：JSONL 解析出的 Decimal 在系数为 0 时仍带负号（CB-2 根因）" {
  let layout = negzero_layout()
  let rec : Bytes = b"\xF0\xF0\xD0\x00\x0D"
  let values = decode_record(layout, rec.exact_view()).unwrap()
  let rows : Array[Map[String, CellValue]] = [values]
  let jsonl = render_jsonl(layout, rows)
  assert_true(jsonl.contains("\"R.A\":-0"))
  let parsed = parse_jsonl_row(
    layout,
    jsonl.split("\n").collect()[0].to_owned(),
  ).unwrap()
  for key in ["R.A", "R.B"] {
    match parsed.get(key) {
      Some(Decimal(d)) => {
        assert_eq(d.coefficient, 0L)
        assert_true(d.negative)
        assert_eq(d.sign_nibble, Some(13))
      }
      Some(other) => fail("\{key} expected Decimal, got " + other.to_display())
      None => fail("missing \{key}")
    }
  }
}

///|
test "负零：verify 的 OK 与 JSONL 字节一致不再互相矛盾（CB-2）" {
  let layout = negzero_layout()
  let rec : Bytes = b"\xF0\xF0\xD0\x00\x0D"
  // 内存路径（verify）：必须逐字节一致
  match roundtrip_check(layout, rec.exact_view()) {
    Ok(None) => ()
    Ok(Some(off)) => fail("verify reported byte mismatch at \{off}")
    Err(e) => fail("verify failed: " + e.to_display())
  }
  // 文本路径（decode → JSONL → encode）：也必须逐字节一致
  assert_eq(negzero_jsonl_roundtrip(layout, rec), rec)
}

///|
test "正零不被改成负零：zoned F0F0F0 与 packed 000C 保持正号（CB-2 反向）" {
  let layout = negzero_layout()
  let rec : Bytes = b"\xF0\xF0\xF0\x00\x0C"
  match decode_record(layout, rec.exact_view()) {
    Ok(m) =>
      for key in ["R.A", "R.B"] {
        match m.get(key) {
          Some(Decimal(d)) => {
            assert_eq(d.coefficient, 0L)
            assert_false(d.negative)
          }
          Some(other) =>
            fail("\{key} expected Decimal, got " + other.to_display())
          None => fail("missing \{key}")
        }
      }
    Err(e) => fail("decode failed: " + e.to_display())
  }
  // 正零经文本链路后仍是正零字节
  assert_eq(negzero_jsonl_roundtrip(layout, rec), rec)
}
