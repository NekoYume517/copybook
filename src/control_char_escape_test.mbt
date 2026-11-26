// CB-19-3（2026-11-27 审计）：错误消息把用户输入里的控制字符原样回显到 stderr。
//
// ## 缺陷形态（修复前）
//
//     01 R.
//        05 A PIC X<ESC>(2).
//
// exit 1，stderr 是（逐字节）：
//
//     ... PIC 模式串中出现非法字符 '<0x1B>' \r\n
//
// `0x1B` 是 ESC，`0x07` 是 BEL，`0x7F` 是 DEL —— 都是**原始控制字节**：
//
//   $ copybook layout --copybook esc.cpy 2>&1 | cat -v
//     ... 非法字符 '^['          # 终端收到 ESC，后续字符被它吞掉
//
// BEL 会让终端响铃、DEL 会删掉前一个字符，ESC 后的 `'` 与 `\r\n` 被当成
// 转义序列的一部分 —— 用户看到的不是「哪个字符非法」，而是一行乱码。
// 若这些字节被重定向进日志/CI 输出，控制序列还会污染整份日志。
//
// ## 为什么必须净化
//
// 错误消息是给**人**读的诊断输出，其中回显的**用户输入**是不可信数据。
// 把 `0x00`-`0x1F` 与 `0x7F` 原样写进 stdout/stderr 是「终端注入」：
// 同一份 copybook 在 `cat` 下正常、在终端里会擦掉/隐藏本行内容。
// 本项目的诊断格式已是「路径:行:列: 原因」，原因里的片段必须可打印。
//
// 修法：错误消息回显的字符统一过一次 `escape_control_for_message`，
// 控制字符写成 `\xNN`（C 风格转义）。可打印字符（含中文、制表符以外的
// 全角）原样保留 —— 净化只针对控制字符，不改既有消息文本。
//
// 覆盖 4 处内插点（本轮审计 grep 全量确认）：
//   lexer.mbt    "无法识别的字符 '{c}'"
//   lexer.mbt    "PIC 模式串中出现非法字符 '{ch}'"
//   parser.mbt   "PIC '{text}' 里出现非法字符 '{other}'"   ×2

///|
/// 触发一个错误，把消息拿回来。
fn san_err(cb : String) -> String {
  try {
    let _ = compile_layout(parse_copybook(cb))
    "ok"
  } catch {
    e => e.to_display()
  } noraise {
    _ => "ok"
  }
}

///|
/// 消息里不应出现任何 C0 控制字符或 DEL。
fn assert_printable(msg : String, what : String) -> Unit raise {
  for ch in msg {
    let c = ch.to_int()
    if c < 0x20 || c == 0x7F {
      fail("\{what}: error message leaks raw control byte \{c}: \{msg}")
    }
  }
}

///|
/// 缺陷本体：ESC 出现在语句层面 → 消息里必须是 `\x1b`，不是原始 ESC。
test "CB-19-3: 词法错误里的 ESC 被转义而非原样回显" {
  let msg = san_err("01 R.\n    05 A PIC X(2).\n    05 \u{1B} PIC X(2).\n")
  assert_true(msg != "ok")
  assert_printable(msg, "lexer ESC")
  assert_true(msg.contains("\\x1b"))
}

///|
/// BEL 与 DEL 同族。
test "CB-19-3: 词法错误里的 BEL / DEL 被转义" {
  let bel = san_err("01 R.\n    05 A PIC X(2).\n    05 \u{7} PIC X(2).\n")
  assert_printable(bel, "lexer BEL")
  assert_true(bel.contains("\\x07"))
  let del = san_err("01 R.\n    05 A PIC X(2).\n    05 \u{7F} PIC X(2).\n")
  assert_printable(del, "lexer DEL")
  assert_true(del.contains("\\x7f"))
}

///|
/// PIC 模式串里的控制字符（第二条内插点）。
test "CB-19-3: PIC 模式串里的控制字符被转义" {
  let msg = san_err("01 R.\n    05 A PIC X\u{1B}(2).\n")
  assert_true(msg != "ok")
  assert_printable(msg, "pic pattern")
  assert_true(msg.contains("\\x1b"))
}

///|
/// 对照：可打印字符照旧原样回显（不能把中文/标点写成转义）。
test "CB-19-3: 可打印字符的既有回显不变" {
  let msg = san_err("01 R.\n    05 A PIC X(2).\n    05 , PIC X(2).\n")
  assert_true(msg != "ok")
  assert_true(msg.contains("','"))
}

///|
/// 对照：正常 copybook 不受影响。
test "CB-19-3: 合法 copybook 仍解析成功" {
  assert_eq(san_err("01 R.\n    05 A PIC X(2).\n"), "ok")
}
