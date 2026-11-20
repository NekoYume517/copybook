// JUSTIFIED RIGHT 跨类型矩阵（2026-11-21 审计）
//
// #1 修的是 decode 侧的 trim 判据，#2 修的是 NATIONAL encode 侧的对齐判据。
// 两条判据必须同源，所以这里把三个入口/layout 形态绑成一张矩阵，每组都断言
// 三件事：
//   1. `encode_record(Text(v))` 的存储字节
//   2. 把这些字节解回来的值（`decode_record`）
//   3. `roundtrip_check` 对这批字节判 identical（L1，FIDELITY §1 首行承诺）
//
// 矩阵：`PIC X(5) JUSTIFIED RIGHT` × `PIC N(5) JUSTIFIED RIGHT` × `PIC X(5)`
// （无 JUSTIFIED）× 三个值长度（短 / 正好填满 / 全空白）。

///|
fn jr_matrix_hex(bs : Bytes) -> String {
  let digits = b"0123456789abcdef"
  let sb = StringBuilder()
  for b in bs {
    let x = b.to_int()
    sb.write_char(digits[(x >> 4) & 0xF].to_int().unsafe_to_char())
    sb.write_char(digits[x & 0xF].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn jr_matrix_case(
  label : String,
  cb : String,
  value : String,
  expected_hex : String,
  expected_decoded : String,
) -> Unit raise {
  let layout = compile_layout(parse_copybook(cb))
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text(value)
  let encoded = match encode_record(layout, row) {
    Ok(bs) => bs
    Err(e) => fail("\{label}: encode failed: \{e.to_display()}")
  }
  assert_eq(jr_matrix_hex(encoded), expected_hex)
  let decoded = decode_record(layout, encoded).unwrap()
  let text = match decoded.get("R.A") {
    Some(Text(s)) => s
    None | Some(_) => fail("\{label}: R.A must decode to Text")
  }
  assert_eq(text, expected_decoded)
  match roundtrip_check(layout, encoded) {
    Ok(None) => ()
    Ok(Some(at)) => fail("\{label}: roundtrip mismatch at byte \{at}")
    Err(e) => fail("\{label}: roundtrip error: \{e.to_display()}")
  }
}

///|
test "justified-right matrix: x(5) jr" {
  let cb = "01 R.\n    05 A PIC X(5) JUSTIFIED RIGHT.\n"
  // 短值：补齐在左侧
  jr_matrix_case("x-jr/short", cb, "AB", "404040c1c2", "   AB")
  // 正好填满：不补
  jr_matrix_case("x-jr/exact", cb, "ABCDE", "c1c2c3c4c5", "ABCDE")
  // 全空白：空值 ⇔ 五个 0x40
  jr_matrix_case("x-jr/blank", cb, "", "4040404040", "")
}

///|
test "justified-right matrix: n(5) jr" {
  let cb = "01 R.\n    05 A PIC N(5) JUSTIFIED RIGHT.\n"
  jr_matrix_case("n-jr/short", cb, "AB", "00200020002000410042", "   AB")
  jr_matrix_case("n-jr/exact", cb, "ABCDE", "00410042004300440045", "ABCDE")
  jr_matrix_case("n-jr/blank", cb, "", "00200020002000200020", "")
}

///|
test "justified-right matrix: x(5) without justified" {
  let cb = "01 R.\n    05 A PIC X(5).\n"
  // 无 JUSTIFIED：补齐在右侧，decode 照旧 trim
  jr_matrix_case("x-plain/short", cb, "AB", "c1c2404040", "AB")
  jr_matrix_case("x-plain/exact", cb, "ABCDE", "c1c2c3c4c5", "ABCDE")
  jr_matrix_case("x-plain/blank", cb, "", "4040404040", "")
}
