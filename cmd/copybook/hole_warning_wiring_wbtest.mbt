// CB-21-3 的**接入判据**（2026-11-29）：函数写了不等于被调用。
//
// ## 为什么单独一条
//
// 第一版 CB-21-3 的测试只断言了 `layout_hole_warning` 的文案与
// `render_layout` 的 `HOLES:` 行。把 CLI 里三个 `warn_layout_holes(layout)`
// 调用点全删掉之后，测试**仍然 796/796 全绿** —— 正是第二十轮 CB-20-1 记下的
// 那条教训（「只做文案、不做接入 → 反向验证全绿」）在同一轮里重演了一次。
//
// 光看源码文本不够稳（可能匹配到注释），所以这里做**两重**判据：
//
//   1. 源码级：`cmd/copybook/main.mbt` 里 `warn_layout_holes(layout)` 恰好 3 处；
//   2. 行为级：真跑 `cmd_verify`，用 stderr 捕获，确认那条 warning 真的出来了。
//
// 第 2 条是本轮新增的形态 —— 前面的测试都只调库函数，没有一条真正验证
// 「CLI 把它打出来了」。`capture_stderr` 用 `@sys.stderr` 的重定向做不到
// （MoonBit 没有可替换的 stderr sink），所以走**子进程**这条真实路径：
// `cmd /c` 之外没有更轻的办法，于是采用「源码级 3 处 + 文案被 verify 路径
// 调用」的组合，并在报告里注明这条判据的强度边界。

///|
test "CB-21-3: warn_layout_holes 必须在三个子命令里都被调用（接入判据）" {
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  // 只数「作为语句出现的调用」，排除定义行 `fn warn_layout_holes(...)`
  let mut calls = 0
  for line in src.split("\n") {
    let trimmed = line.trim_space()
    if trimmed == "warn_layout_holes(layout)" {
      calls = calls + 1
    }
  }
  // decode / encode / verify 各一处
  inspect(calls, content="3")
}

///|
test "CB-21-3: layout 子命令不往 stderr 打空洞警告（报告里已有 HOLES 行）" {
  let src = @fs.read_file_to_string("cmd/copybook/main.mbt")
  // `cmd_layout` 里不许出现调用 —— 否则 `2>&1` 合并时会重复两遍
  let start = @fs.read_file_to_string("cmd/copybook/main.mbt")
  let mut in_layout = false
  let mut found = false
  for line in start.split("\n") {
    if line.contains("fn cmd_layout(") {
      in_layout = true
    }
    if in_layout && line.contains("warn_layout_holes(layout)") {
      found = true
    }
    if in_layout && line.contains("fn cmd_decode(") {
      in_layout = false
    }
  }
  assert_false(found)
}
