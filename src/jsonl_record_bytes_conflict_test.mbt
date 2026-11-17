// 2026-11-17 审计 C10：`__record_bytes` 与 JSONL 旁路键并存时静默胜出，
// 长度不足时静默跳过 —— 都是 CB-15 那一类"洞里的字节悄悄变 0x40"。
//
// ## 背景
//
// `__record_bytes` 是**内存路径**的载体：宽容解码在布局有空洞时把整条原始记录
// 挂在结果 map 上，`encode_record` 按绝对偏移回填（`verify` 走的就是这条）。
// JSONL 路径的载体是 `__tail_hex` / `__filler_hex` 加配套几何。
//
// ## 两条缺陷
//
// 1. **键冲突无仲裁**：`encode_record` 先看 `__record_bytes`，命中就整条短路
//    —— 同一行里的 `__tail_hex` / `__filler_hex` 被无声忽略（既不回填也不报错，
//    也没有键对账）。decode 自己产出的 map 只会有前者，但公开 API 允许混填。
// 2. **长度不足静默跳过**：`restore` 闭包是 `if src < bs.length() { w.set(...) }`，
//    比布局短的 `__record_bytes` 会让没被覆盖的洞落回 Writer 初值 0x40 ——
//    与 CB-15 修复前的损坏形态完全一样，只是入口换成了内存路径。

///|
fn c10_hole_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook("01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M PIC X(4).\n"),
  )
}

///|
test "C10: __record_bytes plus __tail_hex is a key conflict" {
  let layout = c10_hole_layout()
  let row : Map[String, CellValue] = Map([])
  row["__record_bytes"] = Bytes(bs([0xC3, 0xC4, 0xFF, 0xFE]))
  row["__tail_hex"] = Bytes(bs([0xFF, 0xFE]))
  match encode_record(layout, row) {
    Err(e) => {
      assert_true(e.to_display().contains("__record_bytes"))
      assert_true(e.to_display().contains("__tail_hex"))
    }
    Ok(b) =>
      fail(
        "two carriers for the same hole bytes must be arbitrated, got \{b.length()} byte(s)",
      )
  }
}

///|
test "C10: __record_bytes plus __filler_hex is a key conflict too" {
  let layout = c10_hole_layout()
  let row : Map[String, CellValue] = Map([])
  row["__record_bytes"] = Bytes(bs([0xC3, 0xC4, 0xFF, 0xFE]))
  row["__filler_hex"] = Bytes(bs([0xFF, 0xFE]))
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("__record_bytes"))
    Ok(_) => fail("__filler_hex must conflict with __record_bytes as well")
  }
}

///|
test "C10: a too-short __record_bytes must not silently skip hole bytes" {
  let layout = c10_hole_layout()
  inspect(layout.byte_length, content="4")
  let row : Map[String, CellValue] = Map([])
  // 只给前 2 字节：洞 [2,4) 在旧实现里被 `src < bs.length()` 静默跳过 → 0x40
  row["__record_bytes"] = Bytes(bs([0xC3, 0xC4]))
  match encode_record(layout, row) {
    Err(e) => assert_true(e.to_display().contains("__record_bytes"))
    Ok(b) =>
      fail(
        "a short __record_bytes must be rejected, hole bytes became 0x40 at offset 2: \{b[2].to_int()}",
      )
  }
}

///|
test "C10: the in-memory roundtrip still works through __record_bytes" {
  // 反向锁：decode 自己产出的 map（`__record_bytes` 恒为整条记录）照旧逐字节回填。
  let layout = c10_hole_layout()
  let rec = bs([0xC3, 0xC4, 0xFF, 0xFE])
  let row = decode_record(layout, rec).unwrap()
  assert_true(row.get("__record_bytes") is Some(_))
  match encode_record(layout, row) {
    Ok(b) => assert_eq(b, rec)
    Err(e) => fail("in-memory roundtrip must still work: \{e.to_display()}")
  }
}
