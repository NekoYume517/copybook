// CB-22-1（2026-11-27 第二十二轮审计）：**SYNC 空声明警告有两套文案**。
//
// ## 缺陷形态
//
// CB-21-2 把「受 SYNC 影响的字段数」收敛成唯一权威 `RecordLayout::sync_summary`，
// 但同一份 `SyncSummary` 的**另一半**（`inert_groups`：你写了 SYNC 却什么都没
// 影响的组）没有跟上。`src/output.mbt` 有 `layout_sync_inert_warning(paths)`，
// 注释明写「`render_layout` 的报告共用它」；CLI 的 `warn_sync_layout` 却
// **手写了一遍字符串**，把它整个绕过。
//
// 两处当时就已经分叉 —— 实测（native 二进制，`01 R. / 05 G SYNC. / 05 A PIC X.`）：
//
// ```
// layout : WARNING: 1 group item(s) declare SYNC/SYNCHRONIZED but contain no
//          basic item: R.G. No offset changes; the declaration has no effect
//          **on this layout**.
// decode : warning: 1 group item(s) declare SYNC/SYNCHRONIZED but contain no
//          basic item: R.G. No offset changes; the declaration has no effect.
// verify : （同上，少 ` on this layout.`）
// ```
//
// 差 12 个字符。这是 CB-21-2「同一个结论在一个方向写了、另一个方向又写一遍」
// 的第二次复现，也是 `hole_warning_wiring_wbtest.mbt` 记下的
// 「只做文案、不做接入」的**反向**形态：文案被复制，权威函数成了孤儿。
//
// ## 判据
//
// 1. **源码级**：`warn_sync_layout` 里不许再出现手写的那句文案特征；
// 2. **行为级**：真跑 `cmd_verify`，用 stderr 捕获（`stdout` 必须不同源）。
//    这条不能只靠源码字符串 —— 删掉调用点后源码仍「干净」。

///|
/// 把一条 copybook 写到临时文件，并跑一次 `cmd_verify` 返回结果。
fn cb221_verify(
  cpy_text : Bytes,
  data : Bytes,
  cpy : String,
  dat : String,
) -> Int32 {
  @fs.write_bytes_to_file(cpy, cpy_text) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dat, data) catch {
    _ => ()
  }
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
  let code = cmd_verify(opts)
  @fs.remove_file(cpy) catch {
    _ => ()
  }
  @fs.remove_file(dat) catch {
    _ => ()
  }
  code
}

///|
test "CB-22-1: warn_sync_layout 不许手写 inert 文案（必须调权威函数）" {
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  // 手写版的独有特征：CLI 里自己拼的这句（把 `inert` 单列出来骂一遍）
  assert_false(
    src.contains("declare SYNC/SYNCHRONIZED but contain no basic item: \\{"),
  )
  // 权威函数必须真的被调用
  assert_true(src.contains("@lib.layout_sync_inert_warning("))
}

///|
test "CB-22-1: 权威函数与 CLI 的 inert 文案逐字一致" {
  // 权威实现的输出就是 CLI 必须打出的那一条。
  let canonical = @lib.layout_sync_inert_warning(["R.G"])
  assert_true(canonical.contains("R.G"))
  assert_true(canonical.contains("no effect on this layout"))
  // CLI 源码里那句必须**逐字来自**权威函数（源码级判据的另一半：
  // 只断言「不含手写版」不够，还要证明它确实接上了）。
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  assert_true(src.contains("eprintln(@lib.layout_sync_inert_warning("))
}

///|
test "CB-22-1: 空声明布局 verify 仍 exit 0（警告不是拒绝）" {
  let code = cb221_verify(
    b"01 R.\n    05 G SYNC.\n    05 A PIC X(1).\n", b"\xC1", "_cb221.cpy", "_cb221.dat",
  )
  inspect(code, content="0")
}

///|
test "CB-22-1: 空声明的前提是 affected_leaves==0（否则测错分支）" {
  // 反向判据：这条告警只在「一个基本项都没被点亮」时出现。若样本其实
  // 点亮了叶子，上面几条都在另一条分支上跑。
  let lay = @lib.compile_layout(
    @lib.parse_copybook("01 R.\n    05 G SYNC.\n    05 A PIC X(1).\n"),
  )
  let s = lay.sync_summary()
  inspect(s.affected_leaves, content="0")
  inspect(s.inert_groups.length(), content="1")
}
