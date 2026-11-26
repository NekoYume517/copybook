// CB-21-1（2026-11-29 第二十一轮审计）：**`__record_bytes` 的三处判据不同源**。
//
// ## 缺陷形态（修复前实测，每条都在提交日志里）
//
// `__record_bytes`（内存路径：decode 挂在结果 map 上的整条原始记录）在这条
// 路径上有**三个互不相干**的判断：
//
//   A. **空隙计数**（`unaddressed_gap_bytes` + `has_any_carrier`）：
//      只看「行里有没有这个键」，把它当成「空洞有载体」，从不看它够不够长；
//   B. **长度守卫**：`if bs.length() < layout.byte_length { 报错 }` —— 判的是
//      「比**布局**短」，不是「比**还需要回填的空洞**短」；
//   C. **回填**（`restore` 闭包）：`if src < bs.length() { w.set(...) }` ——
//      超出快照长度的位置**静默不写**，落回 Writer 初值 0x40。
//
// 三条各自为政，于是出现两个方向都错的状态：
//
//   · **无关的空洞被当成覆盖**：行里其余字段全部有值、空洞只剩 FILLER 的
//     `[2,4)`，快照给 4 字节（缺口 2）→ B 报错，尽管那 4 字节已经覆盖了
//     **全部仍需回填的字节**。用户没有合法写法表达「我只要 FILLER 那两字节」。
//   · **真正的缺口被当成覆盖**：只要早有一个载体键、B 又被 A 判定为「不需要
//     检查」，C 的越界保护就把剩下的位置静默写成 0x40 —— exit 0。
//
// 同一个问题（"这段空洞有没有字节来源"）被问了三次，三次用了不同的信息源。
// 这是 CB-16「空洞判定说写、编码器说不写」的同族土壤：判据不同源时，
// **哪个先跑**就决定了行为，而不是**哪个对**。
//
// ## 收敛设计
//
// 新增唯一权威：`gap_carrier_report`。它对**每个**空洞字节回答「谁负责」，
// 三处判断全部从它派生：
//
// ```
// pub(all) enum GapByteOwner {
//   Value      // 某个字段的值会写这一字节（编辑优先，不需要旁路）
//   Snapshot   // 只有旁路键能给：__record_bytes（内存）或 __*_hex（JSONL）
//   Missing    // 谁也给不了 → 必须报错
// }
// ```
//
// `gap_carrier_report(layout, values) -> GapCarrierReport` 一次算完：
//
//   · `gaps`      —— 仍然存在（没有任何字段值写）的空洞区间
//   · `open_gaps` —— 其中**没有字节载体覆盖**的区间（= Missing）
//   · `carried`   —— 有载体覆盖的区间
//   · `missing`   —— `open_gaps` 的字节数
//
// 然后：
//   A. 空隙计数 → 直接读 `report.missing`（不再看「键在不在」）；
//   B. 长度守卫 → 改成「载体必须覆盖 `report.carried`」（不再比布局长度）；
//   C. 回填 → 只回填 `report.carried`（越界不再可能发生，`restore` 的
//      `if src < bs.length()` 变成纯防御）。
//
// ## 判据
//
// 1. 三处对**同一个区间**必须给出同一个归属：测试直接用 `gap_carrier_report`
//    的结果与「回填后哪些位置仍是 0x40」交叉验证。
// 2. 空洞已被字段值覆盖时，快照短/长都无关（`Value` 优先）。
// 3. 空洞没有任何值覆盖、载体又没覆盖到 → `InvalidBypass`，exit 1。
// 4. 空洞没有任何值覆盖、载体覆盖到了 → 逐字节回填。
// 5. 无人覆盖又无载体 → `InvalidBypass`（CB-20-3 的既有判据，不能退）。

///|
/// 布局 6 字节：A X(2) | FILLER X(2) | B X(2)。FILLER 区 `[2,4)` 恒为空洞。
fn cb211_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n    05 A PIC X(2).\n    05 FILLER PIC X(2).\n    05 B PIC X(2).\n",
    ),
  )
}

///|
fn cb211_bytes(vals : Array[Int32]) -> Bytes {
  Bytes::from_array(vals.map(fn(v) { v.to_byte() }))
}

