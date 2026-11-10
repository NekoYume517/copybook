// CB-B9（2026-11-10 审计）：layout 报告的 TYPE 列丢失 P 缩放位。
//
// ## 缺陷形态（修复前）
//
// `PIC 9(3)PP`（尾随 P：值 = 存储系数 × 10^2）在报告里显示成 `9(3) DISPLAY`，
// `PIC PP9(2)`（前导 P：值 = 存储系数 × 10^-4）显示成 `9(0)V9999 DISPLAY`。
//
// 值语义与字节往返都是对的（`Decimal.scale` 为负/大正值，decode/encode
// 各自处理），**只有报告看不出来**：一份 `9(3)PP` 与一份 `9(3)` 的 TYPE 列
// 完全一样，而两者差 100 倍。拿布局报告复核数据字典的人会被直接误导 ——
// 这正是「报告与实现不符」这一类，不是数值缺陷。
//
// 修法：TYPE 列按 P 的真实形态渲染（尾随 P 原样补 `P`，前导 P 补在
// `9(n)` 前面），普通 `9(n)` / `S9(n)V9(m)` 的渲染逐字不变。

///|
fn ps_type(cb : String) -> String raise ParseError {
  let layout = compile_layout(parse_copybook(cb))
  pic_type_name(layout.find("R.A").unwrap().pic)
}

///|
test "CB-B9: TYPE 列保留尾随 P 缩放位（9(3)PP 不再显示成 9(3)）" {
  inspect(ps_type("01  R.\n    05  A  PIC 9(3)PP.\n"), content="9(3)PP DISPLAY")
  // 带符号 + 非 Display 的组合同样要看见 P
  inspect(
    ps_type("01  R.\n    05  A  PIC S9(2)PPP.\n"),
    content="S9(2)PPP DISPLAY",
  )
}

///|
test "CB-B9: TYPE 列保留前导 P 缩放位（PP9(2) 不再显示成 9(0)V9999）" {
  inspect(ps_type("01  R.\n    05  A  PIC PP9(2).\n"), content="PP9(2) DISPLAY")
}

///|
test "CB-B9: 无 P 的 TYPE 列逐字不变（修复不伤既有报告）" {
  inspect(ps_type("01  R.\n    05  A  PIC 9(3).\n"), content="9(3) DISPLAY")
  inspect(
    ps_type("01  R.\n    05  A  PIC S9(5)V99 COMP-3.\n"),
    content="S9(5)V99 COMP-3",
  )
  inspect(ps_type("01  R.\n    05  A  PIC X(7).\n"), content="X(7) DISPLAY")
}

///|
test "CB-B9: render_layout 的 p06 报告里能看见 P" {
  let layout = compile_layout(
    parse_copybook("01  R.\n    05  A  PIC 9(3)PP.\n    05  B  PIC PP9(2).\n"),
  )
  let text = render_layout(layout)
  assert_true(text.contains("9(3)PP"))
  assert_true(text.contains("PP9(2)"))
}
