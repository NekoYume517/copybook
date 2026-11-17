// 2026-11-17 审计 C1 / C8：公开 `RecordLayout` 可由调用方手工构造，**两个方向**
// 都必须显式报错，不能一个报错、另一个 panic。
//
// ## 缺陷形态
//
// `b3d2e81` 只修了读取侧：`decode.mbt` 的 `slice_at` 用 Int64 widening 判越界，
// 返回 `FieldOutOfBounds`（锁定测试见 `manual_layout_boundary_test.mbt`）。
// 写入侧没有任何守卫：`encode_field` 把 `field.offset` / `field.byte_length`
// 直接交给 `Writer::set`，而后者是 `self.buf[offset] = value.to_byte()` ——
// 数组赋值越界在 MoonBit 里是 **panic（abort）**，不是 `DecodeError`。
//
// 同一份边界布局（offset = Int32::MAX、byte_length 2）：
//
//     decode_record(layout, b"\xC1\xC2")   -> Err(FieldOutOfBounds)   （已修）
//     encode_record(layout, {})            -> panic                   （本轮）
//
// ## 两条触发入口（同一根因）
//
// 1. 字段编码：`encode_text` / `encode_zoned` 的 `for i … w.set(offset + i, …)`；
// 2. 空洞回填：`written_intervals` 用的是 `offset + total_length`，若它越界，
//    `filler_gaps` / `primary_tail_gaps` 会算出落在记录之外的区间，
//    `restore` / `restore_at_superset` / `restore_at_gaps` 再 `w.set` 进去。
//
// 两条都由 `encode_record` 入口的同一次区间校验拦住（守卫唯一化）：
// 只要每个字段的写入跨度都在 `[0, byte_length]` 内，空洞集按构造也落在
// 同一区间内（`complement_gaps` 把结果钳在 `[from, to] ⊆ [0, byte_length]`）。

///|
fn c1_base_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC X(2).\n"))
}

///|
test "C1: manual layout with a field past Int32 must not panic on encode" {
  let base = c1_base_layout()
  let field = {
    ..base.fields[0],
    offset: 2147483647,
    byte_length: 2,
    total_length: 2,
  }
  let layout = { ..base, byte_length: 0, fields: [field], all_fields: [field], }
  let values : Map[String, CellValue] = Map([])
  // 红：panic（"index out of bounds"），没有任何 Result 可以断言
  match encode_record(layout, values) {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) => fail("expected FieldOutOfBounds, got \{e.to_display()}")
    Ok(_) => fail("a field outside the record must not encode")
  }
}

///|
test "C1: manual layout whose total_length runs past the record must not encode" {
  // 空洞判定按 total_length 记区间（written_intervals），写入按 byte_length：
  // 只校验后者会漏掉「洞被算到记录之外」这条入口。
  let base = c1_base_layout()
  let field = { ..base.fields[0], offset: 0, byte_length: 2, total_length: 6, }
  let layout = { ..base, byte_length: 4, fields: [field], all_fields: [field], }
  let values : Map[String, CellValue] = Map([])
  match encode_record(layout, values) {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) => fail("expected FieldOutOfBounds, got \{e.to_display()}")
    Ok(_) => fail("total_length past the record must not encode")
  }
}

///|
test "C8: covered_bytes stays inside the record for a hand-built layout" {
  // 一个界内字段 + 一个越界字段：`offset + total_length` 回绕后仍被累加，
  // 旧实现给出 2 —— 而记录的 byte_length 是 0。区间并集必须钳在 [0, byte_length]。
  let base = c1_base_layout()
  let inside = { ..base.fields[0], offset: 0, byte_length: 2, total_length: 2, }
  let outside = {
    ..base.fields[0],
    name: "B",
    path: "R.B",
    offset: 2147483647,
    byte_length: 2,
    total_length: 2,
  }
  let layout = {
    ..base,
    byte_length: 0,
    fields: [inside, outside],
    all_fields: [inside, outside],
  }
  let covered = layout.covered_bytes()
  assert_true(covered >= 0)
  assert_true(covered <= layout.byte_length)

  let wide = {
    ..base,
    byte_length: 10,
    fields: [inside, outside],
    all_fields: [inside, outside],
  }
  let w = wide.covered_bytes()
  assert_true(w >= 0)
  assert_true(w <= wide.byte_length)
}
