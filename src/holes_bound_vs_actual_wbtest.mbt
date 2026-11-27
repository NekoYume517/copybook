// CB-22-4（2026-11-27 第二十二轮审计）：**把 `HOLES:` 静态上界与编码器按行动态洞的
// 关系写成一句话，并锁成测试**（HANDOVER 31.8 / 32.6 遗留）。
//
// ## 遗留的形态
//
// `HOLES:` 行是 `layout_static_gaps`（`values = None`）的结果 —— 「**全视图都不写**
// 时」的空洞，是一个**上界**。而编码器 `gap_carrier_report` 看的是这一行实际写了
// 什么，决定「还剩几个字节没归属」。两者**不必相等**，也不该相等：
//
// ```copybook
// 01 R.
//   05 M PIC X(4).
//   05 V2 REDEFINES M PIC X(6).
//   05 V3 REDEFINES M PIC X(8).      <- 记录 8 字节
// ```
//
// 实测（native 二进制）：
//
// ```
// layout  : HOLES: 1 segment(s), 4 byte(s)
// decode  : {"R.M":"ABCD","R.V2":"ABCDEF","R.V3":null,
//            "__tail_hex":"ffee","__tail_gap":[[6,8]]}      <- 这一行只露 2 字节
// ```
//
// `V2` 这一行解出来了，写到 6，于是尾部洞只剩 `[6,8)`。`HOLES` 说的 4 字节是
// 「三个视图**全部**解不出时」的宽度 —— 上界，不是这一行的实际缺口。
//
// 文档此前只有「超集」一词散落在 `FIDELITY.md:146` / `API.md:398`，没有一句话把
// 两者对上。本轮补进 `API.md` 并锁成测试。
//
// ## 判据（双向）
//
// 1. 静态上界 >= 这一行的动态洞总长（上界定义）；
// 2. 存在一份布局让两者**严格不等**（否则「上界」没有意义，相等能靠两边都为零骗过去）；
// 3. 第三重：编码器真正用的 `gap_carrier_report` 必须与同行的动态洞对得上 ——
//    否则「上界 vs 实际」的说法没有落点。

///|
/// 区间总长（测试本地实现，不依赖被测函数）。
fn hba_total(gaps : Array[(Int32, Int32)]) -> Int32 {
  let mut n = 0
  for (s, e) in gaps {
    n = n + (e - s)
  }
  n
}

///|
fn hba_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 M PIC X(4).\n  05 V2 REDEFINES M PIC X(6).\n  05 V3 REDEFINES M PIC X(8).\n",
    ),
  )
}

///|
test "HOLES is an upper bound: static gaps >= this row's actual gaps" {
  let layout = hba_layout()
  let static_total = hba_total(layout_static_gaps(layout))
  assert_eq(static_total, 4)
  let text =
    #|{"R.M":"ABCD","R.V2":"ABCDEF","R.V3":null,"__tail_hex":"ffee","__tail_gap":[[6,8]]}
  let row = parse_jsonl_row(layout, text).unwrap()
  let actual = hba_total(primary_tail_gaps(layout, Some(row)))
  assert_eq(actual, 2)
  // 反向判据：严格不等，这条才有判别力。
  assert_true(static_total > actual)
}

///|
test "when every view is null the static bound is attained exactly" {
  // 上界可达成：三个视图都 null 时，实际洞 == 静态上界 4。
  let layout = hba_layout()
  let text =
    #|{"R.M":null,"R.V2":null,"R.V3":null,"__tail_hex":"ffee4040","__tail_gap":[[4,8]]}
  let row = parse_jsonl_row(layout, text).unwrap()
  let actual = hba_total(primary_tail_gaps(layout, Some(row)))
  assert_eq(actual, hba_total(layout_static_gaps(layout)))
}

///|
test "the gap_carrier_report of a row agrees with its dynamic gap set" {
  // 第三重：编码器的权威口径必须跟上一条对得上。
  let layout = hba_layout()
  let text =
    #|{"R.M":"ABCD","R.V2":"ABCDEF","R.V3":null,"__tail_hex":"ffee","__tail_gap":[[6,8]]}
  let row = parse_jsonl_row(layout, text).unwrap()
  let report = gap_carrier_report(layout, row)
  assert_eq(hba_total(report.gaps), 2)
  assert_eq(report.missing, 0)
}
