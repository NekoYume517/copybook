// cp037 编码层测试
//
// 覆盖：
//   1. 硬性验收点（字母分区、数字区、空格、标点）
//   2. 全 256 项往返一致性
//   3. 越界与不可编码字符的显式行为
//   4. 整块编解码与 zoned decimal 相关的辅助判定

///|
/// 把字节值数组转成 "C1 40 F0" 这样便于 inspect 比对的十六进制串
fn hex_bytes(bs : Array[Int32]) -> String {
  let sb = StringBuilder()
  for i, b in bs {
    if i > 0 {
      sb.write_string(" ")
    }
    let h = b.to_string(radix=16).to_upper()
    if h.length() == 1 {
      sb.write_string("0")
    }
    sb.write_string(h)
  }
  sb.to_string()
}

///|
/// BytesView 逐字节转十六进制串
fn hex_view(bs : BytesView) -> String {
  let out : Array[Int32] = []
  for i = 0; i < bs.length(); i = i + 1 {
    out.push(bs[i].to_int())
  }
  hex_bytes(out)
}

///|
test "ebcdic: 大写字母按 16 字节跳区分段" {
  // A..I = C1..C9
  assert_eq(@src.ebcdic_to_unicode(0xC1), 0x41) // A
  assert_eq(@src.ebcdic_to_unicode(0xC2), 0x42) // B
  assert_eq(@src.ebcdic_to_unicode(0xC9), 0x49) // I
  // J..R = D1..D9 —— 注意 D 是 0xC4 而不是 0xD4
  assert_eq(@src.ebcdic_to_unicode(0xD1), 0x4A) // J
  assert_eq(@src.ebcdic_to_unicode(0xD9), 0x52) // R
  assert_eq(@src.ebcdic_to_unicode(0xC4), 0x44) // D 在 C 区，不在 D 区
  // S..Z = E2..E9 —— 0xE0/0xE1 是 \ 和 7，不是 S 的前一个
  assert_eq(@src.ebcdic_to_unicode(0xE2), 0x53) // S
  assert_eq(@src.ebcdic_to_unicode(0xE9), 0x5A) // Z
  assert_eq(@src.ebcdic_to_unicode(0xE0), 0x5C) // 反斜杠
}

///|
test "ebcdic: 小写字母三段分别落在 8x/9x/Ax" {
  assert_eq(@src.ebcdic_to_unicode(0x81), 0x61) // a
  assert_eq(@src.ebcdic_to_unicode(0x89), 0x69) // i
  assert_eq(@src.ebcdic_to_unicode(0x91), 0x6A) // j
  assert_eq(@src.ebcdic_to_unicode(0x99), 0x72) // r
  assert_eq(@src.ebcdic_to_unicode(0xA2), 0x73) // s
  assert_eq(@src.ebcdic_to_unicode(0xA9), 0x7A) // z
}

///|
test "ebcdic: 数字区在 F0..F9" {
  assert_eq(@src.ebcdic_to_unicode(0xF0), 0x30) // '0'
  assert_eq(@src.ebcdic_to_unicode(0xF5), 0x35) // '5'
  assert_eq(@src.ebcdic_to_unicode(0xF9), 0x39) // '9'
  // 反过来：ASCII '0' 是 0x30，但 EBCDIC 0x30 是 U+0090 控制符
  assert_eq(@src.ebcdic_to_unicode(0x30), 0x90)
}

///|
test "ebcdic: 空格是 0x40，不是 0x20" {
  assert_eq(@src.ebcdic_to_unicode(0x40), 0x20)
  assert_true(@src.is_ebcdic_space(0x40))
  assert_true(!@src.is_ebcdic_space(0x20))
  // EBCDIC 0x20 是 C1 控制符
  assert_eq(@src.ebcdic_to_unicode(0x20), 0x80)
}

///|
test "ebcdic: COBOL 里最常用的五个标点" {
  assert_eq(@src.ebcdic_to_unicode(0x6B), 0x2C) // , 逗号
  assert_eq(@src.ebcdic_to_unicode(0x4B), 0x2E) // . 句点
  assert_eq(@src.ebcdic_to_unicode(0x60), 0x2D) // - 连字符
  assert_eq(@src.ebcdic_to_unicode(0x4D), 0x28) // ( 左括号
  assert_eq(@src.ebcdic_to_unicode(0x5D), 0x29) // ) 右括号
}

///|
test "ebcdic: PIC 编辑字符所需的符号位" {
  // 编辑型 PIC 里会出现的 $ + - * / Z 之外的符号
  assert_eq(@src.ebcdic_to_unicode(0x5B), 0x24) // $
  assert_eq(@src.ebcdic_to_unicode(0x4E), 0x2B) // +
  assert_eq(@src.ebcdic_to_unicode(0x5C), 0x2A) // *
  assert_eq(@src.ebcdic_to_unicode(0x61), 0x2F) // /
  assert_eq(@src.ebcdic_to_unicode(0x7D), 0x27) // ' 单引号，VALUE 字面量用
  assert_eq(@src.ebcdic_to_unicode(0x7C), 0x40) // @
  assert_eq(@src.ebcdic_to_unicode(0x4A), 0xA2) // ¢（cp037 特有，非 ASCII）
}

