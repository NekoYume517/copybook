// CB-19-4（2026-11-27 审计）：verify 在 --record-length > 布局长度时
// 宣告 "byte-identical roundtrip"，但尾部字节根本不是往返的一部分。
//
// ## 缺陷形态（修复前）
//
// examples/customer.cpy 布局 54 字节，数据 5 × 108 字节（每条记录后面跟
// 54 字节 0xAA）。
//
//     $ copybook verify --copybook customer.cpy --data d.dat --record-length 108
//     warning: --record-length 108 exceeds the layout length 54; the trailing
//              54 byte(s) of each record are outside the copybook and are NOT
//              checked against any field
//     verify: 5 record(s) OK, byte-identical roundtrip        ← exit 0
//
// 但真正跑一遍往返是：
//
//     decode --record-length 108 → 5 行 JSONL（警告说尾部 NOT restored by encode）
//     encode                     → 270 字节（不是 540）
//     cmp                        → 540 → 270，尾部 54 字节全部丢失
//
// 而且 encode 写出的第 55..60 字节是 F0 F0 F0 F0 F1 F0（下一条记录的
// CUST-ID），偏移整体错位。也就是说：**verify 刚声明「尾字节没检查」，
// 紧接着宣称「往返逐字节一致」** —— 同一行输出里自相矛盾，而且结论是
// 假的。FIDELITY.md 承诺的 L1（`encode(decode(bytes)) == bytes`）在这条
// 路径上不成立，`verify` 却给了肯定答复。
//
// ## 根因
//
// `cmd_verify` 在 rec_len > 布局时把 check_len 夹到 layout.byte_length
// （636-645 行的注释解释了为什么必须夹：整记录重编码必然在布局长度处
// mismatch），这个夹取本身是对的；错的是 695 行**无条件**打印
// "byte-identical roundtrip"。结论句没有跟着夹取一起改口。
//
// ## 修法
//
// 分两种结论，退出码不变（NEW-8c 已锁定 N>布局 时为 0）：
//   - rec_len == layout.byte_length → 保持 "byte-identical roundtrip"
//   - rec_len >  layout.byte_length → 改为
//     "N record(s) OK, first <L> byte(s) of each record roundtrip byte-identical;
//      the trailing <N-L> byte(s) per record are NOT part of the roundtrip"
//
// 两个数字都写出来，调用方不会把「部分校验通过」误读成「整个文件无损」。

///|
fn cb4_write(cpy : String, dat : String, dat_bytes : Bytes) -> Unit {
  @fs.write_bytes_to_file(cpy, b"01 R.\n    05 A PIC X(4).\n") catch {
    _ => ()
  }
  @fs.write_bytes_to_file(dat, dat_bytes) catch {
    _ => ()
  }
}

///|
fn cb4_opts(cpy : String, dat : String, n : Int32?) -> Options {
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
fn cb4_drop(cpy : String, dat : String) -> Unit {
  @fs.remove_file(cpy) catch {
    _ => ()
  }
  @fs.remove_file(dat) catch {
    _ => ()
  }
}

///|
/// 缺陷本体：N > 布局时结论句不能是 "byte-identical roundtrip"。
///
/// 断言走**渲染出的结论文本**，而不是退出码（退出码由 NEW-8c 锁定为 0，
/// 本轮不改）——这正是缺陷藏身的地方：内部夹取对了，结论句没跟上。
test "CB-19-4: record-length 大于布局时结论不说 byte-identical roundtrip" {
  let cpy = "_cb4_probe.cpy"
  let dat = "_cb4_probe.dat"
  // 2 条 8 字节记录（布局 4 字节 X(4)，尾 4 字节是 0xAA）
  cb4_write(
    cpy, dat, b"\xC1\xC2\xC3\xC4\xAA\xAA\xAA\xAA\xC5\xC6\xC7\xC8\xAA\xAA\xAA\xAA",
  )
  let msg = verify_conclusion(4, 8, 2)
  assert_true(!msg.contains("byte-identical roundtrip"))
  assert_true(msg.contains("first 4"))
  assert_true(msg.contains("trailing 4"))
  // 退出码契约不变（NEW-8c 已锁定 0）
  inspect(cmd_verify(cb4_opts(cpy, dat, Some(8))), content="0")
  cb4_drop(cpy, dat)
}

///|
/// 对照：N == 布局时结论句照旧，一个字符都不改。
test "CB-19-4: record-length 等于布局时结论保持原样" {
  let cpy = "_cb4_probe2.cpy"
  let dat = "_cb4_probe2.dat"
  cb4_write(cpy, dat, b"\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8")
  assert_eq(
    verify_conclusion(4, 4, 2),
    "verify: 2 record(s) OK, byte-identical roundtrip",
  )
  inspect(cmd_verify(cb4_opts(cpy, dat, Some(4))), content="0")
  inspect(cmd_verify(cb4_opts(cpy, dat, None)), content="0")
  cb4_drop(cpy, dat)
}

///|
/// 对照组：N > 布局时结论里两个长度数字都要与实参一致（不能写死）。
test "CB-19-4: 结论句的两个长度数字来自实参" {
  let a = verify_conclusion(54, 108, 5)
  assert_true(a.contains("first 54"))
  assert_true(a.contains("trailing 54"))
  assert_true(a.contains("5 record(s) OK"))
  let b = verify_conclusion(4, 9, 3)
  assert_true(b.contains("first 4"))
  assert_true(b.contains("trailing 5"))
  assert_true(b.contains("3 record(s) OK"))
}
