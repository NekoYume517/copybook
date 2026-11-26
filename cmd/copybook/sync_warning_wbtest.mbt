// CB-20-1（2026-11-28 第二十轮）→ CB-21-2（2026-11-29 第二十一轮）：
// SYNC 警告先是「只在 layout 上出声」，收敛口径后又在「数什么」上分叉。
//
// ## CB-20-1 的形态（已修，`3a71f75`）
//
// 一份声明了 SYNC 的 copybook：`layout` 逐行标 `[SYNC:]` + 汇总 WARNING，
// 但 `verify` 报 `byte-identical roundtrip`（exit 0）**一个字都不提**，
// `decode` / `encode` 同样零提示。根因：文案只长在 `render_layout` 里，
// 只有 `cmd_layout` 调它。修法是把文案提成 `@lib.layout_sync_warning`，
// 并让其余三个子命令也出声。
//
// ## CB-21-2 的形态（本轮修，`audit/2026-11-29/sync-counts.txt`）
//
// CB-20-1 为了让非 layout 子命令出声，在 CLI 里**重新扫了一遍 copybook 源
// 文本**数 `SYNC` 关键字；而 `render_layout` 数的是 `is_synced` 的**叶子**。
// 同一份 copybook 于是能报出两个数字：
//
// | copybook                            | layout | verify |
// |---|---|---|
// | `05 M SYNC.` + 2 个孩子              | 2 | 1 |
// | `05 M1 SYNC.` + `05 M2 SYNC.`        | 3 | 2 |
// | `05 G1 SYNC.` + 三层嵌套 2 叶子      | 2 | 1 |
// | 组级 `SYNC`，组内**没有**基本项       | **不报** | 1 |
//
// 最后一档最强：源文本里确实有 `SYNC`（CLI 报 1），布局里却没有任何字段受
// 影响（`render_layout` 一行都不标）—— 两边都不算错，错在没有共同的定义。
//
// ## 收敛
//
// 权威口径收到 `RecordLayout::sync_summary()`：
//   · `affected_leaves` —— 受 SYNC 影响的基本项数（真正被改动偏移的那些）
//   · `inert_groups`    —— 声明在组上、却没点亮任何基本项的路径
//
// `render_layout` 与 CLI 的 `warn_sync_layout` 都只读它；文案各一条：
// `layout_sync_warning`（N 个字段受影响，别拿去读主机数据）与
// `layout_sync_inert_warning`（你写了 SYNC，但它什么也没影响）。

///|
/// 写 copybook 与数据。**必须按 ASCII 字节字面量写**：`@lib.ebcdic_encode`
/// 把 `.` / 空格 / 数字都映射成 cp037（`.` 是 0x4B、`0` 是 0xF0），落盘的
/// 不是可读的 copybook —— 上一版用它，`verify` 于是报 parse error 而不是
/// 「有 SYNC 警告 + exit 0」。
fn cb212_write(cpy : String, dat : String, bytes : Bytes) -> Unit {
  @fs.write_bytes_to_file(
    cpy, b"01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n    05 C PIC X(1).\n",
  ) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dat, bytes) catch {
    _ => ()
  }
}

///|
fn cb212_cleanup(cpy : String, dat : String) -> Unit {
  @fs.remove_file(cpy) catch {
    _ => ()
  }
  @fs.remove_file(dat) catch {
    _ => ()
  }
}

///|
test "CB-20-1: SYNC 警告必须真的走到 stderr（不只文案正确）" {
  // 反向验证要能变红：光断言文案，删掉调用点也照样全绿（第二十轮实测：
  // 回退三个调用点后 776/776 仍然通过）。所以这条判据直接检查调用点存在，
  // 且三个子命令都调了。
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  let mut hits = 0
  for line in src.split("\n") {
    if line.contains("warn_sync_layout(layout)") {
      hits = hits + 1
    }
  }
  // decode / encode / verify 各一处
  inspect(hits, content="3")
}

///|
test "CB-20-1: SYNC 警告文案只有一个实现，count=0 时为空串（不误伤）" {
  inspect(@lib.layout_sync_warning(0), content="")
  let w = @lib.layout_sync_warning(3)
  assert_true(w.contains("3 field(s)"))
  assert_true(w.contains("SYNC/SYNCHRONIZED"))
  // 警告必须点明「别拿它读主机数据」——这是 NEW-4 的全部要点
  assert_true(w.contains("Do not use this layout to read host data"))
  // 不带结尾换行：`render_layout` 自己补、CLI 走 `eprintln`，各自负责
  assert_false(w.contains("\n"))
}

