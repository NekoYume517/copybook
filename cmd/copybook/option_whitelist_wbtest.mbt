// CLI 选项白名单的回归（2026-11-04 对抗性审计 NEW-8a）。
//
// ## 缺陷形态
//
// 选项解析是全局的：`--data` / `--format` / `--record-length` 在任何子命令
// 下都被识别并填进 Options，而各 `cmd_*` 只读自己关心的字段。于是
//
//     copybook encode --copybook x.cpy --json x.jsonl --out x.dat \
//         --record-length 3 --format table --data y
//
// **exit 0**：用户以为这些选项生效了，实际一个都没被读。从别的命令复制
// 命令行、或子命令名打错时，这是最常见的形态，而且没有任何反馈。
//
// 修复：记录显式给出的键（`Options.given`），按子命令白名单校验，
// 不属于该子命令的键报用法错误并列出它接受什么。

///|
test "NEW-8a: layout 只接受 copybook 与 float-mode" {
  let a = allowed_options("layout")
  inspect(a.length(), content="2")
  for k in a {
    assert_true(k == "--copybook" || k == "--float-mode")
  }
}

///|
test "NEW-8a: encode 不接受 data/format/record-length" {
  let a = allowed_options("encode")
  // 这三个键归 decode/verify
  assert_false(a.contains("--data"))
  assert_false(a.contains("--format"))
  assert_false(a.contains("--record-length"))
  // 它自己的两个键必须在
  assert_true(a.contains("--json"))
  assert_true(a.contains("--out"))
}

///|
test "NEW-8a: decode 接受 data/format/record-length，不接受 json" {
  let a = allowed_options("decode")
  assert_true(a.contains("--data"))
  assert_true(a.contains("--format"))
  assert_true(a.contains("--record-length"))
  assert_false(a.contains("--json"))
}

///|
test "NEW-8a: 每个子命令都接受 --float-mode（全局选项）" {
  for sub in ["layout", "decode", "encode", "verify"] {
    assert_true(allowed_options(sub).contains("--float-mode"))
  }
}

///|
test "NEW-8a: 未知子命令返回空表（由 unknown-subcommand 分支报错）" {
  inspect(allowed_options("bogus").length(), content="0")
}
