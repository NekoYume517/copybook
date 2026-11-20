// 报告面的 PIC 数值域守卫（2026-11-21 审计）
//
// ## 缺陷形态（修复前）
//
// `pic_type_name` 是 `pub`，并且被 `render_layout` 用来出布局报告；它按
// `pic.scale` **逐位展开** P / 9。C11 的 scale 守卫（`check_pic_scale`）
// 只在 `decode_field` / `encode_field` 两个数据面入口，报告面漏了，于是同一个
// 手建 PicClause：
//
// - `scale = 2_000_000_000`：`for i < scale { "9" }` → 十亿次 append。实测跑满
//   28 秒后访问越界崩进程（`0xc0000005`），见
//   `evidence/pic-scale-hang.err.log`；
// - `scale = -2147483648`：`-scale` 回绕成负数 → 循环零次 → 尾随 P 静默消失，
//   打印成 `9(3) DISPLAY`，与 `scale = 0` **完全同形**（"看起来正常"的谎报）；
// - `digits = 0, storage_digits = -2_000_000_000`：`scale - storage_digits`
//   溢出成巨量 P，同样炸。
//
// 修法：报告面在**真正展开 scale 的位置**（`pic_type_name` 入口）判域，越域
// 就回一行原始三元组；`render_layout` 逐行标注并在末尾汇总 WARNING。域与
// 数据面同源（`|scale| <= 18` = `MAX_DECIMAL_SCALE`，位数非负），所以解析器
// 产出的每一个合法 PIC 都照样逐字渲染 —— 下面的"合法形态逐字不变"用例就是
// 这条断言。

///|
fn guard_layout(
  scale : Int32,
  digits : Int32,
  storage_digits : Int32,
) -> RecordLayout raise ParseError {
  let base = compile_layout(parse_copybook("01 R.\n    05 A PIC 9(3).\n"))
  let f = base.fields[0]
  {
    ..base,
    fields: [{ ..f, pic: { ..f.pic, scale, digits, storage_digits, }, }],
  }
}

///|
test "pic report guard: absurd scale is reported, not expanded" {
  // 修复前：十亿次 append，进程崩溃（0xc0000005）
  let layout = guard_layout(2000000000, 0, 0)
  let text = render_layout(layout)
  assert_true(text.contains("<PIC out of range:"))
  assert_true(text.contains("scale=2000000000"))
  assert_true(text.contains("WARNING: 1 field(s) carry a PIC outside"))
}

///|
test "pic report guard: Int32::MIN scale is not silently dropped" {
  // 修复前：打印成 "9(3) DISPLAY"，和 scale = 0 一模一样
  let layout = guard_layout(-2147483647 - 1, 3, 3)
  let pic = layout.fields[0].pic
  let name = pic_type_name(pic)
  assert_false(name == "9(3) DISPLAY")
  assert_true(name.contains("scale=-2147483648"))
}

///|
test "pic report guard: negative storage digits cannot overflow P runs" {
  // digits = 0 时 leading_p = scale - storage_digits，负 storage 会溢出成巨量 P
  let layout = guard_layout(18, 0, -2000000000)
  let name = pic_type_name(layout.fields[0].pic)
  assert_true(name.contains("storage=-2000000000"))
  assert_true(
    render_layout(layout).contains("outside the supported decimal domain"),
  )
}

///|
test "pic report guard: scales beyond the engine domain are rejected" {
  for scale in [19, -19, 2147483647] {
    let name = pic_type_name(guard_layout(scale, 3, 3).fields[0].pic)
    assert_true(name.contains("<PIC out of range:"))
  }
}

///|
test "pic report guard: parser-produced pics render exactly as before" {
  let cb = "01 R.\n    05 A PIC 9(5)V99.\n    05 B PIC 9(3)PP.\n    05 C PIC PP9(2).\n    05 D PIC X(30).\n    05 E PIC N(5).\n    05 F PIC ZZ,ZZ9.99.\n    05 G PIC S9(7)V99 COMP-3.\n    05 H PIC S9(9) COMP-5.\n    05 I PIC 9(5).\n    05 J PIC 9(3)V9(3).\n"
  let layout = compile_layout(parse_copybook(cb))
  let want : Array[(String, String)] = [
    ("R.A", "9(5)V99 DISPLAY"),
    ("R.B", "9(3)PP DISPLAY"),
    ("R.C", "PP9(2) DISPLAY"),
    ("R.D", "X(30) DISPLAY"),
    ("R.E", "N(5) DISPLAY"),
    ("R.F", "EDITED(5) DISPLAY"),
    ("R.G", "S9(7)V99 COMP-3"),
    ("R.H", "S9(9) COMP"),
    ("R.I", "9(5) DISPLAY"),
    ("R.J", "9(3)V999 DISPLAY"),
  ]
  for (path, expected) in want {
    let f = layout.find(path).unwrap()
    assert_eq(pic_type_name(f.pic), expected)
    // 合法布局的报告里不该出现守卫生成的标记
    assert_false(pic_type_name(f.pic).contains("out of range"))
  }
  // 末尾不该多出 PIC 域 WARNING（只有真正的越域布局才有）
  assert_false(
    render_layout(layout).contains("outside the supported decimal domain"),
  )
}
