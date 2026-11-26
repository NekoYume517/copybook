// CB-20-2（2026-11-28 第二十轮审计）：**COMP-1 / COMP-2 上的 JUSTIFIED RIGHT
// 仍被静默吞掉** —— CB-19-2 只补了 `pc.category` 的两条支路。
//
// ## 缺陷形态（修复前实测）
//
// CB-19-2（2026-11-27）把 JUSTIFIED 的拒绝判据补到了 `pc.category` 的
// `Edited` 与 `Numeric` 两条支路。但 **COMP-1 / COMP-2 不经过 `pc`**：
// 它们走的是「没有 PIC 的浮动项」那条分支（`explicit_usage` 为 Comp1/Comp2
// 时合成 PicClause），而那条分支把 `justified_right: false` 硬写死。于是：
//
//     $ copybook layout --copybook c1_jr.cpy      # 05 A COMP-1 JUSTIFIED RIGHT.
//     exit 0，布局正常，一个字都不提 JUSTIFIED
//     $ copybook encode ... --json '{"R.A":1.5,"R.B":"Z"}'
//     41-18-00-00-E9        ← 与非 JUSTIFIED 版本逐字节相同
//
// 同一轮里，`05 A PIC S9(4) COMP JUSTIFIED RIGHT.` 与 `PIC 9(4) JUSTIFIED
// RIGHT` 都已被正确拒绝（exit 1 + 带行列号的语法错误）。判据在「哪条支路」
// 上的缺口，正是本项目反复出现的「一个权威实现」问题的最新一例。
//
// ## 判据
//
// 1. `COMP-1` / `COMP-2` + `JUSTIFIED`（含 `JUST`、`JUSTIFIED LEFT`、
//    `JUSTIFIED RIGHT`、`SYNCHRONIZED` 混写）→ 解析期拒绝，exit 1，
//    错误消息带行列号并说明理由。
// 2. **不误伤**：`COMP-1` / `COMP-2` 不带 JUSTIFIED 照常编译；
//    `NATIONAL`（`PIC N`）与其他字符类的 JUSTIFIED RIGHT **仍然生效**
//    （实测 `PIC N(3) JUSTIFIED RIGHT` 确实右对齐，是本轮复核的正面结论）。

///|
test "CB-20-2: COMP-1 / COMP-2 上的 JUSTIFIED 在解析期拒绝" {
  let cases : Array[String] = [
    "01 R.\n    05 A COMP-1 JUSTIFIED RIGHT.\n", "01 R.\n    05 A COMP-1 JUSTIFIED.\n",
    "01 R.\n    05 A COMP-1 JUST.\n", "01 R.\n    05 A PIC S9(4) COMP-1 JUSTIFIED RIGHT.\n",
    "01 R.\n    05 A COMP-2 JUSTIFIED RIGHT.\n", "01 R.\n    05 A COMP-2 SYNCHRONIZED JUSTIFIED RIGHT.\n",
  ]
  for src in cases {
    let rejected = try {
      let _ = parse_copybook(src)
      "ok"
    } catch {
      e => e.to_display()
    } noraise {
      _ => "ok"
    }
    assert_true(rejected != "ok")
    assert_true(rejected.contains("JUSTIFIED"))
  }
}

///|
/// `JUSTIFIED LEFT` **不算声明**：它是默认值（无操作），对任何类别都不改变
/// 一个字节。CB-20-2 只拒绝「声明了一个编码器不实现的属性」那种形态；
/// 把 LEFT 也拒掉会把一份合法 copybook 打成语法错误（实测 `COMP-1
/// JUSTIFIED LEFT` 与字符类上的 LEFT 都应当照常编译）。这条是**反向**
/// 判据：确认收紧没有过头。
test "CB-20-2: JUSTIFIED LEFT 是默认值，不拒绝" {
  let ok = try {
    let _ = parse_copybook("01 R.\n    05 A COMP-1 JUSTIFIED LEFT.\n")
    true
  } catch {
    _ => false
  } noraise {
    _ => true
  }
  assert_true(ok)
  let ok2 = try {
    let _ = parse_copybook("01 R.\n    05 A PIC X(4) JUSTIFIED LEFT.\n")
    true
  } catch {
    _ => false
  } noraise {
    _ => true
  }
  assert_true(ok2)
}

///|
test "CB-20-2: 不误伤 —— 不带 JUSTIFIED 的 COMP-1/COMP-2 照常编译" {
  inspect(
    compile_layout(
      parse_copybook("01 R.\n    05 A COMP-1.\n    05 B COMP-2.\n"),
    ).byte_length,
    content="12",
  )
  inspect(
    compile_layout(parse_copybook("01 R.\n    05 A PIC S9(4) COMP-2.\n")).byte_length,
    content="8",
  )
}

///|
test "CB-20-2: 不误伤 —— 字符类（含 NATIONAL）的 JUSTIFIED RIGHT 仍然生效" {
  // CB-19-2 收紧的是「数值/编辑型」，字符类必须原样放行并且真的右对齐。
  let lay = compile_layout(
    parse_copybook(
      "01 R.\n    05 A PIC X(4) JUSTIFIED RIGHT.\n    05 B PIC N(3) JUSTIFIED RIGHT.\n",
    ),
  )
  inspect(lay.byte_length, content="10")
  inspect(lay.fields[0].pic.justified_right, content="true")
  inspect(lay.fields[1].pic.justified_right, content="true")
}
