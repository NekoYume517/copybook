// 2026-11-17-b 审计（C1 的镜像缺口）：`check_layout_encode_bounds` 只校验
// `FieldLayout.byte_length`，而**数值类的实际写入宽度由 PIC 决定** ——
// `encode_zoned` / `encode_packed` / `encode_binary` 一律按 `pic.storage_digits`
// 算宽度，`encode_field` 的 National 分支按 `pic.digits * 2` 写。
//
// 于是「pic 声明的存储宽度 > byte_length」的手工布局绕过唯一那道区间守卫，
// `Writer::set`（`self.buf[offset] = …`，数组赋值）越界 **panic**：
//
//     FieldLayout{ offset: 0, byte_length: 1, pic: 9(8) DISPLAY }
//     encode_record(...) -> panic（encode_zoned 写 offset+0..7）
//
// 同一份「解得出、写不回」形态的公开遗留项（3 字节 COMP）也是这个根因：
// `pic.storage_digits = 5` 的宽度是 4，`byte_length = 3` 时写第 4 个字节就
// 越界（记录正好 3 字节时 panic；记录更长时**静默写脏后面的字段**）。
//
// 两个方向都要守：pic 比 byte_length 宽 → 必须显式 `FieldOutOfBounds`；
// 文本/编辑型的写入宽度恒等于 byte_length（`encode_text` 按 width 补空格），
// 它们的 pic 更宽**不能**被误伤。

///|
fn mpww_base() -> RecordLayout raise ParseError {
  compile_layout(parse_copybook("01 R.\n  05 A PIC X(1).\n"))
}

///|
fn mpww_numeric(
  storage : Int32,
  usage : Usage,
  sign_separate : Bool,
) -> PicClause {
  {
    category: Numeric,
    digits: storage,
    scale: 0,
    storage_digits: storage,
    signed: false,
    usage,
    sign_separate,
    sign_leading: false,
    justified_right: false,
    blank_when_zero: false,
    pic_text: "9(\{storage})",
  }
}

///|
fn mpww_layout(
  pic : PicClause,
  byte_length : Int32,
  record_length : Int32,
) -> RecordLayout raise ParseError {
  let base = mpww_base()
  let field = { ..base.fields[0], pic, byte_length, total_length: byte_length, }
  { ..base, byte_length: record_length, fields: [field], all_fields: [field], }
}

///|
fn mpww_expect_oob(layout : RecordLayout, what : String) -> Unit raise {
  match encode_record(layout, Map([])) {
    Err(FieldOutOfBounds(_, _, _)) => ()
    Err(e) => fail("\{what}: expected FieldOutOfBounds, got \{e.to_display()}")
    Ok(bs) =>
      fail("\{what}: expected FieldOutOfBounds, encoded \{bs.length()} byte(s)")
  }
}

///|
test "P1: a zoned PIC wider than byte_length must not panic on encode" {
  mpww_expect_oob(mpww_layout(mpww_numeric(8, Display, false), 1, 1), "zoned")
}

///|
test "P1: a packed PIC wider than byte_length must not panic on encode" {
  mpww_expect_oob(mpww_layout(mpww_numeric(8, Comp3, false), 1, 1), "packed")
}

///|
test "P1: a COMP PIC wider than byte_length must not panic on encode" {
  mpww_expect_oob(mpww_layout(mpww_numeric(9, Comp, false), 1, 1), "comp")
}

///|
test "P1: a separate-sign zoned PIC wider than byte_length must not panic" {
  // 符号字节让写入宽度再加 1：pic 9(2) + SEPARATE 是 3 字节，byte_length 2 就对不上。
  mpww_expect_oob(mpww_layout(mpww_numeric(2, Display, true), 2, 2), "sep")
}

///|
test "P1: a NATIONAL PIC wider than byte_length must not panic on encode" {
  let nat : PicClause = {
    category: National,
    digits: 4,
    scale: 0,
    storage_digits: 4,
    signed: false,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    justified_right: false,
    blank_when_zero: false,
    pic_text: "N(4)",
  }
  mpww_expect_oob(mpww_layout(nat, 2, 2), "national")
}

///|
test "P1: a wide record must not let the PIC overflow its slot silently" {
  // 记录足够长时不会 panic，第 4/8 个字节落到字段声明之外（静默污染）。
  mpww_expect_oob(
    mpww_layout(mpww_numeric(8, Display, false), 1, 16),
    "zoned-wide",
  )
  mpww_expect_oob(mpww_layout(mpww_numeric(9, Comp, false), 1, 16), "comp-wide")
}

///|
test "P1: the declared 3-byte COMP leftover is rejected, not silently widened" {
  // 公开遗留项（第十二轮 REPORT §4-3）声称「手工 3 字节 COMP 走显式 EncodeFailed」：
  // 实测是 panic（记录 3 字节）或写脏第 4 个字节（记录更长）。两者都必须变成
  // 显式的 `FieldOutOfBounds`。
  mpww_expect_oob(mpww_layout(mpww_numeric(5, Comp, false), 3, 3), "comp3byte")
  mpww_expect_oob(
    mpww_layout(mpww_numeric(5, Comp, false), 3, 8),
    "comp3byte-wide",
  )
}

///|
test "P1 reverse lock: a PIC that fits its byte_length still encodes" {
  // 不误伤面：宽度与 byte_length 一致的数值布局照旧；文本/编辑型的写入宽度
  // 恒为 byte_length（`encode_text` 按 width 补空格），pic 更宽也不该被拒。
  let ok_zoned = mpww_layout(mpww_numeric(8, Display, false), 8, 8)
  match encode_record(ok_zoned, Map([])) {
    Ok(bs) => assert_eq(bs.length(), 8)
    Err(e) => fail("zoned 8/8 must encode: \{e.to_display()}")
  }
  let ok_sep = mpww_layout(mpww_numeric(2, Display, true), 3, 3)
  match encode_record(ok_sep, Map([])) {
    Ok(bs) => assert_eq(bs.length(), 3)
    Err(e) =>
      fail("zoned 9(2) SEPARATE (3 bytes) must encode: \{e.to_display()}")
  }
  let ok_packed = mpww_layout(mpww_numeric(3, Comp3, false), 2, 2)
  match encode_record(ok_packed, Map([])) {
    Ok(bs) => assert_eq(bs.length(), 2)
    Err(e) => fail("COMP-3 9(3) (2 bytes) must encode: \{e.to_display()}")
  }
  // 文本项：pic 说 X(8)，byte_length 只有 1 —— 编码只写 1 字节，必须在。
  let base = mpww_base()
  let text_pic : PicClause = {
    category: Alphanumeric,
    digits: 8,
    scale: 0,
    storage_digits: 8,
    signed: false,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    justified_right: false,
    blank_when_zero: false,
    pic_text: "X(8)",
  }
  let text_field = {
    ..base.fields[0],
    pic: text_pic,
    byte_length: 1,
    total_length: 1,
  }
  let text_layout = {
    ..base,
    byte_length: 1,
    fields: [text_field],
    all_fields: [text_field],
  }
  match encode_record(text_layout, Map([])) {
    Ok(bs) => assert_eq(bs.length(), 1)
    Err(e) =>
      fail(
        "texted PIC X(8) in a 1-byte slot must still encode: \{e.to_display()}",
      )
  }
}
