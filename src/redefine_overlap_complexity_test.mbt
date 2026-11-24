// CB-2026-11-24-1（2026-11-24 第十七轮审计）：REDEFINES 重叠检查是
// O(视图叶子 × 全部叶子)。
//
// ## 现象（CLI 实测，`layout` 端到端计时）
//
//     01 R.
//        05 A PIC X(1).
//        05 V REDEFINES A.
//           10 X1 PIC X OCCURS n.
//
//   n = 25000 → 1036 ms；n = 50000 → 3873 ms（规模 ×2、耗时 ×3.7 → 二次）；
//   同一 n 的**非视图** OCCURS 50000 → 281 ms（线性，对照组）。
//   两个视图各 50000（视图叶子 10 万、总叶子 10 万）→ **20478 ms**。
//   拟合 1e10 次区间比较 ≈ 20 s，与 32→50k 两点的斜率一致。
//
// 这不是"大表本来就慢"：`OCCURS_EXPANSION_LIMIT` 允许 2e6 个叶子
// （CB-2026-11-23-1 定的上限），而 2e6 个视图叶子 × 2e6 个叶子
// = 4e12 次比较 ≈ 数小时 CPU —— **一条通过摊平上限的合法 copybook
// 就能把 layout / decode / verify / encode 全部拖死**。上一轮的守卫只管
// 物化条数与字节总量，管不到这条二次路径。
//
// ## 根因
//
// `check_redefine_overlap` 对每个视图叶子全表扫描：
//
//     for view in leaves:            // 视图叶子，n 个
//         for other in leaves:       // 全部叶子，n+1 个
//
// 判据本身只需要「与 [vs, ve) 相交的叶子」，但它没有利用
// `leaves` 已按 offset 升序这一事实（compile_layout 排过序）。
//
// ## 修法
//
// 起点用「前缀最大结束偏移」（单调不减）+ 二分：第一个结束偏移 > vs 的
// 叶子之前的叶子全在 vs 左侧结束，不可能相交；从该处向后扫，
// `other.offset >= ve` 即停。每个视图因此只做 O(log n + 命中数) 次比较，
// **判据与两两全扫逐字等价**（候选集 = {other | other.offset < ve 且
// other.end > vs}），不改任何报错文本与判定结果。
//
// ## 红灯证据
//
// 本职是复杂度缺陷，旧实现在本文件第 1 条用例上要跑 ~33 s（2e6 条上限时
// 是数小时），单测里硬跑挂死没有意义 —— 与 CB-2026-11-23-1 的处理方式
// 一致，红灯证据用 CLI 计时（audit/2026-11-24/copybook/evidence/）：
//   修复前：viewocc=25000 1036 ms / 50000 3873 ms / 2×50000 20478 ms
//   修复后：同三条 < 60 ms / < 100 ms / < 150 ms
// 修复后本文件的用例是毫秒级，作为回归哨兵留在套件里：一旦有人把全表
// 扫描写回来，这条用例立刻从毫秒级退化到十秒级。

///|
fn redef_ov_cb(src : String) -> String {
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
test "CB-2026-11-24-1: 视图内 OCCURS 10 万条不再二次爆炸（旧实现 ~33s）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(1).\n  05 V REDEFINES A.\n    10 X1 PIC X OCCURS 100000 TIMES.\n",
    ),
  )
  assert_eq(layout.byte_length, 100000)
  assert_eq(layout.fields.length(), 100001)
  // 视图叶子仍是逐条摊平、偏移连续 —— 检查没有顺手改变布局语义
  assert_eq(layout.fields[1].path, "R.V.X1(1)")
  assert_eq(layout.fields[1].offset, 0)
  assert_eq(layout.fields[100000].path, "R.V.X1(100000)")
  assert_eq(layout.fields[100000].offset, 99999)
}

///|
test "CB-2026-11-24-1: 两个视图各 50000 条（旧实现 20478ms）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 A PIC X(1).\n  05 V1 REDEFINES A.\n    10 X1 PIC X OCCURS 50000 TIMES.\n  05 V2 REDEFINES A.\n    10 X2 PIC X OCCURS 50000 TIMES.\n",
    ),
  )
  assert_eq(layout.byte_length, 50000)
  assert_eq(layout.fields.length(), 100001)
}

///|
// 等价性锁定：视图压到**后面的**字段上仍必须报错（候选窗口的后边界）。
test "CB-2026-11-24-1: 视图溢出到后续字段仍报错（窗口不丢命中）" {
  let r = redef_ov_cb(
    "01 R.\n  05 A PIC X(4).\n  05 B PIC X(2).\n  05 V REDEFINES A PIC X(5).\n",
  )
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("'R.V'"))
  assert_true(r.contains("'R.B'"))
  assert_true(r.contains("overlaps field"))
}

///|
// 等价性锁定：目标跨度豁免仍然成立（嵌套 REDEFINES 的合法形态不能被新窗口误杀）。
test "CB-2026-11-24-1: 组视图覆盖目标子树仍被接受（豁免路径不变）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n  05 V REDEFINES M PIC X(4).\n",
    ),
  )
  assert_eq(layout.byte_length, 4)
  assert_eq(layout.fields.length(), 3)
}

///|
// 等价性锁定：视图跨度按视图叶子的**单元素**长度算（不是整段 OCCURS），
// 大视图内部不得把自己人当成外来字段。
test "CB-2026-11-24-1: 视图内多叶子互不误报（同组跳过语义不变）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B PIC X(2).\n  05 V REDEFINES M.\n    10 C1 PIC X(2).\n    10 C2 PIC X(2).\n",
    ),
  )
  assert_eq(layout.byte_length, 4)
  assert_eq(layout.fields.length(), 4)
}
