// 2026-11-17 审计 C9：裸名命中多个字段时，静默写全部 = 替用户发明意图。
//
// ## 缺陷形态
//
// `01 R. 05 G1. 10 A PIC 9(2). 05 G2. 10 A PIC 9(2).` 上写
// `{"A": 5}`：取值按「path → name」逐个字段查，两个 `A` 都命中同一个键，
// 于是 **两个字段都被写成 5**，exit 0。用户只点名了一个字段，另一个被静默改值。
//
// 旁路键族（`__nibbles` / `__float_hex`）此前是另一种口径：命中即 `remove`，
// 先到先得 —— 同一个裸名只作用于第一个字段。四个旁路键在「裸名」这条语义上
// 出现了两种不一致的行为，两种都不对：
//
//   - 值族：多发写（把便利做成批量赋值）；
//   - 旁路族：先到先得（第二个字段的字节声明被无声丢弃）。
//
// 裁决（本轮 Lead 拍板）：统一成「单命中照写、多命中报歧义」，文案指出歧义的
// 路径并提示用完整路径。裸名是便利，不是批量赋值。
//
// 注意与 OCCURS 的区别：`05 A PIC 9 OCCURS 3` 的 `{"A":5}` 不是歧义 —— 那是
// **同一个字段**的三个元素，语义是「后备第一项」（C4 的 `field_value`）。

///|
fn c9_dup_leaf() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 G1.\n    10 A PIC 9(2).\n  05 G2.\n    10 A PIC 9(2).\n",
    ),
  )
}

///|
fn c9_dup_packed() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 G1.\n    10 N PIC S9(3) COMP-3.\n  05 G2.\n    10 N PIC S9(3) COMP-3.\n",
    ),
  )
}

///|
fn c9_dup_float() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n  05 G1.\n    10 F COMP-2.\n  05 G2.\n    10 F COMP-2.\n",
    ),
  )
}

///|
fn c9_bytes(
  layout : RecordLayout,
  row : Map[String, CellValue],
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
test "C9: a bare name matching two different fields is an ambiguity error" {
  let layout = c9_dup_leaf()
  match parse_jsonl_row(layout, "{\"A\":5}") {
    Err(e) => {
      assert_true(e.contains("ambiguous"))
      assert_true(e.contains("R.G1.A"))
      assert_true(e.contains("R.G2.A"))
    }
    Ok(row) =>
      fail(
        "ambiguous bare name must be rejected, got bytes \{c9_bytes(layout, row)}",
      )
  }
}

///|
test "C9: full paths still address both fields" {
  let layout = c9_dup_leaf()
  let row = parse_jsonl_row(layout, "{\"R.G1.A\":5,\"R.G2.A\":7}").unwrap()
  assert_eq(c9_bytes(layout, row), [0xF0, 0xF5, 0xF0, 0xF7])
}

///|
test "C9: an unambiguous bare name still works" {
  let layout = compile_layout(
    parse_copybook(
      "01 R.\n  05 G1.\n    10 A PIC 9(2).\n  05 G2.\n    10 B PIC 9(2).\n",
    ),
  )
  let row = parse_jsonl_row(layout, "{\"A\":5}").unwrap()
  assert_eq(c9_bytes(layout, row), [0xF0, 0xF5, 0xF0, 0xF0])
}

///|
test "C9: ambiguous bare names in __nibbles are rejected, not first-come-first-served" {
  let layout = c9_dup_packed()
  // 旧行为：先到的 R.G1.N 拿走这条旁路，R.G2.N 的符号声明被无声丢弃。
  match parse_jsonl_row(layout, "{\"__nibbles\":{\"N\":{\"sign\":12}}}") {
    Err(e) => assert_true(e.contains("ambiguous"))
    Ok(_) => fail("ambiguous __nibbles key must be rejected")
  }
  // 单命中仍然照写（两个字段各自用完整路径时互不干扰）
  match
    parse_jsonl_row(
      layout, "{\"R.G1.N\":123,\"R.G2.N\":-45,\"__nibbles\":{\"R.G1.N\":{\"sign\":12}}}",
    ) {
    Ok(_) => ()
    Err(e) => fail("unambiguous __nibbles key must still parse: \{e}")
  }
}

///|
test "C9: ambiguous bare names in __float_hex are rejected too" {
  let layout = c9_dup_float()
  match
    parse_jsonl_row(layout, "{\"__float_hex\":{\"F\":\"4180000000000001\"}}") {
    Err(e) => assert_true(e.contains("ambiguous"))
    Ok(_) => fail("ambiguous __float_hex key must be rejected")
  }
}
