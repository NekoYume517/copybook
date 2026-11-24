// CB-2026-11-24-2（2026-11-24 第十七轮审计）：`check_redefine_parentage`
// 是 O(兄弟数²)，且内层每次迭代都 `to_lower()` 一次（每条一条新字符串）。
//
// ## 现象（CLI 实测，`layout` 端到端计时；copybook 是 k 个兄弟、其中一半带
// `REDEFINES`，全部指向同一个 4 字节字段）
//
//     k = 2500   →    808 ms
//     k = 5000   →   2955 ms   (×3.7)
//     k = 10000  →  13929 ms   (×4.7)
//     k = 20000  → 121489 ms   (×8.7)
//     对照：k = 20000 个兄弟但**不带** `REDEFINES` → 699 ms（线性）
//
// 触发量远低于任何上限：2 万条子句 ≈ 500 KB copybook、2 万个叶子，而叶子
// 摊平上限是 2e6、字节闸门是 2^31。也就是说一条完全合法的 copybook 能让
// `layout` / `decode` / `verify` / `encode` 全部沉默 2 分钟（4 万条 ≈ 8 分钟），
// 与 CB-2026-11-23-1（内存）和 CB-2026-11-24-1（视图叶子的二次比较）同族，
// 但走的是**第三个**入口：兄弟层校验。
//
// ## 根因
//
//     for spec in siblings:
//         for other in siblings:                      // k² 次
//             if other.name.to_lower() == want ...    // 每次一条新字符串
//
// ## 修法
//
// 兄弟层只建两张计数表（小写名 → 条数、原始名 → 条数），「除自己以外还有
// 没有同名兄弟」变成两次 O(1) 查询。判据逐字保持：
// `found` 仍然排掉**原始名与本项相同**的兄弟（所以 `a` 与 `A` 这种大小写
// 不同的兄弟照样算命中，`A REDEFINES A` 照样报错）。
//
// ## 红灯证据
//
// 与 CB-2026-11-23-1 / CB-2026-11-24-1 一致：复杂度缺陷，红灯是 CLI 计时
// （audit/2026-11-24/copybook/evidence/），单测里硬跑 2 分钟没有意义。
// 修复后本文件是毫秒级，作为回归哨兵留下。

///|
fn many_siblings_src(k : Int32, with_redefines : Bool) -> String {
  let sb = StringBuilder()
  sb.write_string("01 R.\n  05 A PIC X(4).\n")
  for i = 0; i < k; i = i + 1 {
    if with_redefines {
      sb.write_string("  05 V\{i} REDEFINES A PIC X(4).\n")
    } else {
      sb.write_string("  05 V\{i} PIC X(4).\n")
    }
  }
  sb.to_string()
}

///|
test "CB-2026-11-24-2: 2 万条 REDEFINES 子句不再二次爆炸（旧实现 121s）" {
  let layout = compile_layout(parse_copybook(many_siblings_src(20000, true)))
  assert_eq(layout.byte_length, 4)
  assert_eq(layout.fields.length(), 20001)
  // 兄弟层语义不变：全部指向 A 的同一段存储
  assert_eq(layout.fields[0].path, "R.A")
  assert_eq(layout.fields[20000].offset, 0)
}

///|
test "CB-2026-11-24-2: 目标不在同一兄弟层仍报错（判据不变）" {
  let r = try {
    let _ = compile_layout(
      parse_copybook(
        "01 R.\n  05 G.\n    10 A PIC X(4).\n  05 B REDEFINES A PIC X(2).\n",
      ),
    )
    "ok"
  } catch {
    InvalidLayout(msg) => "err:" + msg
    _ => "other"
  } noraise {
    v => v
  }
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("not a sibling under the same parent item"))
}

///|
test "CB-2026-11-24-2: 大小写不同仍算命中（to_lower 判据不变）" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 alpha PIC X(4).\n  05 B REDEFINES ALPHA PIC X(4).\n",
    ),
  )
  assert_eq(layout.byte_length, 4)
  assert_eq(layout.fields.length(), 2)
}

///|
test "CB-2026-11-24-2: 重定义自己仍报错（自身排除不变）" {
  let r = try {
    let _ = compile_layout(
      parse_copybook("01 R.\n  05 A REDEFINES A PIC X(4).\n"),
    )
    "ok"
  } catch {
    InvalidLayout(msg) => "err:" + msg
    _ => "other"
  } noraise {
    v => v
  }
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("not a sibling"))
}

///|
test "CB-2026-11-24-2: 缺目标名的兄弟仍报错（缺目标判据不变）" {
  let r = try {
    let _ = compile_layout(
      parse_copybook(
        "01 R.\n  05 A PIC X(4).\n  05 B REDEFINES ZZZ PIC X(4).\n",
      ),
    )
    "ok"
  } catch {
    InvalidLayout(msg) => "err:" + msg
    _ => "other"
  } noraise {
    v => v
  }
  assert_true(r.has_prefix("err:"))
  assert_true(r.contains("'ZZZ' is not a sibling"))
}
