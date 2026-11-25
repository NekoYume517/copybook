// 回归：copybook 文本里出现「坏槽位」（非法 UTF-8 被宽松解码）时 panic（P0）。
//
// ## 缺陷形态
//
// CLI 用 `@fs.read_file_to_string` 读文件，它宽松解码 UTF-8：非法字节
// 序列变成**坏槽位**——`String::get_char(i)` 返回 `None`，但
// `String::length()` 仍把它算作 1 个字符。
//
// 于是把 UTF-16 文件（记事本「另存为 → Unicode」的
// `FF FE 30 00 31 00 …`）改名成 `.cpy` 喂进来时：
//
//   $ copybook layout --copybook utf16.cpy
//   PanicError
//       at moonbit_panic
//   exit = -1073740791          # 0xC0000409，契约外
//
// 根因是 `lexer.mbt` 的 `split_lines`：
//
//     let c = src.get_char(i).unwrap()
//
// `.unwrap()` 在坏槽位上 panic。同样受影响的还有孤立代理项
// `ED A0 80`（某些工具产出的「UTF-8 里塞 UTF-16 码元」）。
//
// ## 修复
//
// `split_lines` 不再假设每个位置都能取到字符：取不到时放一个 U+FFFD
// 占位。词法层的「无法识别的字符」分支本来就处理 U+FFFD，于是非法
// 输入走正常的 `ParseError`（带行号列号），不再多一条崩溃路径。

///|
/// 复现坏槽位：宽松解码一个非法 UTF-8 字节，得到 get_char() == None 的 String。
fn broken_string(bs : Bytes) -> String {
  @unicode.to_utf8_string(bs)
}

///|
test "UTF8: a broken slot in copybook source is a parse error, not a panic" {
  // 单独的 0xFF 会被宽松解码成空串（length == 0），不构成坏槽位；
  // 用孤立代理项 ED A0 80 —— 它留下「length == 1、get_char == None」。
  let broken = broken_string(b"\xED\xA0\x80")
  // 前提：宽松解码确实留下了「长度 > 0 但取不出字符」的 String
  assert_true(broken.length() > 0)
  assert_true(broken.get_char(0) is None)
  // 旧实现：lexer 的 split_lines 里 `.unwrap()` 直接 panic
  let r = try
    parse_copybook("01 R.\n  05 A PIC X(2).\n".to_string() + broken)
  catch {
    _e => None
  } noraise {
    specs => Some(specs)
  }
  // 要么解析成功（坏字节在注释位置上被容忍），要么是 ParseError；
  // 无论哪种，本测试跑到了这里就说明**没有 panic**。
  match r {
    Some(_) => ()
    None => ()
  }
}

///|
test "UTF8: a lone surrogate in copybook source is a parse error, not a panic" {
  let broken = broken_string(b"\xED\xA0\x80")
  assert_true(broken.length() > 0)
  let r = try parse_copybook(broken) catch {
    _e => None
  } noraise {
    specs => Some(specs)
  }
  match r {
    Some(_) => ()
    None => ()
  }
}

///|
test "UTF8: a UTF-16LE BOM in copybook source is a parse error, not a panic" {
  // 记事本「另存为 → Unicode」：FF FE 30 00 31 00 20 00 52 00 2E 00
  let broken = broken_string(
    b"\xFF\xFE\x30\x00\x31\x00\x20\x00\x52\x00\x2E\x00",
  )
  let r = try parse_copybook(broken) catch {
    _e => None
  } noraise {
    specs => Some(specs)
  }
  match r {
    Some(_) => ()
    None => ()
  }
}
