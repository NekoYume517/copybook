// 编辑型 `CR` / `DB` 的存储宽度（2026-11-21 审计，**锁实现、不改实现**）
//
// ## 这一条为什么是"文档失真"而不是缺陷
//
// 实现从一开始就把 `CR` / `DB` 的两个字母各算一个字符位置
// （`edited_storage_len` 里除 `V` / `P` / `S` 之外每字符 1 位），所以
// `9(5)CR` = 5 + 2 = **7** 字节 —— 与 IBM 的算法一致：IBM Enterprise
// COBOL 6.5.0《PICTURE clause》符号表写明
//
//   "The symbols CR and DB each occupy two character positions."
//
// 2026-11-21 之前 README:177 / API.md:173 把这句话写成了"插入字符
// `$ , . + - / B 0 CR DB *` 各占 1"，读起来像 `9(5)CR` 只有 6 字节。
// 结论：**存储布局是对的，错的只有文档措辞**。本文件把宽度写死成数字，
// 以后谁"顺手统一"成 6 字节都会在这里红。
//
// 附带锁一条 L1：编辑型字段仍然逐字节往返（FIDELITY §1 首行承诺）。

///|
fn cr_layout() -> RecordLayout raise ParseError {
  compile_layout(
    parse_copybook(
      "01 R.\n    05 A PIC 9(5)CR.\n    05 B PIC 9(5)DB.\n    05 C PIC 9(5)V9CR.\n    05 D PIC ZZ9CR.\n",
    ),
  )
}

///|
test "edited CR/DB occupy two character positions each" {
  let layout = cr_layout()
  // 7 + 7 + 8 + 5
  assert_eq(layout.byte_length, 27)
  assert_eq(layout.find("R.A").unwrap().byte_length, 7)
  assert_eq(layout.find("R.B").unwrap().byte_length, 7)
  assert_eq(layout.find("R.C").unwrap().byte_length, 8)
  assert_eq(layout.find("R.D").unwrap().byte_length, 5)
  // 偏移连续：CR/DB 若被算成 1 位，后面每个字段都会前移
  assert_eq(layout.find("R.B").unwrap().offset, 7)
  assert_eq(layout.find("R.C").unwrap().offset, 14)
  assert_eq(layout.find("R.D").unwrap().offset, 22)
}

///|
test "edited CR suffix bytes round-trip" {
  let layout = cr_layout()
  // "12345CR" / "12345  " / "12345.6CR"? 这里用两种后缀形态各一条记录
  let with_suffix = b"\xF1\xF2\xF3\xF4\xF5\xC3\xD9\xF1\xF2\xF3\xF4\xF5\x40\x40\xF1\xF2\xF3\xF4\xF5\xF6\xC3\xD9\x40\x40\x40\xC3\xD9"
  let row = decode_record(layout, with_suffix).unwrap()
  assert_eq(row.get("R.A").unwrap().to_display(), "12345CR")
  // 空白后缀被 trim 成纯数字文本，encode 再补回 0x40
  assert_eq(row.get("R.B").unwrap().to_display(), "12345")
  assert_eq(encode_record(layout, row).unwrap(), with_suffix)
  match roundtrip_check(layout, with_suffix) {
    Ok(None) => ()
    Ok(Some(at)) => fail("edited CR roundtrip mismatch at \{at}")
    Err(e) => fail("edited CR roundtrip error: \{e.to_display()}")
  }
}
