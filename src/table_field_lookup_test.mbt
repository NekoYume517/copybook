// 2026-11-17-b 审计（C4 的镜像缺口）：取值口径的**第五份拷贝**在 render_table。
//
// C4（b3007cf）把「完整路径 → 裸路径 → 裸名（只服务第一项）」收敛到
// `field_value`，并改掉了 parse_jsonl_row / render_jsonl / encode_field /
// field_will_write 四条路径。`render_table` 漏在外面，仍是旧的两段查找
// （`row.get(field.path)` 后再 `row.get(field.name)`），于是：
//
//   `01 R. 05 A PIC 9(2) OCCURS 3.` + `{"A":"5"}`（裸名 = 第一项的后备）
//     render_jsonl -> {"R.A(1)":"5","R.A(2)":null,"R.A(3)":null}   （正确）
//     render_table -> 5  5  5                                     （三个元素全拿到 5）
//
//   + `{"R.A":"7"}`（裸路径 = 第一项的后备）
//     render_jsonl -> {"R.A(1)":"7","R.A(2)":null,"R.A(3)":null}   （正确）
//     render_table -> 空白                                         （裸路径完全不认）
//
// 同一行数据在两条渲染路径上给出互相矛盾的结论，正是 C4 要消灭的形态。

///|
fn tfl_count(s : String, c : Char) -> Int32 {
  let mut n = 0
  for ch in s.to_array() {
    if ch == c {
      n = n + 1
    }
  }
  n
}

///|
fn tfl_last_line(layout : RecordLayout, row : Map[String, CellValue]) -> String {
  let text = render_table(layout, [row])
  let lines = text.split("\n").collect()
  // 表格最后一行是数据行（结尾带一个 \n，split 后多出一个空串）
  if lines.length() >= 2 {
    lines[lines.length() - 2].to_owned()
  } else {
    text
  }
}

///|
fn tfl_layout() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC 9(2) OCCURS 3.\n"))
}

///|
test "table: the bare field name backs only the first OCCURS element" {
  let layout = tfl_layout()
  let row : Map[String, CellValue] = Map([("A", Text("5"))])
  // JSONL 侧是权威口径（C4 已锁）：只有第一项拿到值。
  assert_eq(
    render_jsonl(layout, [row]),
    "{\"R.A(1)\":\"5\",\"R.A(2)\":null,\"R.A(3)\":null}\n",
  )
  // 表格必须与它一致：第一列 5，后两列空白 —— 旧实现打印 "5  5  5"。
  assert_eq(tfl_count(tfl_last_line(layout, row), '5'), 1)
}

///|
test "table: the bare field path backs only the first OCCURS element" {
  let layout = tfl_layout()
  let row : Map[String, CellValue] = Map([("R.A", Text("7"))])
  assert_eq(
    render_jsonl(layout, [row]),
    "{\"R.A(1)\":\"7\",\"R.A(2)\":null,\"R.A(3)\":null}\n",
  )
  // 旧实现完全不认裸路径：三列全空。
  assert_eq(tfl_count(tfl_last_line(layout, row), '7'), 1)
}

///|
test "table reverse lock: full-path rows still render every element" {
  // decode 的输出恒为完整路径键，这条路径不能被上面的收敛改坏。
  let layout = tfl_layout()
  let row : Map[String, CellValue] = Map([
    ("R.A(1)", Text("1")),
    ("R.A(2)", Text("2")),
    ("R.A(3)", Text("3")),
  ])
  let line = tfl_last_line(layout, row)
  assert_eq(tfl_count(line, '1'), 1)
  assert_eq(tfl_count(line, '2'), 1)
  assert_eq(tfl_count(line, '3'), 1)
}

///|
test "table reverse lock: a bare name matching the first element does not erase explicit indices" {
  // 显式下标键优先（API.md §5）：给了 (2) 时裸名不能覆盖它。
  let layout = tfl_layout()
  let row : Map[String, CellValue] = Map([
    ("A", Text("5")),
    ("R.A(2)", Text("9")),
  ])
  let line = tfl_last_line(layout, row)
  assert_eq(tfl_count(line, '9'), 1)
  assert_eq(tfl_count(line, '5'), 1)
}