///|
test "CB-21-2: 权威口径 —— 组级 SYNC 数受影响的基本项，不是声明条数" {
  // `05 M SYNC.` + 2 个孩子：受影响 2、声明 1（修复前 layout 2 / verify 1）
  let lay = @lib.compile_layout(
    @lib.parse_copybook(
      "01 R.\n    05 M SYNC.\n       10 B PIC X(1).\n       10 C PIC X(1).\n",
    ),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="2")
  inspect(s.inert_groups.length(), content="0")
  // 报告与 summary 同源
  assert_true(@lib.render_layout(lay).contains("2 field(s) declare SYNC"))
}

///|
test "CB-21-2: 两处组级 SYNC 影响 3 个基本项（声明 2 条）" {
  let lay = @lib.compile_layout(
    @lib.parse_copybook(
      "01 R.\n    05 A PIC X(1).\n    05 M1 SYNC.\n       10 B PIC X(1).\n    05 M2 SYNC.\n       10 C PIC X(1).\n       10 D PIC X(1).\n",
    ),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="3")
  inspect(s.inert_groups.length(), content="0")
}

///|
test "CB-21-2: 空组上的 SYNC = 空声明，单列一条，不混进字段数" {
  // `05 M SYNC.` 后面没有任何子项：源文本里有 SYNC（修复前 CLI 报 1），
  // 布局里却没有任何字段受影响（修复前 render_layout 一行都不标）。
  let lay = @lib.compile_layout(
    @lib.parse_copybook("01 R.\n    05 A PIC X(1).\n    05 M SYNC.\n"),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="0")
  inspect(s.inert_groups.length(), content="1")
  inspect(s.inert_groups[0], content="R.M")
  let report = @lib.render_layout(lay)
  // 不能报「0 field(s)」，也不能沉默
  assert_false(report.contains("0 field(s)"))
  assert_true(report.contains("R.M"))
  assert_true(report.contains("has no effect"))
  assert_true(@lib.layout_sync_inert_warning(["R.M"]).contains("R.M"))
}

///|
test "CB-21-2: 叶子级 SYNC 不受影响（1 处声明 = 1 个受影响）" {
  let lay = @lib.compile_layout(
    @lib.parse_copybook(
      "01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n",
    ),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="1")
  inspect(s.inert_groups.length(), content="0")
}

///|
test "CB-21-2: CLI 不再扫源文本（两套口径的根源已删除）" {
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  assert_false(src.contains("fn count_sync_leaves"))
  assert_false(src.contains("fn declares_sync"))
  assert_false(src.contains("fn trim_ascii_space"))
}

///|
test "CB-20-1: 有 SYNC 的布局 verify 仍 exit 0（警告不是拒绝）" {
  let cpy = "_cb212_sync.cpy"
  let dat = "_cb212_sync.dat"
  // 布局 4 字节（本子集不做对齐）、数据 4 字节、往返自洽
  cb212_write(cpy, dat, b"\xC1\x00\x01\xC2")
  let opts : Options = {
    copybook: Some(cpy),
    data: Some(dat),
    json: None,
    out: None,
    format: "jsonl",
    record_length: None,
    float_mode: @lib.Hfp,
    given: [],
  }
  inspect(cmd_verify(opts), content="0")
  // 声明的确被算进去（否则上一条 exit 0 说明不了「出声了」）
  let lay = @lib.compile_layout(
    @lib.parse_copybook(
      "01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n    05 C PIC X(1).\n",
    ),
  )
  inspect(lay.sync_summary().affected_leaves, content="1")
  cb212_cleanup(cpy, dat)
}

///|
test "CB-20-1: 无 SYNC 的布局不产生警告（不误伤）" {
  let lay = @lib.compile_layout(
    @lib.parse_copybook("01 R.\n    05 A PIC X(2).\n"),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="0")
  inspect(s.inert_groups.length(), content="0")
  assert_false(@lib.render_layout(lay).contains("SYNC"))
}
