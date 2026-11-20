// `format_json_number` 的真实输出形态（2026-11-21 审计，文档锁）
//
// ## 这一条为什么是"文档失真"
//
// `format_json_number` 的 docstring 曾写"渲染成**不带科学计数法**的十进制串"
// 且"只用于手写 JSON 没有 repr 的兜底路径；导出的 JSONL 总是带 repr"。
// 实测：
//
//   - 导出 JSONL 的浮点 repr 就是它生成的（`cell_to_json` → `Json::number(repr=)`）；
//   - 非整数且量级很大/很小走 `Double::to_string()`：`1e-7` → `"1e-7"`、
//     `1e300` → `"1e+300"`（科学计数法）。
//
// 数值与字节往返都不受影响（JSON number 允许指数、解析回同一个 double），
// 所以只更正措辞 + 把形态锁进用例，不改实现。

///|
fn float_repr_layout() -> RecordLayout raise ParseError {
  compile_layout_with_float_mode(
    parse_copybook("01 R.\n    05 A PIC S9(9) COMP-2.\n"),
    Ieee754,
  )
}

///|
/// double → 8 字节大端（IEEE binary64）
fn float_repr_bytes(d : Double) -> Bytes {
  let bits = d.reinterpret_as_int64()
  let out : Array[Byte] = []
  for i = 0; i < 8; i = i + 1 {
    let shift = (7 - i) * 8
    out.push(((bits >> shift) & 0xFFL).to_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn float_repr_jsonl(d : Double) -> String raise ParseError {
  let layout = float_repr_layout()
  let row = decode_record(layout, float_repr_bytes(d)).unwrap()
  render_jsonl(layout, [row])
}

///|
test "float repr: integral values are folded to plain integers" {
  // 1e18 是精确可表示的整数，repr 走整数折叠/长十进制形态，不带指数
  let text = float_repr_jsonl(1.0e18)
  assert_true(text.contains(":1000000000000000000"))
  assert_false(text.contains("e+18"))
}

///|
test "float repr: very small magnitude uses scientific notation" {
  let text = float_repr_jsonl(1.0e-7)
  assert_true(text.contains(":1e-7"))
}

///|
test "float repr: very large magnitude uses scientific notation" {
  let text = float_repr_jsonl(1.0e300)
  assert_true(text.contains(":1e+300"))
}

///|
test "float repr: scientific notation still round-trips bytes" {
  for d in [1.0e-7, 1.0e300, 1.0e18, 12345.67] {
    let layout = float_repr_layout()
    let rec = float_repr_bytes(d)
    let row = decode_record(layout, rec).unwrap()
    let jsonl = render_jsonl(layout, [row])
    let back = parse_jsonl_row(layout, jsonl).unwrap()
    assert_eq(encode_record(layout, back).unwrap(), rec)
  }
}
