// CB-21-3（2026-11-29 第二十一轮审计）：**空洞在四个子命令上全程不出声**。
//
// ## 缺陷形态（修复前实测，`audit/2026-11-29/visibility.txt`）
//
// 「空洞」指记录里**没有任何字段承载、只能靠旁路键保真**的字节，两类：
//
//   · **FILLER 中部空洞**：`05 A X(1). 05 FILLER X(2). 05 B X(1).` 的 `[1,3)`
//   · **REDEFINES 尾部空洞**：`05 M COMP-3(4). 05 A REDEFINES M. 10 RAW X(4).`
//     的 `[3,4)`（视图比主视图长、且解不出）
//
// 修复前四个子命令的实际输出（逐条实跑）：
//
//     layout  → FILLER 区不进报告（设计如此），0 行任何诊断
//     decode  → {"R.A":"A","R.B":"B","__filler_hex":"f1f2","__filler_gap":[[1,3]]}
//               旁路键是唯一线索，没有文字说明「离开这条 JSONL 就丢」
//     encode  → 0 行诊断
//     verify  → verify: 1 record(s) OK, byte-identical roundtrip
//
// `byte-identical` 是真的（宽容解码的 `__record_bytes` 把它回填了）——
// **恰恰因此看不出风险**：这份字节只在本工具的 `decode → JSONL → encode`
// 侧道里活着。手写 JSONL、外部工具过滤 `__` 键、把值喂给下游系统之后，
// 这几个字节落回 `0x40`（合法空格，损坏的记录看着仍然正常）。
//
// 与本项目反复出现的「结论没说清覆盖范围」同族（CB-19-4 / CB-20-1）。
//
// ## 判据
//
// 1. `layout_hole_warning(gaps)` 是**唯一**文案实现：点名区间与字节数，并说清
//    「离开旁路键就变 0x40」。`gaps` 为空时返回空串。
// 2. `decode` / `encode` / `verify` 三处都读 `gap_carrier_report`（CB-21-1 的
//    唯一权威），不新起一套判据。
// 3. `layout` 的报告追加机读字段 `HOLES: N segment(s), M byte(s)`；无空洞时
//    不追加（不误伤）。
//
// 本文件是黑盒测试：只断言公开 API 与报告文本。

///|
/// 布局 4 字节：A X(1) | FILLER X(2) | B X(1)。中部洞 `[1,3)`。
fn cb213_filler_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n    05 A PIC X(1).\n    05 FILLER PIC X(2).\n    05 B PIC X(1).\n",
    ),
  )
}

///|
test "CB-21-3: 空洞告警文案点名区间与字节数，并说清 0x40 的风险" {
  let gaps : Array[(Int32, Int32)] = [(1, 3)]
  let msg = layout_hole_warning(gaps)
  assert_true(msg.contains("[1,3)"))
  assert_true(msg.contains("2 byte(s)"))
  assert_true(msg.contains("0x40"))
  // 必须点明「只能靠旁路键活着」——这是判据的实质
  assert_true(msg.contains("__tail_hex"))
  // 没有空洞时不出声
  inspect(layout_hole_warning([]), content="")
}

///|
test "CB-21-3: 尾部空洞走同一条告警（不只是 FILLER）" {
  let gaps : Array[(Int32, Int32)] = [(3, 4)]
  let msg = layout_hole_warning(gaps)
  assert_true(msg.contains("[3,4)"))
  assert_true(msg.contains("1 byte(s)"))
}

///|
test "CB-21-3: layout 报告带机读字段 HOLES；无空洞的布局不追加" {
  let reported = render_layout(cb213_filler_layout())
  assert_true(reported.contains("HOLES: 1 segment(s), 2 byte(s)"))
  let clean = compile_layout(parse_copybook("01 R.\n    05 A PIC X(4).\n"))
  assert_false(render_layout(clean).contains("HOLES:"))
}
