// CB-20 回归：布局编译期必须**拒绝**产生重复 path 键的字段。
//
// 复现（修复前）：两个同名 01（README 把「多个 01 并列拼接」列为已声明的
// 支持形态）各含一个 `05 A`，两者都编译成路径 `R.A`，map 键撞车：
//   decode  C1 C2  ->  {"R.A":"B"}      （C1 静默丢失，exit 0）
//   encode  {"R.A":"B"} ->  C2 C2       （同一个值写进两个偏移）
//   verify  ->  byte mismatch at offset 0, exit 1
// 同名兄弟组（`05 G. 10 X.` 出现两次）同样触发 `R.G.X` 重复。
//
// 契约选择：按项目第一原则「绝不静默修正」，重复 path 是**编译错误**，
// 而不是运行期去重或加后缀 —— 前者让问题在 layout 阶段就暴露，后者会把
// 一份自相矛盾的 copybook 变成"看起来能用"的数据。
//
// 注意：**不同组下的同名字段必须继续工作**（`G1.A` / `G2.A` 路径不同），
// 这是 COBOL 的常态用法，不能被这条检查误杀。

///|
fn layout_cb20(src : String) -> RecordLayout raise ParseError {
  compile_layout(parse_copybook(src))
}

///|
/// 期望编译失败：返回错误正文；若意外成功则返回空串（调用方据此 fail）。
fn layout_cb20_err(src : String) -> String {
  try layout_cb20(src) catch {
    e => e.to_display()
  } noraise {
    _ => ""
  }
}

///|
test "duplicate 01 record names with a same-named leaf are rejected (CB-20)" {
  let msg = layout_cb20_err(
    "01 R.\n  05 A PIC X(1).\n01 R.\n  05 A PIC X(1).\n",
  )
  assert_true(msg.contains("duplicate"))
  assert_true(msg.contains("R.A"))
}

///|
test "sibling groups with the same name are rejected (CB-20)" {
  let msg = layout_cb20_err(
    "01 R.\n  05 G.\n    10 X PIC X(1).\n  05 G.\n    10 X PIC X(1).\n",
  )
  assert_true(msg.contains("duplicate"))
  assert_true(msg.contains("R.G.X"))
}

///|
test "same-named leaf inside one group is rejected (CB-20)" {
  let msg = layout_cb20_err("01 R.\n  05 A PIC X(1).\n  05 A PIC X(1).\n")
  assert_true(msg.contains("duplicate"))
}

///|
test "differently-named groups may hold same-named leaves (CB-20 must not over-reject)" {
  // COBOL 常态：不同组下同名（G1.A / G2.A 路径不同）—— 必须继续工作
  let l = layout_cb20(
    "01 R.\n  05 G1.\n    10 A PIC X(1).\n  05 G2.\n    10 A PIC X(1).\n",
  )
  inspect(l.byte_length, content="2")
  inspect(l.fields.length(), content="2")
  // 路径必须可区分，且解码结果里两个字段各自独立
  let row = decode_record(l, bs([0xC1, 0xC2])).unwrap()
  match row.get("R.G1.A") {
    Some(Text(s)) => inspect(s, content="A")
    _ => fail("R.G1.A must decode")
  }
  match row.get("R.G2.A") {
    Some(Text(s)) => inspect(s, content="B")
    _ => fail("R.G2.A must decode")
  }
  // 往返逐字节一致
  let text = render_jsonl(l, [row])
  assert_eq(
    encode_record(l, parse_jsonl_row(l, text).unwrap()).unwrap(),
    bs([0xC1, 0xC2]),
  )
}

///|
test "OCCURS-expanded keys do not collide with each other (CB-20 must not over-reject)" {
  // 展开后的 `R.A(1)` / `R.A(2)` 是不同的 path，不能误判成重复
  let l = layout_cb20("01 R.\n  05 A PIC X(1) OCCURS 3 TIMES.\n")
  inspect(l.byte_length, content="3")
  inspect(l.fields.length(), content="3")
  let row = decode_record(l, bs([0xC1, 0xC2, 0xC3])).unwrap()
  match row.get("R.A(2)") {
    Some(Text(s)) => inspect(s, content="B")
    _ => fail("R.A(2) must decode")
  }
}

///|
test "nested OCCURS keys and REDEFINES views do not trigger the check (CB-20 guard)" {
  // 嵌套展开：path 各不相同
  let l = layout_cb20(
    "01 R.\n  05 G OCCURS 2 TIMES.\n    10 H OCCURS 2 TIMES.\n      15 X PIC X(1).\n",
  )
  inspect(l.byte_length, content="4")
  inspect(l.fields.length(), content="4")
  // REDEFINES 的视图 path（V）与目标 path（M）不同，不构成重复
  let l2 = layout_cb20(
    "01 R.\n  05 M PIC X(2).\n  05 V REDEFINES M PIC X(2).\n",
  )
  inspect(l2.byte_length, content="2")
  inspect(l2.fields.length(), content="2")
}
