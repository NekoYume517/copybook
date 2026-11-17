// 2026-11-17 审计 C7：`__tail_gap` 比当前空洞短 —— **已声明语义**，不是截断缺陷。
//
// ## 为什么这里不拦
//
// `__filler_gap` 有一条 `filler_snapshot_complete` 判据（`156b43d` 加），拦
// 「静态 FILLER / 布局裂缝被几何截断」。尾部几何只有三条判据（升序不相交、
// 恰好一个区间、右端到记录末尾），看起来少了同一条。但尾部这个缺口是
// **不可证伪**的：
//
//   1. `byte_length` 是某个**非主字段**（视图）的末端，而 `primary_end` 是主视图
//      的末端。任何 `p ∈ [primary_end, byte_length)` 都落在「末端达到 byte_length
//      的那个视图」的跨度内 —— 所以尾部的每个位置**都**至少被一个视图覆盖；
//   2. 于是 `filler_snapshot_complete` 里那条「位置在某个 REDEFINES 视图内 ⇒
//      可能是刚被置 Null 新暴露」的豁免，在尾部**恒真**；
//   3. `jsonl_gap_geometry_test.mbt` 的 shape 2 就是合法形态：decode 时视图写了
//      那段、快照只覆盖后半截，用户把视图置 Null 后空洞向左扩张，前段本来就没有
//      旧字节 → 按未赋值存储写 0x40（API.md §6 已声明）。
//
// 换句话说：「几何比当前空洞短」与「某个视图刚被置为 null」在编码器的可见信息里
// **完全同形**，任何"更严格"的判据都会打掉 shape 2 这条既有锁定测试。所以按
// Lead 裁决保留实现，只把这条语义写成显式断言，并写进 API.md。

///|
test "C7: a tail geometry shorter than the current gap means a view went null" {
  // tg_layout: A X(2) | M X(2) | V2 REDEFINES M X(4) | V4 REDEFINES M X(8)
  //            → byte_length 10、primary_end 4、尾部超集 [4,10)
  let layout = tg_layout()
  // V2 有值 → 已写 [2,6)；V4 为 null → 当前尾部空洞 [6,10)。
  // 几何只声明 [8,10)：等价于「V4 之外还有视图曾解出、现在被置 Null」，
  // 被省略的 [6,8) 没有旧字节可恢复。
  let line = "{\"R.A\":\"AB\",\"R.M\":\"CD\",\"R.V2\":\"CDEF\",\"R.V4\":null,\"__tail_hex\":\"f7f8\",\"__tail_gap\":[[8,10]]}"
  match parse_jsonl_row(layout, line) {
    Err(e) => fail("this row is a declared-tolerated shape, it must parse: \{e}")
    Ok(row) =>
      match encode_record(layout, row) {
        Err(e) =>
          fail(
            "declared tolerance (view set to null) must still encode: \{e.to_display()}",
          )
        Ok(b) => {
          // [6,8) 按"未赋值存储"落 0x40 —— API.md §6 的已声明语义
          assert_eq(b[6].to_int(), 0x40)
          assert_eq(b[7].to_int(), 0x40)
          // 声明的 [8,10) 原样回填
          assert_eq(b[8].to_int(), 0xF7)
          assert_eq(b[9].to_int(), 0xF8)
        }
      }
  }
}
