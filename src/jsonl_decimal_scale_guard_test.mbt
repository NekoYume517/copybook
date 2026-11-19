// 2026-11-20：__nibbles 的 scale 对齐必须复用 align_scale 的有界实现。
// 公开手工 PicClause 的 scale 不受 parser 的 [-18,18] 约束；零系数在任意
// scale 之间转换仍是零，不能按目标 scale 空转数十亿次。

///|
test "JSONL nibble alignment short-circuits zero at extreme PIC scales" {
  // 重复构造让未短路的 O(|scale|) 实现在独立超时进程里稳定可观测，
  // 修复后每次构造都是 O(1)，不会拖慢日常测试。
  for _ in 0..<20 {
    for scale in [2000000000, -2147483648] {
      let layout = c11_layout(scale)
      let line = "{\"R.A\":0,\"__nibbles\":{\"R.A\":{\"sign\":12}}}"
      let row = parse_jsonl_row(layout, line).unwrap()
      // encode_field 的 PIC scale 守卫仍是最终业务错误；本断言到达这里本身
      // 就证明 parse_jsonl_row 没有先在重复的对齐循环里挂死。
      match encode_record(layout, row) {
        Err(e) => assert_true(e.to_display().contains("scale"))
        Ok(_) => fail("an absurd PIC scale must be rejected by encode")
      }
    }
  }
}

///|
test "JSONL nibble alignment preserves ordinary zero and precision errors" {
  let layout = c11_layout(0)
  let zero = parse_jsonl_row(
    layout, "{\"R.A\":0,\"__nibbles\":{\"R.A\":{\"sign\":12}}}",
  ).unwrap()
  match encode_record(layout, zero) {
    Ok(bytes) => assert_eq(bytes.to_array(), [b'\xF0', b'\xF0', b'\xC0'])
    Err(e) => fail("ordinary zero must still encode: \{e.to_display()}")
  }
  let inexact = parse_jsonl_row(
    layout, "{\"R.A\":1.2,\"__nibbles\":{\"R.A\":{\"sign\":12}}}",
  ).unwrap()
  match encode_record(layout, inexact) {
    Err(e) => assert_true(e.to_display().contains("fractional digits"))
    Ok(_) => fail("inexact scale reduction must remain an error")
  }
}
