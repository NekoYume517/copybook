// UTF-8 输入的合法性校验（2026-11-26 审计，P0）。
//
// ## 为什么需要这一层
//
// `@fs.read_file_to_string` 对非法字节是**宽松**解码：坏槽位留在 String
// 里（`length()` 算它一个字符，`get_char()` 返回 `None`）。于是
//
//   - copybook 侧：`lexer.mbt` 的 `split_lines` 在 `get_char(i).unwrap()`
//     上 panic，进程以 `0xC0000409`（abort）退出；
//   - JSONL 侧：`String::split` 之后的行里带着坏槽位，报错信息是
//     看不懂的 `invalid JSON`。
//
// 两种都不是契约里的 0/1/2。最容易撞上的是 Windows 记事本
// 「另存为 → Unicode」产出的 UTF-16LE，或某些工具写出的孤立代理项
// `ED A0 80`。
//
// 这里在**字节层**先做一遍 RFC 3629 结构校验：非法就给带偏移的说明，
// 合法才交给 core 解码（此时它不会 panic）。

///|
/// UTF-8 合法性校验：返回第一个非法字节的偏移与原因。
///
/// 只做结构校验（RFC 3629：不允许多字节过长编码、不接受代理项码点、
/// 不接受 > U+10FFFF），不返回解码结果 —— 解码仍交给 core。
fn validate_utf8(b : Bytes) -> Result[Unit, (Int32, String)] {
  let n = b.length()
  let mut i = 0
  while i < n {
    let c = b[i].to_int() & 0xFF
    if c < 0x80 {
      i = i + 1
      continue
    }
    let (need, lo, hi) = if c >= 0xC2 && c <= 0xDF {
      (1, 0x80, 0xBF)
    } else if c == 0xE0 {
      (2, 0xA0, 0xBF)
    } else if c >= 0xE1 && c <= 0xEC {
      (2, 0x80, 0xBF)
    } else if c == 0xED {
      // 排除代理项 U+D800..U+DFFF（UTF-8 里它们是非法的）
      (2, 0x80, 0x9F)
    } else if c >= 0xEE && c <= 0xEF {
      (2, 0x80, 0xBF)
    } else if c == 0xF0 {
      (3, 0x90, 0xBF)
    } else if c >= 0xF1 && c <= 0xF3 {
      (3, 0x80, 0xBF)
    } else if c == 0xF4 {
      (3, 0x80, 0x8F)
    } else {
      return Err((i, "invalid UTF-8 lead byte 0x\{hex2(c)}"))
    }
    if i + need >= n {
      return Err((i, "truncated UTF-8 sequence at end of file"))
    }
    let b1 = b[i + 1].to_int() & 0xFF
    if b1 < lo || b1 > hi {
      return Err(
        (
          i,
          "invalid UTF-8 continuation byte 0x\{hex2(b1)} in a \{need + 1}-byte sequence",
        ),
      )
    }
    let mut k = 2
    while k <= need {
      let bk = b[i + k].to_int() & 0xFF
      if bk < 0x80 || bk > 0xBF {
        return Err(
          (
            i,
            "invalid UTF-8 continuation byte 0x\{hex2(bk)} in a \{need + 1}-byte sequence",
          ),
        )
      }
      k = k + 1
    }
    i = i + need + 1
  }
  Ok(())
}

///|
fn hex2(v : Int32) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  sb.write_char(digits.get_char((v >> 4) & 0xF).unwrap())
  sb.write_char(digits.get_char(v & 0xF).unwrap())
  sb.to_string()
}

///|
/// 该字节串是否以 UTF-16 / UTF-32 的 BOM 开头（给「另存为 Unicode」一条明路）。
///
/// UTF-32LE 必须先判：它的 BOM 是 `FF FE 00 00`，前两字节与 UTF-16LE 相同。
fn non_utf8_bom_name(b : Bytes) -> String? {
  let n = b.length()
  if n >= 4 {
    let a = b[0].to_int() & 0xFF
    let c = b[1].to_int() & 0xFF
    let d = b[2].to_int() & 0xFF
    let e = b[3].to_int() & 0xFF
    if a == 0xFF && c == 0xFE && d == 0 && e == 0 {
      return Some("UTF-32LE")
    }
    if a == 0 && c == 0 && d == 0xFE && e == 0xFF {
      return Some("UTF-32BE")
    }
  }
  if n >= 2 {
    let a = b[0].to_int() & 0xFF
    let c = b[1].to_int() & 0xFF
    if a == 0xFF && c == 0xFE {
      return Some("UTF-16LE")
    }
    if a == 0xFE && c == 0xFF {
      return Some("UTF-16BE")
    }
  }
  None
}
