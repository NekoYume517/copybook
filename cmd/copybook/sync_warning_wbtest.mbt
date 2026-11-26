// CB-20-1（2026-11-28 第二十轮审计）：**SYNC 声明在所有子命令里都不出声**。
//
// ## 缺陷形态（修复前实测）
//
// `SYNC` / `SYNCHRONIZED` 是一个「本子集不实现、但会改变真实布局」的子句：
// IBM 上带 SYNC 的 COMP 字段必须落在半字/全字边界，它前面的字段可能被填充、
// 记录变长。`render_layout` 因此逐行标注 `[SYNC: ...]` 并在末尾打一条
// WARNING（NEW-4，2026-11-04）——**但只有 `copybook layout` 会调
// `render_layout`**：
//
//     $ copybook layout --copybook s.cpy          # 有 [SYNC:] 标注 + WARNING
//     $ copybook verify --copybook s.cpy --data s.dat
//     verify: 1 record(s) OK, byte-identical roundtrip      <- exit 0，零提示
//     $ copybook decode --copybook s.cpy --data s.dat --format jsonl
//     {"R.A":"A","R.B":1,"R.C":"B"}                          <- exit 0，零提示
//
// 危害正是 NEW-4 当初要拦的那一条：这份布局拿去读**主机数据**时每个 COMP
// 数值都是错位解出的错误值，而 verify 抓不到（布局自洽，往返当然一致）。
// 用户在 verify / decode 上拿到的却是无条件的「byte-identical roundtrip」，
// 与 CB-19-4 的 partial roundtrip 是同一类缺陷：**载荷本身没错，错的是那句
// 结论没有说明自己不覆盖什么**。
//
// ## 判据
//
// 1. 只要布局里有 SYNC 声明，`decode` / `encode` / `verify` 都必须说出同一句
//    话（`layout` 的 stdout 报告里已有逐行标注 + 汇总警告，不重复打印）。
// 2. `exit 0` 不被警告改变 —— 这是**警告**不是拒绝（契约没变）。
// 3. 文案只有一个实现（`@lib.layout_sync_warning`），CLI 与 `render_layout`
//    同源，免得「文案在 A、判定在 B」再分裂一次。

///|
fn cb201_write_pair(
  cpy_bytes : Bytes,
  cpy : String,
  dat : String,
  dat_bytes : Bytes,
) -> Unit {
  @fs.write_bytes_to_file(cpy, cpy_bytes) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dat, dat_bytes) catch {
    _ => ()
  }
}

///|
fn cb201_opts(cpy : String, dat : String) -> Options {
  {
    copybook: Some(cpy),
    data: Some(dat),
    json: None,
    out: None,
    format: "jsonl",
    record_length: None,
    float_mode: @lib.Hfp,
    given: [],
  }
}

///|
fn cb201_cleanup(cpy : String, dat : String) -> Unit {
  @fs.remove_file(cpy) catch {
    _ => ()
  }
  @fs.remove_file(dat) catch {
    _ => ()
  }
}

///|
test "CB-20-1: SYNC 警告必须真的走到 stderr（不只文案正确）" {
  // 反向验证要能变红：光断言 `layout_sync_warning` 的文案，删掉调用点也照样
  // 全绿（第二十轮实测：回退三个调用点后 776/776 仍然通过）。所以这条判据
  // 直接检查调用点确实存在，且三个子命令都调了。
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  let mut hits = 0
  for line in src.split("\n") {
    if line.contains("warn_sync_layout(cpy_text)") {
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
test "CB-20-1: 源文本里的 SYNC 声明计数（含组项、大小写、注释不算）" {
  // 叶子上的 SYNC / SYNCHRONIZED，大小写不敏感
  inspect(
    count_sync_leaves(
      "01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n",
    ),
    content="1",
  )
  inspect(
    count_sync_leaves(
      "01 R.\n    05 B PIC 9(4) COMP Synchronized.\n    05 C PIC X(1).\n",
    ),
    content="1",
  )
  // 组项上的 SYNC 同样改变布局（parser 会下发给孩子）——必须数进去
  inspect(
    count_sync_leaves("01 R.\n    05 M SYNC.\n       10 B PIC X(1).\n"),
    content="1",
  )
  // 注释行不算、字面量不是 SYNC 的词不算
  inspect(
    count_sync_leaves(
      "01 R.\n*    05 B PIC 9(4) COMP SYNC.\n    05 C PIC X(1).\n",
    ),
    content="0",
  )
  inspect(count_sync_leaves("01 R.\n    05 C PIC X(1).\n"), content="0")
}

///|
test "CB-20-1: 无 SYNC 的布局在 verify 上保持原样（不误伤）" {
  let cpy = "_cb201_plain.cpy"
  let dat = "_cb201_plain.dat"
  cb201_write_pair(b"01 R.\n    05 A PIC X(2).\n", cpy, dat, b"\xC1\xC2")
  inspect(cmd_verify(cb201_opts(cpy, dat)), content="0")
  // 源文本判定也必须为 0：这条 copybook 一个字都不提 SYNC
  inspect(count_sync_leaves("01 R.\n    05 A PIC X(2).\n"), content="0")
  cb201_cleanup(cpy, dat)
}

///|
test "CB-20-1: 带 SYNC 的布局 verify 仍 exit 0（警告不是拒绝）" {
  let cpy = "_cb201_sync.cpy"
  let dat = "_cb201_sync.dat"
  // 布局 4 字节（本子集不做对齐）、数据 4 字节、往返自洽 —— 修复前 exit 0
  // 且一个字都不提 SYNC；修复后 exit 0 不变，只是必须出声。
  cb201_write_pair(
    b"01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n    05 C PIC X(1).\n",
    cpy, dat, b"\xC1\x00\x01\xC2",
  )
  inspect(cmd_verify(cb201_opts(cpy, dat)), content="0")
  // 声明的确被数到 1（否则上一条 exit 0 就说明不了「出声了」）
  inspect(
    count_sync_leaves(
      "01 R.\n    05 A PIC X(1).\n    05 B PIC 9(4) COMP SYNC.\n    05 C PIC X(1).\n",
    ),
    content="1",
  )
  cb201_cleanup(cpy, dat)
}
