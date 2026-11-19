// 2026-11-17-b 审计：`unsigned zoned decimal has negative sign` 的定位指错字节。
//
// `decode_zoned` 的判定分支用 `sign_leading` 决定**符号半字节**落在首字节还是
// 末字节，但报错那一处恒写 `base_offset + n - 1` 与 `digit_bytes[dn - 1]`。
// 于是 SIGN 子句声明符号在前时，进程报的是最后一个数字字节：
//
//     05 A PIC 9(3) SIGN IS LEADING.   喂 D1 F2 F3
//     -> invalid numeric at offset 2: ... (byte 0xF3)
//        真正越界的是 offset 0 的 0xD1（0xF3 是完全合法的 F 区号）
//
// 同一条不对称也出现在 `SIGN ... SEPARATE` 的 LEADING 形态上（符号字节在
// offset 0）。EBCDIC 逐字节定位是 `DecodeError::InvalidNumeric` 唯一的用处
// （打开十六进制编辑器按偏移找位置），指错等于没有。

///|
fn zseo_decode(src : String, bytes : Array[Int32]) -> String raise ParseError {
  let layout = compile_layout(parse_copybook(src))
  let bs : Array[Byte] = []
  for v in bytes {
    bs.push(v.to_byte())
  }
  match decode_record(layout, Bytes::from_array(bs)) {
    Ok(_) => "OK"
    Err(e) => e.to_display()
  }
}

///|
fn zseo_manual(
  sign_leading : Bool,
  separate : Bool,
  bytes : Array[Int32],
) -> String {
  let base = try
    compile_layout(parse_copybook("01 R.\n  05 A PIC S9(3).\n"))
  catch {
    _ => return "base layout failed"
  } noraise {
    l => l
  }
  let pic : PicClause = {
    ..base.fields[0].pic,
    signed: false,
    sign_separate: separate,
    sign_leading,
  }
  let field = {
    ..base.fields[0],
    pic,
    byte_length: bytes.length(),
    total_length: bytes.length(),
  }
  let layout = {
    ..base,
    byte_length: bytes.length(),
    fields: [field],
    all_fields: [field],
  }
  let bs : Array[Byte] = []
  for v in bytes {
    bs.push(v.to_byte())
  }
  match decode_record(layout, Bytes::from_array(bs)) {
    Ok(_) => "OK"
    Err(e) => e.to_display()
  }
}

///|
test "zoned: an embedded LEADING sign points at the first byte" {
  let msg = zseo_decode("01 R.\n  05 A PIC 9(3) SIGN IS LEADING.\n", [
    0xD1, 0xF2, 0xF3,
  ])
  assert_true(msg.contains("offset 0"))
  assert_true(msg.contains("0xD1"))
}

///|
test "zoned reverse lock: a TRAILING sign still points at the last byte" {
  let msg = zseo_decode("01 R.\n  05 A PIC 9(3).\n", [0xF1, 0xF2, 0xD3])
  assert_true(msg.contains("offset 2"))
  assert_true(msg.contains("0xD3"))
}

///|
test "zoned: a separate LEADING sign byte points at offset 0" {
  let msg = zseo_manual(true, true, [0x60, 0xF1, 0xF2, 0xF3])
  assert_true(msg.contains("offset 0"))
  assert_true(msg.contains("0x60"))
}

///|
test "zoned reverse lock: a separate TRAILING sign byte still points at the end" {
  let msg = zseo_manual(false, true, [0xF1, 0xF2, 0xF3, 0x60])
  assert_true(msg.contains("offset 3"))
  assert_true(msg.contains("0x60"))
}

///|
test "zoned: separate LEADING digit errors skip the sign byte offset" {
  let msg = zseo_manual(true, true, [0x4E, 0xF1, 0xFA, 0xF3])
  assert_true(msg.contains("offset 2"))
  assert_true(msg.contains("0xFA"))
}

///|
test "zoned reverse lock: separate TRAILING digit offsets stay unchanged" {
  let msg = zseo_manual(false, true, [0xF1, 0xFA, 0xF3, 0x4E])
  assert_true(msg.contains("offset 1"))
  assert_true(msg.contains("0xFA"))
}
