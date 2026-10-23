// COMP 二进制字段的**十进制容量**必须在 decode 与 encode 两侧对称强制。
//
// 背景（CB-1）：`PIC S9(4) COMP` 占 2 字节，二进制容器能装 -32768..32767，
// 但 COBOL 字段的语义是「最多 4 位十进制数」。encode 一侧早已按
// `storage_digits` 设容量上限（issue #28 的契约：**声明的十进制容量是权威**），
// decode 一侧却只校验宽度与无符号符号位 —— 同一份 `7F FF`：
//
//   copybook decode  → 成功，输出 32767
//   copybook verify  → 失败：value 32767 exceeds 4 decimal digits
//
// 两个方向对同一段字节给出互相矛盾的结论，说明单边修补漏了一侧。
// 这里锁定「decode 也拒绝」，并锁定合法边界不受影响。

///|
/// 编译单字段 COMP 布局。
fn comp_layout(pic_text : String) -> RecordLayout raise {
  compile_layout(parse_copybook("01 R.\n  05 A PIC \{pic_text}.\n"))
}

///|
/// 取出唯一的解码值（断言成功）。
fn comp_decode(layout : RecordLayout, rec : Bytes) -> CellValue raise {
  match decode_record(layout, rec.exact_view()) {
    Ok(m) =>
      match m.get("R.A") {
        Some(v) => v
        None => fail("missing R.A")
      }
    Err(e) => fail("decode must succeed: " + e.to_display())
  }
}

///|
test "COMP 解码：超出 PIC 声明容量的补码与 encode 一样被拒绝（CB-1）" {
  // (PIC, 字节, 期望消息里的容量上限)
  let cases : Array[(String, Bytes, String)] = [
    // S9(4)：2 字节容器，声明容量 9999
    ("S9(4) COMP", b"\x7F\xFF", "9999"),
    ("S9(4) COMP", b"\x80\x00", "9999"),
    // 9(4)：无符号 2 字节容得下 65535，但声明容量仍是 9999
    ("9(4) COMP", b"\xFF\xFF", "9999"),
    // S9(9)：4 字节容器，声明容量 999999999
    ("S9(9) COMP", b"\x7F\xFF\xFF\xFF", "999999999"),
    ("S9(9) COMP", b"\x80\x00\x00\x00", "999999999"),
  ]
  for (pic_text, rec, limit_text) in cases {
    let layout = comp_layout(pic_text)
    match decode_record(layout, rec.exact_view()) {
      Ok(_) => fail("\{pic_text} \{rec} must be rejected by decode")
      Err(InvalidNumeric(_, message)) => {
        assert_true(message.contains(limit_text))
        // 消息要指向「PIC 声明的十进制容量」，与 encode 侧同一套说法，
        // 而不是「二进制容器溢出」。
        assert_true(message.contains("decimal digits"))
      }
      Err(e) => fail("expected InvalidNumeric, got " + e.to_display())
    }
  }
}

///|
test "COMP 解码：encode 拒绝的值 decode 也拒绝（两侧同一判定）" {
  // 任一侧单独校验都会让「decode 成功但 verify 失败」，这里直接对拍两个方向。
  let cases : Array[(String, Bytes)] = [
    ("S9(4) COMP", b"\x7F\xFF"),
    ("S9(4) COMP", b"\x80\x00"),
    ("9(4) COMP", b"\xFF\xFF"),
    ("S9(9) COMP", b"\x7F\xFF\xFF\xFF"),
  ]
  for (pic_text, rec) in cases {
    let layout = comp_layout(pic_text)
    let decoded = decode_record(layout, rec.exact_view())
    let verified = roundtrip_check(layout, rec.exact_view())
    match decoded {
      Err(InvalidNumeric(_, dmsg)) =>
        match verified {
          // verify 走 decode→encode：decode 已拒绝，就不该再说「字节一致」
          Ok(_) => fail("verify must not report a roundtrip on rejected input")
          Err(InvalidNumeric(_, vmsg)) => assert_eq(vmsg, dmsg)
          Err(e) => fail("unexpected verify error: " + e.to_display())
        }
      _ => fail("\{pic_text} \{rec} must be rejected by decode")
    }
  }
}

///|
test "COMP 解码：合法十进制边界照常解码并逐字节往返（CB-1 回归护栏）" {
  // (PIC, 字节, 期望的数值文本)
  let cases : Array[(String, Bytes, String)] = [
    ("S9(4) COMP", b"\x27\x0F", "9999"),
    ("S9(4) COMP", b"\xD8\xF1", "-9999"),
    ("S9(4) COMP", b"\x00\x00", "0"),
    ("S9(9) COMP", b"\x3B\x9A\xC9\xFF", "999999999"),
    ("S9(9) COMP", b"\xC4\x65\x36\x01", "-999999999"),
    // 18 位边界：8 字节补码能装 2^63-1，但声明容量只有 10^18-1
    ("S9(18) COMP", b"\x0D\xE0\xB6\xB3\xA7\x63\xFF\xFF", "999999999999999999"),
  ]
  for (pic_text, rec, expected) in cases {
    let layout = comp_layout(pic_text)
    match comp_decode(layout, rec) {
      Decimal(d) => assert_eq(d.to_string(), expected)
      other => fail("expected Decimal, got \{other.to_display()}")
    }
    // 逐字节往返：decode 出的值再 encode 必须复原同样的字节
    match roundtrip_check(layout, rec.exact_view()) {
      Ok(mismatch) =>
        match mismatch {
          None => ()
          Some(off) => fail("\{pic_text} \{rec} byte mismatch at \{off}")
        }
      Err(e) => fail("\{pic_text} \{rec} must roundtrip: " + e.to_display())
    }
  }
}
