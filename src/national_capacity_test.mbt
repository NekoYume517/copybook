// `PIC N(n)` 的容量单位是 **UTF-16 码元**，不是字符数。
//
// 背景（CB-6）：实现在这一点的行为是对的（容量按码元数校验，补充平面字符
// 占 2 码元，放不下就报错不截断），但 README / API 的说法没写清「n 是码元数」，
// 读者容易以为 `PIC N(1)` 能存一个 emoji。
//
// 本文件把行为锁死，避免文档与实现再次分叉：emoji 在 `N(1)` 报错、在 `N(2)`
// 通过并写成 UTF-16BE 代理对。

///|
/// 编译单字段 NATIONAL 布局。
fn nat_layout(pic_text : String) -> RecordLayout raise {
  compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic_text}.\n"))
}

///|
test "PIC N(n)：emoji 在 N(1) 报错、在 N(2) 通过（CB-6）" {
  // U+1F600 在 UTF-16 里是两个码元（D83D DE00），因此占 4 字节
  let emoji = "\u{1F600}"
  // N(1) 只有 2 个码元容量（4 字节里的 2 字节）——放不下，必须报错而不是截断
  let narrow = nat_layout("N(1)")
  assert_eq(narrow.byte_length, 2)
  let row : Map[String, CellValue] = Map([])
  row["R.A"] = Text(emoji)
  match encode_record(narrow, row) {
    Ok(_) => fail("emoji must not fit PIC N(1) (n is UTF-16 code units)")
    Err(InvalidNumeric(_, message)) => {
      assert_true(message.contains("code-unit"))
      assert_true(message.contains("NATIONAL"))
    }
    Err(e) => fail("expected InvalidNumeric, got " + e.to_display())
  }
  // N(2) 够，且写成代理对的 4 字节 UTF-16BE
  let wide = nat_layout("N(2)")
  assert_eq(wide.byte_length, 4)
  let bytes = encode_record(wide, row).unwrap()
  assert_eq(bytes, b"\xD8\x3D\xDE\x00")
  // 解码回同一个字符
  match decode_record(wide, bytes) {
    Ok(m) =>
      match m.get("R.A") {
        Some(Text(s)) => assert_eq(s, emoji)
        Some(other) => fail("expected Text, got " + other.to_display())
        None => fail("missing R.A")
      }
    Err(e) => fail("decode failed: " + e.to_display())
  }
}
