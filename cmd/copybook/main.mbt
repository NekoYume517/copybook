// CLI —— copybook 命令行工具
//
// 四个子命令：
//   copybook layout --copybook <file.cpy>
//   copybook decode --copybook <file.cpy> --data <file.dat> [--format jsonl|table] [--record-length N]
//   copybook encode --copybook <file.cpy> --json <file.jsonl> --out <file.dat>
//   copybook verify --copybook <file.cpy> --data <file.dat>
//
// 退出码：0 成功 / 1 数据错误 / 2 用法错误
//
// 参数解析手写（不引入 argparse）：四个子命令的参数集很小，手写更可控，
// 也避免把 `--record-length` 这类项目特有语义硬塞进通用解析器。

///|
/// 退出码常量
const EXIT_OK : Int32 = 0

///|
const EXIT_DATA : Int32 = 1

///|
const EXIT_USAGE : Int32 = 2

///|
/// 用法说明（打印到 stderr）
fn usage_text() -> String {
  let sb = StringBuilder()
  sb.write_string("copybook — COBOL copybook 编解码工具\n\n")
  sb.write_string("用法:\n")
  sb.write_string("  copybook layout --copybook <file.cpy>\n")
  sb.write_string(
    "  copybook decode --copybook <file.cpy> --data <file.dat> [--format jsonl|table] [--record-length N]\n",
  )
  sb.write_string(
    "  copybook encode --copybook <file.cpy> --json <file.jsonl> --out <file.dat>\n",
  )
  sb.write_string("  copybook verify --copybook <file.cpy> --data <file.dat>\n")
  sb.write_string("\n全局选项:\n")
  sb.write_string(
    "  --float-mode hfp|ieee  COMP-1/COMP-2 的字节解释方式（默认 hfp）\n",
  )
  sb.write_string(
    "                         hfp  = IBM z/OS 主机十六进制浮点（base-16 指数）\n",
  )
  sb.write_string(
    "                         ieee = IEEE 754 binary32/binary64（GnuCOBOL/x86）\n",
  )
  sb.write_string(
    "                         两者字节布局互不兼容，必须先确定数据源属于哪一种\n",
  )
  sb.write_string("\n退出码: 0 成功 / 1 数据错误 / 2 用法错误\n")
  sb.to_string()
}

///|
/// 解析后的命令行选项。
priv struct Options {
  mut copybook : String?
  mut data : String?
  mut json : String?
  mut out : String?
  mut format : String
  mut record_length : Int32?
  /// COMP-1 / COMP-2 的字节解释方式（`hfp` 默认 / `ieee`）。
  ///
  /// 这不是"精度选项"，而是**数据源属性**：IBM z/OS 写 HFP、
  /// GnuCOBOL / Micro Focus 写 IEEE 754，同一份 copybook 两种字节布局完全
  /// 互不兼容。默认 `hfp`（本项目目标平台）。见 `--float-mode`。
  mut float_mode : @lib.FloatMode
}

///|
/// 逐个 token 解析 `--key value` 形式。
///
/// 支持 `--key=value` 与 `--key value` 两种写法（后者更常见于手敲）。
/// 未知选项直接报错 —— 静默忽略会让 "打错一个字就用了默认值" 变得不可见。
fn parse_options(args : ArrayView[String]) -> Result[Options, String] {
  let opts : Options = {
    copybook: None,
    data: None,
    json: None,
    out: None,
    format: "jsonl",
    record_length: None,
    float_mode: @lib.Hfp,
  }
  let mut i = 0
  let n = args.length()
  while i < n {
    let tok = args[i]
    // 拆 --key=value
    let mut key = tok
    let mut inline_value : String? = None
    match tok.find("=") {
      Some(eq) => {
        key = tok[:eq].to_owned()
        inline_value = Some(tok[eq + 1:].to_owned())
      }
      None => ()
    }
    // 取值辅助：有 inline 用 inline，否则吃下一个 token
    let take_value = fn() -> Result[String, String] {
      match inline_value {
        Some(v) => Ok(v)
        None =>
          if i + 1 >= n {
            Err("option \{key} requires a value")
          } else {
            i = i + 1
            Ok(args[i])
          }
      }
    }
    match key {
      "--copybook" =>
        match take_value() {
          Ok(v) => opts.copybook = Some(v)
          Err(e) => return Err(e)
        }
      "--data" =>
        match take_value() {
          Ok(v) => opts.data = Some(v)
          Err(e) => return Err(e)
        }
      "--json" =>
        match take_value() {
          Ok(v) => opts.json = Some(v)
          Err(e) => return Err(e)
        }
      "--out" =>
        match take_value() {
          Ok(v) => opts.out = Some(v)
          Err(e) => return Err(e)
        }
      "--format" =>
        match take_value() {
          Ok(v) => opts.format = v
          Err(e) => return Err(e)
        }
      "--record-length" =>
        match take_value() {
          Ok(v) =>
            match parse_positive_int(v) {
              Some(n) => opts.record_length = Some(n)
              None =>
                return Err(
                  "--record-length expects a positive integer, got '\{v}'",
                )
            }
          Err(e) => return Err(e)
        }
      "--float-mode" =>
        match take_value() {
          Ok(v) =>
            match v.to_lower() {
              "hfp" | "ibm" | "hex" => opts.float_mode = @lib.Hfp
              "ieee" | "ieee754" | "binary" => opts.float_mode = @lib.Ieee754
              other =>
                return Err(
                  "--float-mode expects 'hfp' (IBM 主机, 默认) or 'ieee' (GnuCOBOL/x86), got '\{other}'",
                )
            }
          Err(e) => return Err(e)
        }
      _ => return Err("unknown option '\{key}'")
    }
    i = i + 1
  }
  Ok(opts)
}

