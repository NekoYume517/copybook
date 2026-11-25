// 回归：非 UTF-8 的 copybook / JSONL 输入必须 exit 1，不能 abort。
//
// ## 缺陷形态
//
// `main.mbt` 的 `read_text_file` 旧实现用 `@fs.read_file_to_string`，它
// 对非法字节宽松解码：坏槽位留在 String 里（`length()` 算一个字符、
// `get_char()` 返回 `None`）。随后 `lexer.mbt` 的 `split_lines` 在
// `get_char(i).unwrap()` 上 `moonbit_panic`，进程以 `0xC0000409`
// （STATUS_STACK_BUFFER_OVERRUN，即 abort）退出：
//
//   $ copybook layout --copybook utf16.cpy    # 记事本「另存为 → Unicode」
//   PanicError
//       at moonbit_panic
//   exit = -1073740791
//
// `0xC0000409` 既不是 1（数据错误）也不是 2（用法错误）；脚本只会把它
// 当成「进程被系统杀了」，而且报错里连文件名都没有。
//
// ## 修复
//
// 两层：`utf8_input.mbt` 在字节层做 RFC 3629 结构校验，非法时给出
// **文件名 + 字节偏移 + 该另存成什么**；`lexer.mbt` 的 `split_lines`
// 也不再对坏槽位 `unwrap`（占位 U+FFFD，走正常的 ParseError）。

///|
test "UTF8: a UTF-16LE upload is named, not guessed" {
  let raw : Bytes = b"\xFF\xFE\x30\x00\x31\x00"
  match non_utf8_bom_name(raw) {
    Some(name) => assert_eq(name, "UTF-16LE")
    None => fail("UTF-16LE BOM must be recognised")
  }
}

///|
test "UTF8: a UTF-32LE BOM is not mis-read as UTF-16LE" {
  let raw : Bytes = b"\xFF\xFE\x00\x00"
  match non_utf8_bom_name(raw) {
    Some(name) => assert_eq(name, "UTF-32LE")
    None => fail("UTF-32LE BOM must be recognised")
  }
}

///|
test "UTF8: a lone surrogate encoding (ED A0 80) is rejected with an offset" {
  let raw : Bytes = b"01 R.\n\xED\xA0\x80\n"
  match validate_utf8(raw) {
    Err((off, why)) => {
      assert_eq(off, 6)
      assert_true(why.contains("continuation"))
    }
    Ok(_) => fail("ED A0 80 is a surrogate and must not pass UTF-8 validation")
  }
}

///|
test "UTF8: overlong encodings are rejected" {
  // C0 80 是 U+0000 的过长编码；合法的 U+0000 只写 00
  let raw : Bytes = b"\xC0\x80"
  match validate_utf8(raw) {
    Err((off, _why)) => assert_eq(off, 0)
    Ok(_) => fail("overlong C0 80 must not pass UTF-8 validation")
  }
}

///|
test "UTF8: a truncated sequence at end of file is rejected" {
  let raw : Bytes = b"01 R.\n\xE4\xB8"
  match validate_utf8(raw) {
    Err((off, why)) => {
      assert_eq(off, 6)
      assert_true(why.contains("truncated"))
    }
    Ok(_) => fail("a truncated 3-byte sequence must not pass UTF-8 validation")
  }
}

///|
test "UTF8: a 4-byte sequence above U+10FFFF is rejected" {
  // F4 90 80 80 = U+110000，超出 Unicode 上限
  let raw : Bytes = b"\xF4\x90\x80\x80"
  match validate_utf8(raw) {
    Err((off, _why)) => assert_eq(off, 0)
    Ok(_) => fail("U+110000 must not pass UTF-8 validation")
  }
}

///|
test "UTF8: plain ASCII and a 3-byte BMP char still validate" {
  let raw : Bytes = b"01 R.\n  05 A PIC X(2).\n\xE4\xB8\xAD\n"
  match validate_utf8(raw) {
    Ok(_) => ()
    Err((off, why)) => fail("valid UTF-8 rejected at \{off}: \{why}")
  }
}

///|
test "UTF8: a 4-byte astral char (emoji) still validates" {
  let raw : Bytes = b"01 R.\n\xF0\x9F\x92\xA9\n"
  match validate_utf8(raw) {
    Ok(_) => ()
    Err((off, why)) => fail("valid 4-byte UTF-8 rejected at \{off}: \{why}")
  }
}

///|
test "UTF8: a UTF-8 BOM alone is still valid UTF-8" {
  let raw : Bytes = b"\xEF\xBB\xBF01 R.\n"
  match validate_utf8(raw) {
    Ok(_) => ()
    Err((off, why)) =>
      fail("UTF-8 BOM (EF BB BF) must validate, got \{off}: \{why}")
  }
}
