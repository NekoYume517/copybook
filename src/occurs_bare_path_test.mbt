// 2026-11-17 审计 C4：`API.md` §5 承诺的「裸路径后备」只兑现了一半。
//
// ## 声明
//
//   API.md:318-321
//     `compile_layout` 将所有叶子 OCCURS 展开为带下标路径、`occurs == 1` 的字段……
//     **未给第一项下标键时，裸路径和裸名仅作为第一项的后备值**，显式下标键优先。
//
// ## 缺陷形态
//
// 「裸名」那一半成立（`encode_field` 的查找是 path → name），「裸路径」那一半
// 不成立：`compile_layout` 摊平之后字段路径是 `R.A(1)`、`occurs == 1`，而
// 取值只查 `field.path` 与 `field.name` —— `{"R.A": 5}` 三个元素一个都查不到，
// 全部按「未赋值存储」写成 0，`exit 0`、零提示。用户以为改了值。
//
// 只有手工构造的 `occurs > 1` 布局才走 `occurs_element_values`（那里有裸路径
// 后备，`manual_occurs_test.mbt` 锁定的就是那条），也就是说：**公开手工结构
// 承诺过的东西，parser 可达的常规形态反而没有**。
//
// 本组测试同时锁住四条读值路径里的三条（JSONL 取值 / render_jsonl 渲染 /
// encode 编码）；第四条 `field_will_write`（空洞判定）由同一份 `field_value`
// 实现保证，见 `src/field_will_write_mirror_wbtest.mbt`。

///|
fn c4_numeric() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC 9 OCCURS 3.\n"))
}

///|
fn c4_text() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 T PIC X(1) OCCURS 2.\n"))
}

///|
fn c4_bytes(
  row : Map[String, CellValue],
  layout : RecordLayout,
) -> Array[Int32] {
  let out : Array[Int32] = []
  match encode_record(layout, row) {
    Ok(b) =>
      for i = 0; i < b.length(); i = i + 1 {
        out.push(b[i].to_int())
      }
    Err(e) => abort("encode failed: \{e.to_display()}")
  }
  out
}

///|
test "C4: bare path supplies the first OCCURS element only" {
  let layout = c4_numeric()
  let row = parse_jsonl_row(layout, "{\"R.A\":5}").unwrap()
  // 红：修复前三个元素都查不到 → F0 F0 F0
  assert_eq(c4_bytes(row, layout), [0xF5, 0xF0, 0xF0])
}

///|
test "C4: bare name still supplies the first OCCURS element" {
  // 另一半承诺（裸名）本来就成立，这里锁住不许回退。
  let layout = c4_numeric()
  let row = parse_jsonl_row(layout, "{\"A\":5}").unwrap()
  assert_eq(c4_bytes(row, layout), [0xF5, 0xF0, 0xF0])
}

///|
test "C4: an explicit index key wins over the bare path for the same element" {
  let layout = c4_numeric()
  // 显式下标键优先：`R.A(1)` 压过裸路径 `R.A`
  let row = parse_jsonl_row(layout, "{\"R.A\":5,\"R.A(1)\":9}").unwrap()
  assert_eq(c4_bytes(row, layout), [0xF9, 0xF0, 0xF0])
  // 裸路径仍只补第一项：显式给的是第 2 项时，第 1 项照旧由裸路径供给
  let sparse = parse_jsonl_row(layout, "{\"R.A\":5,\"R.A(2)\":7}").unwrap()
  assert_eq(c4_bytes(sparse, layout), [0xF5, 0xF7, 0xF0])
}

///|
test "C4: bare path works for text OCCURS leaves too" {
  let layout = c4_text()
  let row = parse_jsonl_row(layout, "{\"R.T\":\"A\"}").unwrap()
  assert_eq(c4_bytes(row, layout), [0xC1, 0x40])
}

///|
test "C4: render_jsonl honours the bare path for the first element" {
  let layout = c4_numeric()
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(5L)
  let text = render_jsonl(layout, [row])
  // 红：修复前全渲染成 null
  assert_true(text.contains("\"R.A(1)\":5"))
  assert_true(text.contains("\"R.A(2)\":null"))
  assert_true(text.contains("\"R.A(3)\":null"))
}

///|
test "C4: render_jsonl prefers the indexed key over the bare path" {
  let layout = c4_numeric()
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Int(5L)
  row["R.A(1)"] = Int(9L)
  let text = render_jsonl(layout, [row])
  assert_true(text.contains("\"R.A(1)\":9"))
}

///|
test "C4: the bare path never reaches element 2 or later" {
  // 只服务第 1 个元素：别的元素不许被同一个值重复写入。
  let layout = c4_numeric()
  let row = parse_jsonl_row(layout, "{\"R.A\":5}").unwrap()
  assert_eq(row.length(), 1)
}