///|
test "CB-21-1: 归属判定三处同源 —— 报告说 Value 的字节，回填后确实不是 0x40" {
  let layout = cb211_layout()
  let row : Map[String, CellValue] = Map([
    ("R.A", Text("AB")),
    ("R.B", Text("EF")),
    ("__record_bytes", Bytes(cb211_bytes([0xC1, 0xC2, 0xF1, 0xF2, 0xC5, 0xC6]))),
  ])
  let report = gap_carrier_report(layout, row)
  // FILLER [2,4) 没有被字段值覆盖 → 必须由快照负责
  inspect(report.missing, content="0")
  inspect(report.gaps.length(), content="1")
  inspect(report.gaps[0].0, content="2")
  inspect(report.gaps[0].1, content="4")
  let b = encode_record(layout, row).unwrap()
  // 报告的区间 == 实际被回填的区间
  inspect(b[2].to_int(), content="241")
  inspect(b[3].to_int(), content="242")
}

///|
test "CB-21-1: 快照恰好覆盖仍需回填的字节时合法（不再比布局长度）" {
  let layout = cb211_layout()
  // 行里没有 B 的值 → 尾部 [4,6) 也是空洞，快照必须覆盖 [2,6) 四字节
  let enough : Map[String, CellValue] = Map([
    ("R.A", Text("AB")),
    ("__record_bytes", Bytes(cb211_bytes([0xC1, 0xC2, 0xF1, 0xF2]))),
  ])
  match encode_record(layout, enough) {
    Ok(_) => ()
    Err(e) =>
      fail("4 字节恰好覆盖 [2,6)，不该报错: \{e.to_display()}")
  }
  // 少一字节 → 仍有 1 字节无来源 → 必须报错
  let short : Map[String, CellValue] = Map([
    ("R.A", Text("AB")),
    ("__record_bytes", Bytes(cb211_bytes([0xC1, 0xC2, 0xF1]))),
  ])
  match encode_record(layout, short) {
    Ok(bytes) =>
      fail(
        "缺口 1 字节不得静默写 0x40：第 5 字节 = \{bytes[5].to_int()}（应为报错）",
      )
    Err(InvalidBypass(detail)) => assert_true(detail.contains("__record_bytes"))
    Err(e) => fail("应当是 InvalidBypass，实际 \{e.to_display()}")
  }
}

///|
test "CB-21-1: 空洞被字段值覆盖时，快照长度无关（Value 优先）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n    05 M PIC X(2).\n    05 V REDEFINES M PIC X(2).\n    05 W REDEFINES M PIC X(4).\n",
    ),
  )
  // W 有值覆盖 [0,4) → 空洞集为空 → 快照长度不参与任何判断
  let row : Map[String, CellValue] = Map([
    ("R.M", Text("AB")),
    ("R.W", Text("WXYZ")),
    ("__record_bytes", Bytes(cb211_bytes([0xC1]))),
  ])
  let report = gap_carrier_report(layout, row)
  inspect(report.gaps.length(), content="0")
  inspect(report.missing, content="0")
  match encode_record(layout, row) {
    Ok(_) => ()
    Err(e) =>
      fail(
        "空洞已被 W 覆盖，不该因快照短而报错: \{e.to_display()}",
      )
  }
}

///|
test "CB-21-1: 无症状 —— 既无值也无载体时仍报 no carrier（CB-20-3 不退）" {
  let layout = cb211_layout()
  let bare : Map[String, CellValue] = Map([("R.A", Text("AB"))])
  let report = gap_carrier_report(layout, bare)
  // 只有 FILLER 的 [2,4) 恒为空洞；尾部 [4,6) 被 R.B 的默认值写满
  // （`written_intervals` 主视图恒写），所以缺口是 2 字节而不是 4。
  inspect(report.missing, content="2")
  inspect(report.open_gaps.length(), content="1")
  inspect(report.open_gaps[0].0, content="2")
  match encode_record(layout, bare) {
    Ok(_) => fail("无值无载体时必须报错")
    Err(InvalidBypass(detail)) => assert_true(detail.contains("no carrier"))
    Err(e) => fail("应当是 InvalidBypass，实际 \{e.to_display()}")
  }
}