///|
/// 解析正整数（只用 ASCII 数字，拒绝空串/负数/杂字符）。
fn parse_positive_int(s : StringView) -> Int32? {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut v = 0
  for i = 0; i < n; i = i + 1 {
    let c = s[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  if v <= 0 {
    None
  } else {
    Some(v)
  }
}

///|
/// 从文件读 copybook 并编译布局。
fn load_layout(
  path : String,
  float_mode : @lib.FloatMode,
) -> Result[@lib.RecordLayout, String] {
  let text = match read_text_file(path) {
    Some(t) => t
    None => return Err("cannot read copybook '\{path}'")
  }
  let specs = match compile_specs(text) {
    Ok(s) => s
    Err(msg) => return Err("copybook parse error: \{msg}")
  }
  match try_compile(specs, float_mode) {
    Ok(l) => Ok(l)
    Err(msg) => Err("layout error: \{msg}")
  }
}

///|
/// 分隔 try 的边界：@lib.parse_copybook raise @lib.ParseError
fn compile_specs(text : String) -> Result[Array[@lib.FieldSpec], String] {
  match try_parse(text) {
    Ok(s) => Ok(s)
    Err(msg) => Err(msg)
  }
}

///|
fn try_parse(text : String) -> Result[Array[@lib.FieldSpec], String] {
  let r : Result[Array[@lib.FieldSpec], @lib.ParseError] = try_parse_raw(text)
  match r {
    Ok(s) => Ok(s)
    Err(e) => Err(e.to_display())
  }
}

///|
fn try_parse_raw(
  text : String,
) -> Result[Array[@lib.FieldSpec], @lib.ParseError] {
  try @lib.parse_copybook(text) catch {
    e => Err(e)
  } noraise {
    v => Ok(v)
  }
}

///|
fn try_compile(
  specs : Array[@lib.FieldSpec],
  float_mode : @lib.FloatMode,
) -> Result[@lib.RecordLayout, String] {
  try @lib.compile_layout_with_float_mode(specs, float_mode) catch {
    e => Err(e.to_display())
  } noraise {
    v => Ok(v)
  }
}

///|
/// 读文本文件（UTF-8）。失败返回 `None`（调用方决定退出码）。
fn read_text_file(path : String) -> String? {
  try Some(@fs.read_file_to_string(path)) catch {
    _ => None
  } noraise {
    v => v
  }
}

///|
/// 读二进制文件。
fn read_binary_file(path : String) -> Bytes? {
  try Some(@fs.read_file_to_bytes(path)) catch {
    _ => None
  } noraise {
    v => v
  }
}

///|
/// 子命令：layout
fn cmd_layout(opts : Options) -> Int32 {
  let cpy = match opts.copybook {
    Some(p) => p
    None => {
      eprintln("layout: --copybook is required")
      return EXIT_USAGE
    }
  }
  let layout = match load_layout(cpy, opts.float_mode) {
    Ok(l) => l
    Err(msg) => {
      eprintln(msg)
      return EXIT_DATA
    }
  }
  if layout.byte_length == 0 {
    eprintln("copybook has zero record length (no fields)")
    return EXIT_DATA
  }
  println(@lib.render_layout(layout))
  EXIT_OK
}

///|
/// 子命令：decode
fn cmd_decode(opts : Options) -> Int32 {
  let cpy = match opts.copybook {
    Some(p) => p
    None => {
      eprintln("decode: --copybook is required")
      return EXIT_USAGE
    }
  }
  let data_path = match opts.data {
    Some(p) => p
    None => {
      eprintln("decode: --data is required")
      return EXIT_USAGE
    }
  }
  // 先校验 format，避免读完文件才发现拼错
  let as_table = match opts.format {
    "jsonl" => false
    "table" => true
    other => {
      eprintln("decode: unknown --format '\{other}' (expected jsonl or table)")
      return EXIT_USAGE
    }
  }
  let layout = match load_layout(cpy, opts.float_mode) {
    Ok(l) => l
    Err(msg) => {
      eprintln(msg)
      return EXIT_DATA
    }
  }
  if layout.byte_length == 0 {
    eprintln("copybook has zero record length (no fields)")
    return EXIT_DATA
  }
  let data = match read_binary_file(data_path) {
    Some(b) => b
    None => {
      eprintln("decode: cannot read data file '\{data_path}'")
      return EXIT_DATA
    }
  }
  let rec_len = match opts.record_length {
    Some(n) => n
    None => layout.byte_length
  }
  if rec_len < layout.byte_length {
    eprintln(
      "decode: --record-length \{rec_len} is smaller than the layout length \{layout.byte_length}",
    )
    return EXIT_USAGE
  }
  // 空文件不是「成功解码了 0 条记录」，而是没有数据可解。
  // 静默返回 0 会让调用方（尤其是脚本）误以为文件正常。
  if data.length() == 0 {
    eprintln(
      "decode: data file '\{data_path}' is empty (expected \{rec_len}-byte records)",
    )
    return EXIT_DATA
  }
  match @lib.decode_records(layout, data, rec_len) {
    Err(e) => {
      eprintln("decode: " + e.to_display())
      EXIT_DATA
    }
    Ok(rows) =>
      if as_table {
        println(@lib.render_table(layout, rows))
        EXIT_OK
      } else {
        // render_jsonl 的每行已自带 \n，println 会再补一个换行 →
        // 5 条记录导出成 6 行（尾部多一个空行）。去掉尾部的单个换行
        // 再 println，保证恰好 N 条记录 N 行。
        let text = @lib.render_jsonl(layout, rows)
        println(if text.length() > 0 { text[:text.length() - 1] } else { text })
        EXIT_OK
      }
  }
}

///|
/// 子命令：encode
fn cmd_encode(opts : Options) -> Int32 {
  let cpy = match opts.copybook {
    Some(p) => p
    None => {
      eprintln("encode: --copybook is required")
      return EXIT_USAGE
    }
  }
  let json_path = match opts.json {
    Some(p) => p
    None => {
      eprintln("encode: --json is required")
      return EXIT_USAGE
    }
  }
  let out_path = match opts.out {
    Some(p) => p
    None => {
      eprintln("encode: --out is required")
      return EXIT_USAGE
    }
  }
  let layout = match load_layout(cpy, opts.float_mode) {
    Ok(l) => l
    Err(msg) => {
      eprintln(msg)
      return EXIT_DATA
    }
  }
  if layout.byte_length == 0 {
    eprintln("copybook has zero record length (no fields)")
    return EXIT_DATA
  }
  let text = match read_text_file(json_path) {
    Some(t) => t
    None => {
      eprintln("encode: cannot read json file '\{json_path}'")
      return EXIT_DATA
    }
  }
  // 逐行解析 JSONL → Map[路径, @lib.CellValue]
  let rows : Array[Map[String, @lib.CellValue]] = []
  let lines = text.split("\n").collect()
  for i = 0; i < lines.length(); i = i + 1 {
    let line = lines[i].to_owned()
    let trimmed = line.trim(chars=" \t\r").to_owned()
    if trimmed.length() == 0 {
      continue
    }
    match @lib.parse_jsonl_row(layout, trimmed) {
      Ok(m) => rows.push(m)
      Err(msg) => {
        eprintln("encode: line \{i + 1}: \{msg}")
        return EXIT_DATA
      }
    }
  }
  // 空 JSONL 与 decode 的空数据文件对称：写 0 字节并报成功会让脚本
  // 误以为转换完成，实际什么都没发生。
  if rows.length() == 0 {
    eprintln("encode: input contains no records")
    return EXIT_DATA
  }
  let bytes = match @lib.encode_records(layout, rows) {
    Ok(b) => b
    Err(e) => {
      eprintln("encode: " + e.to_display())
      return EXIT_DATA
    }
  }
  match write_binary_file(out_path, bytes) {
    Ok(_) => {
      eprintln(
        "encoded \{rows.length()} record(s), \{bytes.length()} bytes -> \{out_path}",
      )
      EXIT_OK
    }
    Err(msg) => {
      eprintln("encode: \{msg}")
      EXIT_DATA
    }
  }
}

///|
/// 子命令：verify（往返自检）
fn cmd_verify(opts : Options) -> Int32 {
  let cpy = match opts.copybook {
    Some(p) => p
    None => {
      eprintln("verify: --copybook is required")
      return EXIT_USAGE
    }
  }
  let data_path = match opts.data {
    Some(p) => p
    None => {
      eprintln("verify: --data is required")
      return EXIT_USAGE
    }
  }
  let layout = match load_layout(cpy, opts.float_mode) {
    Ok(l) => l
    Err(msg) => {
      eprintln(msg)
      return EXIT_DATA
    }
  }
  if layout.byte_length == 0 {
    eprintln("copybook has zero record length (no fields)")
    return EXIT_DATA
  }
  let data = match read_binary_file(data_path) {
    Some(b) => b
    None => {
      eprintln("verify: cannot read data file '\{data_path}'")
      return EXIT_DATA
    }
  }
  let rec_len = layout.byte_length
  // 零长度布局（如只有 `01 EMPTY.`）没有任何字段，除零会以运行时栈崩溃的
  // 方式暴露。空布局意味着「没有任何数据契约」，verify 对它无事可做。
  if rec_len == 0 {
    eprintln("verify: layout has zero length (no fields); nothing to verify")
    return EXIT_DATA
  }
  if data.length() % rec_len != 0 {
    eprintln(
      "verify: data length \{data.length()} is not a multiple of record length \{rec_len}",
    )
    return EXIT_DATA
  }
  let mut checked = 0
  let mut pos = 0
  while pos < data.length() {
    let rec = data[pos:pos + rec_len]
    match @lib.roundtrip_check(layout, rec) {
      Err(e) => {
        eprintln("verify: record \{checked}: decode failed: " + e.to_display())
        return EXIT_DATA
      }
      Ok(Some(off)) => {
        eprintln("verify: record \{checked}: byte mismatch at offset \{off}")
        return EXIT_DATA
      }
      Ok(None) => ()
    }
    checked = checked + 1
    pos = pos + rec_len
  }
  eprintln("verify: \{checked} record(s) OK, byte-identical roundtrip")
  EXIT_OK
}

///|
fn write_binary_file(path : String, bytes : Bytes) -> Result[Unit, String] {
  let r = try_write(path, bytes)
  match r {
    Ok(_) => Ok(())
    Err(_) => Err("cannot write output file")
  }
}

///|
fn try_write(path : String, bytes : Bytes) -> Result[Unit, @fs.IOError] {
  try {
    @fs.write_bytes_to_file(path, bytes)
    Ok(())
  } catch {
    e => Err(e)
  } noraise {
    v => v
  }
}

///|
fn main {
  let args = @env.args()
  // args[0] 是可执行文件路径
  if args.length() < 2 {
    eprintln(usage_text())
    @sys.exit(EXIT_USAGE)
  }
  let sub = args[1]
  if sub == "--help" || sub == "-h" || sub == "help" {
    println(usage_text())
    @sys.exit(EXIT_OK)
  }
  let rest = args[2:]
  let opts = match parse_options(rest) {
    Ok(o) => o
    Err(msg) => {
      eprintln("error: \{msg}")
      eprintln(usage_text())
      @sys.exit(EXIT_USAGE)
      Options::{
        copybook: None,
        data: None,
        json: None,
        out: None,
        format: "",
        record_length: None,
        float_mode: @lib.Hfp,
      }
    }
  }
  let code = match sub {
    "layout" => cmd_layout(opts)
    "decode" => cmd_decode(opts)
    "encode" => cmd_encode(opts)
    "verify" => cmd_verify(opts)
    other => {
      eprintln("error: unknown subcommand '\{other}'")
      eprintln(usage_text())
      EXIT_USAGE
    }
  }
  @sys.exit(code)
}
