// 2026-11-17-b 审计：组级 `OCCURS` 包住一段嵌套 `REDEFINES` 时，布局层把
// **合法** copybook 判成非法。
//
// ## 缺陷形态
//
// `check_redefine_overlap` 用 `Builder.exempt_spans` 放行「视图落在它目标的
// 存储区间内」这一形态（2026-11-12 的嵌套 REDEFINES 修复）。豁免区间是在
// 递归编译子项时按**第 1 个元素**的绝对偏移登记的，而组级 OCCURS 的摊平
// （C1）发生在递归**之后** —— 叶子被改写成 `(k)` 份、偏移加 `(k-1)*inner`，
// 豁免区间却留在了元素 1 的坐标系里。
//
// 于是第 2..n 个元素的视图与目标子树重新落进「不同重定义组、区间重叠、
// 无豁免」的判据（实测：`REDEFINES view 'R.G.H.M.A(1)(2)' (offset 4, length 2)
// overlaps field 'R.G.H.V(1)(2)' (offset 4, length 4)`）。
//
// 同一份结构**去掉外层 OCCURS 就通过** —— 合法性不该由「有没有 OCCURS」
// 决定。这不是宽松度问题：一份 IBM 上合法、本工具能算对字节的 copybook 被
// 整个拒收，用户没有任何绕过办法。
//
// ## 反向锁
//
// 豁免只到「目标跨度」为止：视图溢出到目标之外的兄弟字段上，有没有
// OCCURS 都必须继续报 InvalidLayout（`redefines_nested_test.mbt` 的判据
// 不能被这次复制拉松）。

///|
fn roe_paths(layout : RecordLayout) -> String {
  let parts : Array[String] = []
  for f in layout.fields {
    parts.push("\{f.path}@\{f.offset}:\{f.byte_length}")
  }
  parts.join(",")
}

///|
fn roe_compile(src : String) -> Result[RecordLayout, String] {
  try Ok(compile_layout(parse_copybook(src))) catch {
    e => Err(e.message())
  } noraise {
    v => v
  }
}

///|
test "OCCURS: a nested REDEFINES chain compiles the same with and without OCCURS" {
  // 参照形态（无 OCCURS）：M 是含 A/B 的组，V 重新描述 M 并把跨度撑到 4。
  let plain = roe_compile(
    "01 R.\n  05 M.\n    10 A PIC X(2).\n    10 B REDEFINES A PIC X(2).\n  05 V REDEFINES M PIC X(4).\n",
  )
  match plain {
    Err(e) => fail("the OCCURS-free reference shape must compile: \{e}")
    Ok(l) => assert_eq(roe_paths(l), "R.M.A@0:2,R.M.B@0:2,R.V@0:4")
  }
  // 同一结构包进 `OCCURS 2`：每个元素各占 4 字节（M 2 字节 + V 溢出 2 字节）。
  let occ = roe_compile(
    "01 R.\n  05 G OCCURS 2.\n    10 M.\n      15 A PIC X(2).\n      15 B REDEFINES A PIC X(2).\n    10 V REDEFINES M PIC X(4).\n",
  )
  match occ {
    Err(e) =>
      fail(
        "a group OCCURS must not change the validity of a nested REDEFINES: \{e}",
      )
    Ok(l) => {
      assert_eq(l.byte_length, 8)
      assert_eq(
        roe_paths(l),
        "R.G.M.A(1)@0:2,R.G.M.B(1)@0:2,R.G.V(1)@0:4,R.G.M.A(2)@4:2,R.G.M.B(2)@4:2,R.G.V(2)@4:4",
      )
    }
  }
}

///|
test "OCCURS: nested group OCCURS keeps every element's exemption" {
  let occ = roe_compile(
    "01 R.\n  05 G OCCURS 2.\n    10 H OCCURS 2.\n      15 M.\n        20 A PIC X(2).\n        20 B REDEFINES A PIC X(2).\n      15 V REDEFINES M PIC X(4).\n",
  )
  match occ {
    Err(e) => fail("nested OCCURS + nested REDEFINES must compile: \{e}")
    Ok(l) => {
      assert_eq(l.byte_length, 16)
      assert_eq(l.fields.length(), 12)
      assert_eq(
        roe_paths(l).has_prefix(
          "R.G.H.M.A(1)(1)@0:2,R.G.H.M.B(1)(1)@0:2,R.G.H.V(1)(1)@0:4",
        ),
        true,
      )
    }
  }
}

///|
test "OCCURS reverse lock: a view spanning a sibling is still rejected" {
  // 视图 X(6) 的目标 M 只有 2 字节，第 3..6 字节里的 W 不在 M 的跨度内 ——
  // 无论有没有 OCCURS，都必须是 InvalidLayout（豁免只到目标跨度为止）。
  let plain = roe_compile(
    "01 R.\n  05 M.\n    10 A PIC X(2).\n  05 W PIC X(2).\n  05 V REDEFINES M PIC X(6).\n",
  )
  match plain {
    Ok(_) => fail("a view spanning another leaf must be rejected")
    Err(_) => ()
  }
  let occ = roe_compile(
    "01 R.\n  05 G OCCURS 2.\n    10 M.\n      15 A PIC X(2).\n    10 W PIC X(2).\n    10 V REDEFINES M PIC X(6).\n",
  )
  match occ {
    Ok(_) =>
      fail("a view spanning another leaf must be rejected under OCCURS too")
    Err(_) => ()
  }
}
