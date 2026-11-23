// CB-2026-11-23-1（2026-11-23 轮审计）：OCCURS 摊平没有**条数**上限。
//
// 现象（CLI 实测，日志在 audit/2026-11-23/copybook/evidence/）：
//   `PIC X OCCURS 999999999`（1e9 字节 < 2^31，过 checked_mul 字节闸门）
//   → 布局层把 ~10 亿个 FieldLayout 逐条物化，12 秒吃 3.85 GB 峰值内存被杀；
//   `PIC 9 OCCURS 999999999` 同挂；嵌套 `OCCURS 31623 x OCCURS 31623 x
//   PIC X(2)`（总字节 ≈2e9 < 2^31，同样过闸）同挂。而 `PIC X(9) OCCURS
//   999999999`（>2^31）被字节闸门正确拒绝 —— 闸门只挡字节总量，挡不住
//   摊平后的叶子**条数**。
//
// 修法（唯一权威实现，都在布局层）：两个摊平循环（叶子自带 OCCURS、
// 组级 OCCURS）物化之前加 OCCURS_EXPANSION_LIMIT = 2_000_000 守卫。
// decode / verify / encode / layout / 渲染消费同一份 RecordLayout 叶子
// 数组，守卫一处生效、全路径一致。渲染器输出契约不变；不做惰性摊平的
// 架构改动。
//
// 上限理由：放行 `PIC X(2) OCCURS 999999`（约 2 MB 记录、近百万叶子，
// 已远超真实 COBOL 表的常见规模）与恰为 200 万条的组合；挡住 1e9 条目
// 级别的物化（物理内存必然不够）。贴限 / 超限双向都有测试锁定。
//
// 注意：999999999 / 31623x31623 这几条「超限用例」在修复后的实现下是
// 微秒级拒绝（守卫先验后摊，一个条目都不物化）；在修复前的实现下会
// 物化 ~10 亿条目挂死 —— 所以修复前的红灯证据用 CLI 实测法
// （scratch/measure.ps1 带峰值内存采样）另存，不在单测里硬跑挂死。
//
// 「红灯阶段临时注释」标记：超限挂死用例在旧实现下无法出红日志，
// 修复后立即恢复（见文件尾）。

// 红灯阶段临时注释（旧实现下挂死）：

///|
fn occ_cb(src : String) -> String {
  try {
    let _ = compile_layout(parse_copybook(src))
    "ok"
  } catch {
    InvalidLayout(msg) => "err:" + msg
    _ => "other"
  } noraise {
    v => v
  }
}

///|
test "CB-2026-11-23-1: 限值+1 被拒（OCCURS 2000001 PIC X）" {
  let r = occ_cb("01 R.\n  05 A PIC X OCCURS 2000001 TIMES.\n")
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("field 'A'"))
  assert_true(r.contains("2000001 leaf entries"))
  assert_true(r.contains("flattening limit"))
}

///|
test "CB-2026-11-23-1: 恰在限值 2000000 条被接受" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X OCCURS 2000000 TIMES.\n"),
  )
  assert_eq(layout.byte_length, 2000000)
  assert_eq(layout.fields.length(), 2000000)
}

///|
test "CB-2026-11-23-1: 贴限 999999 条 x PIC X(2)（约 2MB 记录）被接受" {
  let layout = compile_layout(
    parse_copybook("01 R.\n  05 A PIC X(2) OCCURS 999999 TIMES.\n"),
  )
  assert_eq(layout.byte_length, 1999998)
  assert_eq(layout.fields.length(), 999999)
  assert_eq(layout.fields[0].path, "R.A(1)")
  assert_eq(layout.fields[0].offset, 0)
  assert_eq(layout.fields[999998].path, "R.A(999999)")
  assert_eq(layout.fields[999998].offset, 1999996)
}

///|
test "CB-2026-11-23-1: 嵌套贴限 2000 x 1000 恰 2000000 条被接受" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G1 OCCURS 2000 TIMES.\n    10 G2 OCCURS 1000 TIMES.\n      15 A PIC X.\n",
    ),
  )
  assert_eq(layout.byte_length, 2000000)
  assert_eq(layout.fields.length(), 2000000)
}

///|
test "CB-2026-11-23-1: 嵌套限值+1 1001 x 2000 条被拒" {
  let r = occ_cb(
    "01 R.\n  05 G1 OCCURS 1001 TIMES.\n    10 G2 OCCURS 2000 TIMES.\n      15 A PIC X.\n",
  )
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("group 'G1'"))
  assert_true(r.contains("2002000 leaf entries"))
}

///|
// 「红灯阶段临时注释」恢复说明：下面三条超限用例在旧实现下会物化
// ~10 亿条目挂死，无法出红日志；红灯证据改用 CLI 实测法
// （evidence/CB-2026-11-23-1-red-occ-max.log 等三份 measure.ps1 日志）。
// 修复后守卫先验后摊，三条全部微秒级拒绝。
test "CB-2026-11-23-1: 叶子 999999999 条 PIC X 被拒（先验后摊，不物化）" {
  let r = occ_cb("01 R.\n  05 A PIC X OCCURS 999999999 TIMES.\n")
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("field 'A'"))
  assert_true(r.contains("999999999 leaf entries"))
}

///|
test "CB-2026-11-23-1: 叶子 999999999 条 PIC 9 被拒" {
  let r = occ_cb("01 R.\n  05 A PIC 9 OCCURS 999999999 TIMES.\n")
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("field 'A'"))
  assert_true(r.contains("999999999 leaf entries"))
}

///|
test "CB-2026-11-23-1: 嵌套 31623 x 31623 累计条数被拒" {
  let r = occ_cb(
    "01 R.\n  05 G1 OCCURS 31623 TIMES.\n    10 G2 OCCURS 31623 TIMES.\n      15 A PIC X(2).\n",
  )
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("group 'G1'"))
  assert_true(r.contains("1000014129 leaf entries"))
}
