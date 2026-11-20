// CLI 选项的"值位"不许吞掉另一个选项（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `parse_options` 的 `take_value` 只看"有没有下一个 token"，于是：
//
//     copybook decode --copybook --data c.dat
//
// 把 `--data` 当成 `--copybook` 的值吃掉，随后 `c.dat` 变成"未知选项"，
// 报错是 `unknown option 'c.dat'` —— 真正的问题（`--copybook` 缺值）被
// 错位诊断掩盖，用户会去查一个不存在的选项拼写。
//
// 修法：值位遇到以 `--` 开头的 token 一律报"缺少值"并点名这两个 token；
// 真要传以 `--` 开头的路径，用内联写法 `--copybook=--weird.cpy`（内联值
// 不经过这条判定）。单短横线（`-x.cpy`）不是选项前缀，仍然当值。
//
// 重复选项静默后者覆盖（`--format jsonl --format table` → table）本轮
// **不改**：只把现状锁进用例，避免以后无声漂移。

///|
test "option value position must not swallow another option" {
  match parse_options(["--copybook", "--data", "c.dat"]) {
    Ok(_) => fail("--copybook must not consume '--data' as its value")
    Err(msg) => {
      assert_true(msg.contains("--copybook"))
      assert_true(msg.contains("--data"))
      assert_true(msg.contains("requires a value"))
    }
  }
  match parse_options(["--record-length", "--format", "table"]) {
    Ok(_) => fail("--record-length must not consume '--format'")
    Err(msg) => assert_true(msg.contains("requires a value"))
  }
}

///|
test "inline form still passes values that start with --" {
  match parse_options(["--copybook=--weird.cpy", "--data", "c.dat"]) {
    Ok(opts) => assert_eq(opts.copybook, Some("--weird.cpy"))
    Err(msg) => fail("inline value must be accepted, got: \{msg}")
  }
}

///|
test "single-dash values are still ordinary values" {
  match parse_options(["--copybook", "-x.cpy", "--data", "d.dat"]) {
    Ok(opts) => assert_eq(opts.copybook, Some("-x.cpy"))
    Err(msg) => fail("'-x.cpy' is not an option prefix, got: \{msg}")
  }
}

///|
test "duplicate options keep last-wins (documented, unchanged this round)" {
  match parse_options(["--format", "jsonl", "--format", "table"]) {
    Ok(opts) => assert_eq(opts.format, "table")
    Err(msg) => fail("duplicate options are still accepted, got: \{msg}")
  }
}
