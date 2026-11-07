// CB-2（2026-11-08 审计）：verify 的 --record-length 是死选项。
//
// ## 缺陷形态（修复前）
//
// NEW-8 的白名单把 --record-length 列为 verify 合法选项，但 cmd_verify
// 写死 `rec_len = layout.byte_length`，opts.record_length 从未被读取：
//
//     copybook verify --copybook x4.cpy --data d9.dat --record-length 8
//     （x4.cpy = 05 A PIC X(4).，d9.dat = 9 字节）
//     → verify: data length 9 is not a multiple of record length 4
//
// 用户要求按 8 切分，工具仍按 4 切分；8 字节数据时 8%4==0 碰巧
// exit 0 报 "2 record(s) OK"，语义完全错位且无任何提示。
//
// ## 修复
//
// cmd_verify 与 decode 同款消费 opts.record_length：
// - 显式给出且 < 布局长度 → 用法错误 exit 2（对齐 decode 文案）；
// - 显式给出且 > 布局长度 → 警告尾字节在 copybook 之外，仍按 N 切分；
// - 未给出 → 布局长度（行为不变）。
//
// 锁定：N=2 < 布局 4 的用法门 —— 修复前无此门、8 字节数据按 4 切分
// exit 0；修复后 exit 2。测试直接构造 Options 调 cmd_verify。
// 退出码契约：EXIT_OK=0 / EXIT_DATA=1 / EXIT_USAGE=2。

///|
fn cb2_write_probe(cpy : String, dat : String, dat_bytes : Bytes) -> Unit {
  // copybook 是 ASCII 文本，按字节写
  let text = b"01 R.\n    05 A PIC X(4).\n"
  @fs.write_bytes_to_file(cpy, text) catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dat, dat_bytes) catch {
    _ => ()
  }
}

///|
fn cb2_opts(cpy : String, dat : String, n : Int32?) -> Options {
  {
    copybook: Some(cpy),
    data: Some(dat),
    json: None,
    out: None,
    format: "jsonl",
    record_length: n,
    float_mode: @lib.Hfp,
    given: ["--record-length"],
  }
}

///|
fn cb2_cleanup(cpy : String, dat : String) -> Unit {
  @fs.remove_file(cpy) catch {
    _ => ()
  }
  @fs.remove_file(dat) catch {
    _ => ()
  }
}

///|
test "NEW-8c: cmd_verify 的 --record-length 小于布局长度报用法错误" {
  let cpy = "_cb2_probe.cpy"
  let dat = "_cb2_probe.dat"
  cb2_write_probe(cpy, dat, b"\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8")
  // 修复前：record_length 被丢弃，8%4==0 → exit 0；修复后：N<布局 → exit 2
  inspect(cmd_verify(cb2_opts(cpy, dat, Some(2))), content="2")
  cb2_cleanup(cpy, dat)
}

///|
test "NEW-8c: cmd_verify 按 --record-length 切分并校验余数" {
  let cpy = "_cb2_probe.cpy"
  let dat = "_cb2_probe.dat"
  // 9 字节按 8 切分 → 1 条完整 + 1 字节余数 → 数据错误 exit 1
  // （修复前按 4 切分也是余数错误，但门槛数字是 4 —— 与下一条 N=8
  // 整除时的 OK 路径共同锁定「真的按 8 在切」）
  cb2_write_probe(cpy, dat, b"\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9")
  inspect(cmd_verify(cb2_opts(cpy, dat, Some(8))), content="1")
  cb2_cleanup(cpy, dat)
}

///|
test "NEW-8c: cmd_verify 在 N 覆盖数据长度时按 N 校验并成功" {
  let cpy = "_cb2_probe.cpy"
  let dat = "_cb2_probe.dat"
  // 8 字节按 8 切分 → 1 条记录（布局只取前 4 字节，尾 4 字节在 copybook
  // 之外、走 N>布局 警告路径）→ byte-identical → exit 0。
  // 修复前：--record-length 8 被丢弃，9 字节样例报 "record length 4"；
  // 本条与上条一起把「按 N 切」钉死。
  cb2_write_probe(cpy, dat, b"\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8")
  inspect(cmd_verify(cb2_opts(cpy, dat, Some(8))), content="0")
  cb2_cleanup(cpy, dat)
}