///|
test "ebcdic: is_ebcdic_digit 边界" {
  assert_true(@src.is_ebcdic_digit(0xF0))
  assert_true(@src.is_ebcdic_digit(0xF9))
  assert_true(!@src.is_ebcdic_digit(0xEF))
  assert_true(!@src.is_ebcdic_digit(0xFA))
  // ASCII 数字不是 EBCDIC 数字，这是最容易搞混的一处
  assert_true(!@src.is_ebcdic_digit(0x30))
  assert_true(!@src.is_ebcdic_digit(0x39))
}

///|
test "ebcdic: 全 256 项正向映射无重复且无 U+FFFD" {
  // cp037 是单射：256 个字节对应 256 个互不相同的码点
  let seen : Map[Int32, Bool] = Map([])
  for b = 0; b < 256; b = b + 1 {
    let cp = @src.ebcdic_to_unicode(b)
    assert_true(cp != 0xFFFD)
    assert_true(!seen.get(cp).unwrap_or(false))
    seen[cp] = true
  }
  assert_eq(seen.length(), 256)
}

///|
test "ebcdic: 全 256 项往返一致" {
  // 验收硬指标：@src.unicode_to_ebcdic(@src.ebcdic_to_unicode(b)) == Some(b)
  let mut mismatches = 0
  for b = 0; b < 256; b = b + 1 {
    let cp = @src.ebcdic_to_unicode(b)
    match @src.unicode_to_ebcdic(cp) {
      Some(back) => if back != b { mismatches = mismatches + 1 }
      None => mismatches = mismatches + 1
    }
  }
  assert_eq(mismatches, 0)
}

///|
test "ebcdic: 越界字节返回 U+FFFD" {
  assert_eq(@src.ebcdic_to_unicode(-1), 0xFFFD)
  assert_eq(@src.ebcdic_to_unicode(256), 0xFFFD)
  assert_eq(@src.ebcdic_to_unicode(9999), 0xFFFD)
  assert_true(!@src.ebcdic_has_mapping(-1))
  assert_true(!@src.ebcdic_has_mapping(256))
}

///|
test "ebcdic: 不可编码的码点返回 None" {
  // 中文不在 cp037 表中
  assert_true(@src.unicode_to_ebcdic(0x4E2D) is None)
  // 但 'A' 在
  assert_eq(@src.unicode_to_ebcdic(0x41), Some(0xC1))
  // U+00A0（不换行空格）在 cp037 的 0x41 位置
  assert_eq(@src.unicode_to_ebcdic(0xA0), Some(0x41))
}

///|
test "ebcdic: 整块解码" {
  // "AB 01" 的 EBCDIC 表示
  let bs = b"\xC1\xC2\x40\xF0\xF1"
  assert_eq(@src.ebcdic_decode(bs), "AB 01")
}

///|
test "ebcdic: 整块编码" {
  let bs = @src.ebcdic_encode("AB 01")
  assert_eq(hex_view(bs), "C1 C2 40 F0 F1")
}

///|
test "ebcdic: 整块往返（解码后再编码逐字节相同）" {
  // 用全部 256 个字节构造，避开 String 无法表示的孤立代理项（cp037 没有）
  let src : Array[Byte] = []
  for b = 0; b < 256; b = b + 1 {
    src.push(b.to_byte())
  }
  let view = Bytes::from_array(src)
  let text = @src.ebcdic_decode(view)
  let back = @src.ebcdic_encode(text)
  assert_eq(hex_view(back), hex_view(view))
}

///|
test "ebcdic: 含中文的字符串编码时替换为 0x6F" {
  let bs = @src.ebcdic_encode("A中B")
  assert_eq(hex_view(bs), "C1 6F C2")
}

///|
test "ebcdic: strict 编码遇不可表示字符返回 None" {
  assert_true(@src.ebcdic_encode_strict("A中B") is None)
  match @src.ebcdic_encode_strict("ABC") {
    Some(v) => assert_eq(hex_bytes(v), "C1 C2 C3")
    None => fail("ABC 应当可编码")
  }
}

///|
test "ebcdic: printable 判定区分控制符与字母" {
  // 0x00..0x3F 全是 C0 控制符
  assert_true(!@src.ebcdic_is_printable(0x00))
  assert_true(!@src.ebcdic_is_printable(0x25)) // LF
  // 0x40 空格算可打印
  assert_true(@src.ebcdic_is_printable(0x40))
  // 字母、数字
  assert_true(@src.ebcdic_is_printable(0xC1))
  assert_true(@src.ebcdic_is_printable(0xF0))
  // 0xCA 是软连字符（不可见），不算可打印
  assert_true(!@src.ebcdic_is_printable(0xCA))
  // 0xFF 映射到 C1 控制符 U+009F
  assert_true(!@src.ebcdic_is_printable(0xFF))
}

///|
test "ebcdic: Char 版本与 Int 版本一致" {
  let c = @src.ebcdic_char_to_unicode(0xC1)
  assert_eq(c.to_int(), 65)
  assert_eq(@src.unicode_char_to_ebcdic(c), Some(0xC1))
}
