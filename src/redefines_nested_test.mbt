// 审计回归（2026-11-12）：**嵌套 REDEFINES** 被 B10 重叠判据误拒。
//
// ## 缺陷形态（修复前 `compile_layout` 直接抛 InvalidLayout）
//
//     01 R.
//        05 M.
//           10 A PIC X(2).
//           10 B REDEFINES A PIC X(2).
//        05 V REDEFINES M PIC X(4).
//
// `R.V` 重定义的是**组** `R.M`（跨度 2 字节），V 的 4 字节里超出目标的
// 2 字节落在记录尾部空洞（该处没有别的字段），按 CB-9 / CB-15 / CB-16 的
// 尾部保真契约应当合法。但 `check_redefine_overlap` 只看「组 id 是否相同」：
//
//   - `R.M.A` / `R.M.B` 因为是 A←B 的重定义对，被分配组 1；
//   - `R.M` / `R.V` 因为是 M←V 的重定义对，被分配组 2；
//
// 于是「V 的跨度 vs A/B 的跨度」被当成两个无关字段在抢字节 —— 报
// `REDEFINES view 'R.M.A' (offset 0, length 2) overlaps field 'R.V'`。
// 报错还把方向说反了：A 是目标组内的原主，V 才是视图。
//
// ## 根因
//
// 判据缺失了「视图可以重新描述**目标项整棵子树**的存储」这一条：组 id 只表达
// 「这两个字段共享同一段字节」的直接父子关系，不表达「目标组内部的一切都在
// 目标的跨度之内」。修法是把「目标的存储区间」作为豁免区间带进检查（见
// `Builder.target_spans`），判据变成「视图不得与**豁免区间之外**的叶子重叠」。
//
// 这同时保住了 B10 的原意：视图溢出目标区间、压到目标之外的字段上仍然拒绝。

///|
fn nested_layout_err(cb : String) -> String {
  try {
    let _ = compile_layout(parse_copybook(cb))
    "ok"
  } catch {
    e => e.to_display()
  } noraise {
    _ => "ok"
  }
}

///|
test "nested redefines: a view of a group that itself contains a redefine pair compiles" {
  // probe/nest1.cpy：目标组内部已有一个重定义对
  let cb = "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n  05 V REDEFINES M PIC X(4).\n"
  inspect(nested_layout_err(cb), content="ok")
  let layout = compile_layout(parse_copybook(cb))
  inspect(layout.byte_length, content="4")
  inspect(layout.find("R.M.A").unwrap().offset, content="0")
  inspect(layout.find("R.M.B").unwrap().offset, content="0")
  inspect(layout.find("R.V").unwrap().offset, content="0")
  inspect(layout.find("R.V").unwrap().total_length, content="4")
  // 目标组与视图共享组；组内重定义对自成另一组
  let a = layout.find("R.M.A").unwrap()
  let v = layout.find("R.V").unwrap()
  assert_true(a.redefine_group != 0)
  assert_true(v.redefine_group != 0)
  assert_true(a.redefine_group != v.redefine_group)
}

///|
test "nested redefines: tail bytes beyond the redefined group survive the JSONL roundtrip" {
  // 嵌套形态的视图同样享受 CB-9 尾部保真：V 的 2..4 是空洞，字节必须原样保留
  let cb = "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n  05 V REDEFINES M PIC X(4).\n"
  let layout = compile_layout(parse_copybook(cb))
  let record = bs([0xC1, 0xC2, 0xFF, 0xEE])
  let row = decode_record(layout, record).unwrap()
  match row.get("R.M.A") {
    Some(Text(s)) => inspect(s, content="AB")
    _ => fail("R.M.A must decode")
  }
  // A 与 B 是同一段字节的两个视图，解出同一个值
  match row.get("R.M.B") {
    Some(Text(s)) => inspect(s, content="AB")
    _ => fail("R.M.B must decode")
  }
  // V 覆盖 0..4，含不可打印字节 → Null；尾部 2..4 由 __tail_hex 保真
  assert_true(row.get("R.V") is Some(Null))
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"__tail_hex\":\"ffee\""))
  let encoded = encode_record(layout, parse_jsonl_row(layout, text).unwrap()).unwrap()
  assert_eq(encoded, record)
}

///|
test "nested redefines: a target group that is longer than its own first item still exempts" {
  // 目标组内部的视图把组撑长到 4 字节：整棵子树（0..4）都在豁免区间内
  let cb = "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(4).\n  05 V REDEFINES M PIC X(4).\n"
  inspect(nested_layout_err(cb), content="ok")
  let layout = compile_layout(parse_copybook(cb))
  inspect(layout.byte_length, content="4")
  inspect(layout.find("R.M.B").unwrap().total_length, content="4")
  inspect(layout.find("R.V").unwrap().offset, content="0")
}

///|
test "nested redefines: two separate redefine pairs inside the target are both exempt" {
  // 目标组内部有两个互不相干的重定义对，视图覆盖整组 —— 仍然合法
  let cb = "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n    10 C PIC X(2).\n    10 D REDEFINES C PIC X(2).\n  05 V REDEFINES M PIC X(4).\n"
  inspect(nested_layout_err(cb), content="ok")
  let layout = compile_layout(parse_copybook(cb))
  inspect(layout.byte_length, content="4")
  inspect(layout.find("R.V").unwrap().total_length, content="4")
}

///|
test "nested redefines: spilling past the redefined group onto another field is still rejected" {
  // 豁免只到目标组的跨度为止。V 的 6 字节里 2..4 压在同层的 W 上 ——
  // B10 的原意（视图不得吞掉别的字段）必须继续生效。
  let cb = "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n  05 W PIC X(2).\n  05 V REDEFINES M PIC X(6).\n"
  let msg = nested_layout_err(cb)
  assert_true(msg.contains("overlaps"))
  assert_true(msg.contains("R.V"))
  assert_true(msg.contains("R.W"))
}
