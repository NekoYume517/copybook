// CB-22-2（2026-11-27 第二十二轮审计）：`API.md` 的**行数契约**值得机检。
//
// `API.md:484-489` 有一张表，声称 `render_layout` 的行数：
//
// | 布局有空洞？ | 行数 |
// |---|---|
// | 无 | `2 + 1 + fields.length()` |
// | 有 | `2 + 1 + fields.length() + 2` |
//
// 这是文档里少数**可以精确对拍**的自由叙述（BN-21-2 出现过「括号合计 34 ≠
// 标题 9」）。它此前只有人眼 —— 实测三份 examples（6/17/5 个字段，无洞）
// 与三份带洞布局（3/2/3 字段，1/1/2 个洞）全部吻合，于是把结论锁成测试：
// 以后谁改 `render_layout` 的尾部（比如把 `HOLES:` 挪到表头、或多余一个空行），
// 这条契约会当场变红，而不是靠评审重数一遍。
//
// ## 判据（双向）
//
// 1. 无洞布局：`挂载行数 == 3 + fields.length()`，且**不含** `HOLES:`；
// 2. 有洞布局：`挂载行数 == 3 + fields.length() + 2`，且**含** `HOLES:`。
//
// 「不含 HOLES」那一半是必需的：只数行数的话，「无洞布局误加一个空 HOLES
// 行、同时又少了一行」可以凑出同一个数字。

///|
fn rlc_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  for part in s.split("\n") {
    out.push(part.to_string())
  }
  out
}

///|
test "API.md 的行数契约：无空洞 = 3 + fields.length()，且不含 HOLES:" {
  let cases : Array[(String, Int32)] = [
    ("01 R.\n  05 A PIC X(2).\n", 1),
    ("01 R.\n  05 A PIC X(2).\n  05 B PIC 9(4).\n", 2),
    ("01 R.\n  05 G.\n    10 A PIC X.\n    10 B PIC X.\n  05 C PIC X.\n", 3),
  ]
  for (src, nfields) in cases {
    let lay = compile_layout(parse_copybook(src))
    let report = render_layout(lay)
    let lines = rlc_lines(report)
    assert_eq(lines.length().to_int(), (3 + nfields).to_int())
    assert_false(report.contains("HOLES:"))
  }
}

///|
test "API.md 的行数契约：有空洞 = 3 + fields.length() + 2，且含 HOLES:" {
  let cases : Array[(String, Int32)] = [
    // A + FILLER(2) + B：2 个字段、1 段洞
    ("01 R.\n  05 A PIC X.\n  05 FILLER PIC X(2).\n  05 B PIC X.\n", 2),
    // A + FILLER + B + FILLER + C：3 个字段、2 段洞
    (
      "01 R.\n  05 A PIC X.\n  05 FILLER PIC X.\n  05 B PIC X.\n  05 FILLER PIC X.\n  05 C PIC X.\n",
      3,
    ),
  ]
  for (src, nfields) in cases {
    let lay = compile_layout(parse_copybook(src))
    let report = render_layout(lay)
    let lines = rlc_lines(report)
    assert_eq(lines.length().to_int(), (5 + nfields).to_int())
    assert_true(report.contains("HOLES:"))
    // 末尾两行必须是「空行 + HOLES:」
    assert_eq(lines[lines.length() - 2], "")
    assert_true(lines[lines.length() - 1].contains("HOLES:"))
  }
}
