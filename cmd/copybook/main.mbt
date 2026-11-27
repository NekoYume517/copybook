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
  /// 显式出现过的选项键（NEW-8：用于「子命令级白名单」校验）。
  ///
  /// 旧实现只做全局键识别，于是 encode 静默接受 --data / --format /
  /// --record-length 这些对它毫无意义的选项（exit 0）。打错一个子命令名
  /// 或从别的命令复制过来时，用户得不到任何反馈。
  given : Array[String]
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
    given: [],
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
    // 取值辅助：有 inline 用 inline，否则吃下一个 token。
    //
    // **值位不许吞掉另一个选项**（2026-11-21 审计）：`--copybook --data c.dat`
    // 旧实现把 `--data` 当作 `--copybook` 的值吃掉，随后 `c.dat` 变成
    // "unknown option 'c.dat'" —— 真正的问题（缺值）被错位诊断掩盖。
    // 以 `--` 开头的 token 一律视为选项；要传这种路径用内联写法
    // `--copybook=--weird.cpy`（内联值不经过这里）。单短横线（`-x.cpy`）
    // 不是选项前缀，照旧当值。
    let take_value = fn() -> Result[String, String] {
      match inline_value {
        Some(v) => Ok(v)
        None =>
          if i + 1 >= n {
            Err("option \{key} requires a value")
          } else if args[i + 1].has_prefix("--") {
            Err(
              "option \{key} requires a value, but the next token '\{args[i + 1]}' looks like another option (use the inline form \{key}=... when the value itself starts with '--')",
            )
          } else {
            i = i + 1
            Ok(args[i])
          }
      }
    }
    match key {
      "--copybook" => {
        opts.given.push("--copybook")
        match take_value() {
          Ok(v) => opts.copybook = Some(v)
          Err(e) => return Err(e)
        }
      }
      "--data" => {
        opts.given.push("--data")
        match take_value() {
          Ok(v) => opts.data = Some(v)
          Err(e) => return Err(e)
        }
      }
      "--json" => {
        opts.given.push("--json")
        match take_value() {
          Ok(v) => opts.json = Some(v)
          Err(e) => return Err(e)
        }
      }
      "--out" => {
        opts.given.push("--out")
        match take_value() {
          Ok(v) => opts.out = Some(v)
          Err(e) => return Err(e)
        }
      }
      "--format" => {
        opts.given.push("--format")
        match take_value() {
          Ok(v) => opts.format = v
          Err(e) => return Err(e)
        }
      }
      "--record-length" => {
        opts.given.push("--record-length")
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
      }
      "--float-mode" => {
        opts.given.push("--float-mode")
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
      }
      _ => return Err("unknown option '\{key}'")
    }
    i = i + 1
  }
  Ok(opts)
}

///|
/// 解析正整数（只用 ASCII 数字，拒绝空串/负数/杂字符/溢出）。
///
/// **必须防 Int32 回绕**（NEW-3，2026-11-04 审计）：旧实现逐位
/// `v = v * 10 + digit` 无溢出检查，于是
/// `--record-length 4294967300` 回绕成 **4**——恰好等于某个布局的长度，
/// `decode` 因此静默成功 exit 0、零提示，而用户要求的记录长度与实际用的
/// 完全不同（`9999999999` 会回绕成 1410065407）。更坏的情形是回绕成
/// 大于布局的值，把大文件按错误边界切分。
///
/// 项目里已有同类先例：`src/lexer.mbt` 的 `parse_digits` 明确用「超过 9 位
/// 直接拒绝」来防 OCCURS 的回绕，并在注释里说明踩过这个坑。CLI 侧漏了同一
/// 防护，这里补上，且判定放在**乘之前**（否则乘以 10 本身就可能已经溢出）。
fn parse_positive_int(s : StringView) -> Int32? {
  let n = s.length()
  if n == 0 {
    return None
  }
  // 位数上限：Int32 最大 2147483647 是 10 位，但记录长度不可能到这个量级
  // （远大于任何真实记录）。超过 9 位一律拒绝，既防溢出又不误伤。
  if n > 9 {
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
/// 从文件读 copybook 并编译布局，**同时把源文本交回调用方**。
///
/// CB-20-1（2026-11-28 审计）：`SYNC` 警告需要在非 layout 子命令上也出现，
/// 而「这份 copybook 声明了几处 SYNC」只能从源文本判定（布局层的
/// `FieldLayout.is_synced` 会把组项上的 SYNC 下发给叶子，口径不同）。
/// 这里顺手把文本带出来，免得再读一次文件、也免得两条路径读到不同内容。
fn load_layout_with_text(
  path : String,
  float_mode : @lib.FloatMode,
) -> Result[(@lib.RecordLayout, String), String] {
  let text = match read_text_file(path) {
    Some(Ok(t)) => t
    Some(Err(msg)) => return Err(msg)
    None => return Err("cannot read copybook '\{path}'")
  }
  let specs = match compile_specs(text) {
    Ok(s) => s
    Err(msg) => return Err("copybook parse error: \{msg}")
  }
  match try_compile(specs, float_mode) {
    Ok(l) => Ok((l, text))
    Err(msg) => Err("layout error: \{msg}")
  }
}

///|
/// 从文件读 copybook 并编译布局。
fn load_layout(
  path : String,
  float_mode : @lib.FloatMode,
) -> Result[@lib.RecordLayout, String] {
  match load_layout_with_text(path, float_mode) {
    Ok(pair) => Ok(pair.0)
    Err(msg) => Err(msg)
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
/// 读文本文件（UTF-8），并**校验它是真的 UTF-8**。
///
/// 旧实现直接用 `@fs.read_file_to_string`，它对非法字节是宽松解码：
/// 坏槽位留在 String 里，随后 `lexer.mbt` 的 `split_lines` 在
/// `get_char(i).unwrap()` 上 `moonbit_panic`，进程以 `0xC0000409`
/// （abort）退出 —— 既不是 1（数据错误）也不是 2（用法错误）。
/// 最容易撞上的是 Windows 记事本「另存为 → Unicode」产出的 UTF-16LE，
/// 或者某些工具写出的孤立代理项 `ED A0 80`（2026-11-26 审计，P0）。
///
/// 这里先按字节校验（`validate_utf8`），非法时返回**带文件名与字节偏移**
/// 的用法级提示；同时单独识别 UTF-16/UTF-32 的 BOM，直接告诉用户该文件
/// 该另存成什么。校验通过后才交给 core 的解码器（此时它不会 panic）。
///
/// 返回 `Some(Ok(text))` / `Some(Err(msg))` / `None`（读不出来）。
fn read_text_file(path : String) -> Result[String, String]? {
  let raw = match read_binary_file(path) {
    Some(b) => b
    None => return None
  }
  match non_utf8_bom_name(raw) {
    Some(name) =>
      return Some(
        Err(
          "'\{path}' starts with a \{name} byte-order mark: this tool reads UTF-8 only (a copybook re-saved by Notepad as \u{201C}Unicode\u{201D} is the usual cause) — re-save it as UTF-8 without a BOM",
        ),
      )
    None => ()
  }
  match validate_utf8(raw) {
    Err((off, why)) =>
      return Some(
        Err(
          "'\{path}' is not valid UTF-8: \{why} at byte offset \{off} (the file is probably UTF-16 or otherwise mis-encoded) — re-save it as UTF-8",
        ),
      )
    Ok(_) => ()
  }
  Some(Ok(@unicode.to_utf8_string(raw)))
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
/// 在 stderr 上补一条 SYNC 警告 —— **读布局层的唯一权威**（CB-21-2，2026-11-29）。
///
/// 第二十轮（CB-20-1）为了让 `verify` / `decode` / `encode` 也出声，在这里
/// **重新扫了一遍 copybook 源文本**数 `SYNC` 关键字；于是同一份 copybook 在
/// `layout`（数叶子）和 `verify`（数源文本声明）上可能报出两个数字，实测：
///
///   `05 M SYNC.` + 2 个孩子          layout 2 / verify 1
///   `05 M1 SYNC.` + `05 M2 SYNC.`    layout 3 / verify 2
///   `05 G1 SYNC.` + 三层嵌套 2 叶子   layout 2 / verify 1
///   组级 SYNC 但组内没有叶子          layout 不报 / verify 1
///
/// 现在两边都读 `RecordLayout::sync_summary()`，文案与 `render_layout` 的
/// 汇总警告同源（`@lib.layout_sync_warning`），不可能再分叉。
///
/// 「组上声明但没有任何基本项受影响」的情形单列一条**不同的**诊断，

///|
/// 布局有空洞时在 stderr 上出声（CB-21-3，2026-11-29）。
///
/// 「空洞」= 记录里没有任何字段承载、只能靠旁路键保真的字节（FILLER 中部区，
/// 或只有重定义视图覆盖而该视图解不出的尾部区）。本工具内部能逐字节往返
/// （`__record_bytes` 回填），所以 `verify` 报 `byte-identical` 是真的 ——
/// 但那几个字节**只活在 `decode → JSONL → encode` 这条侧道里**。手写 JSONL、
/// 外部工具过滤 `__` 键、把值喂给下游系统之后，它们会静默变成 0x40（合法空格，
/// 损坏的记录看着仍然正常）。四个子命令此前没有一处提过这件事。
///
/// `layout` 不调它：报告里已有 `HOLES:` 机读行，重复打到 stderr 会让
/// `2>&1` 合并后出现两遍。
///
/// 判据与 `@lib.layout_static_gaps` 同源（后者又复用 `filler_gaps` /
/// `primary_tail_gaps`，与 `gap_carrier_report` 是同一对底层函数）。
fn warn_layout_holes(layout : @lib.RecordLayout) -> Unit {
  let gaps = @lib.layout_static_gaps(layout)
  if gaps.length() > 0 {
    eprintln(@lib.layout_hole_warning(gaps))
  }
}

///|
/// 不混进字段数里（源文本里写了 SYNC 却一个偏移都没变，用户需要知道）。
///
/// **文案只有一个实现**（CB-22-1，2026-11-27 审计）：这里此前手写了一遍，
/// 与 `@lib.layout_sync_inert_warning` 分叉 12 个字符（少了 ` on this layout`）——
/// `layout` 与 `decode` / `verify` 对同一件事说两种话。与 CB-21-2 同一条教训：
/// 结论一旦有两个书写点，就一定会漂移。
fn warn_sync_layout(layout : @lib.RecordLayout) -> Unit {
  let sync = layout.sync_summary()
  if sync.affected_leaves > 0 {
    eprintln(@lib.layout_sync_warning(sync.affected_leaves))
  }
  if sync.inert_groups.length() > 0 {
    eprintln(@lib.layout_sync_inert_warning(sync.inert_groups))
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
  let (layout, cpy_text) = match load_layout_with_text(cpy, opts.float_mode) {
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
  // --record-length 大于布局长度：每条记录的尾部（rec_len - 布局长度）字节
  // 不属于任何字段，解码跳过、重编码也不会还原。这是 RDW/BDW 头或自定义
  // 填充的合法用法，但静默截尾会让「8 字节数据每条丢 1 字节」无迹可查——
  // 明确警告一次（不改变退出码：解码本身仍逐条成功）。
  if rec_len > layout.byte_length {
    eprintln(
      "warning: --record-length \{rec_len} exceeds the layout length \{layout.byte_length}; the trailing \{rec_len - layout.byte_length} byte(s) of each record are outside the copybook and are skipped on decode (they are NOT restored by encode)",
    )
  }
  warn_sync_layout(layout)
  warn_layout_holes(layout)
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
  let (layout, cpy_text) = match load_layout_with_text(cpy, opts.float_mode) {
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
  warn_sync_layout(layout)
  warn_layout_holes(layout)
  let text = match read_text_file(json_path) {
    Some(Ok(t)) => t
    Some(Err(msg)) => {
      eprintln("encode: \{msg}")
      return EXIT_DATA
    }
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
    // **剥 BOM**（NEW-8，2026-11-04 审计）：copybook 侧词法层会剥 U+FEFF
    // （`lexer.mbt` 的 tokenize 明确处理），但 encode 侧没有——于是
    // 「编辑器/PowerShell 重定向产出的带 BOM 的 JSONL」会整份被拒，
    // 报错只说 `invalid JSON`，不提 BOM，用户无从下手。
    // README 推荐的 `> out.jsonl` 在 Windows 上正好会产生这种文件。
    //
    // 必须显式剥首字符：`trim(chars=...)` 是按字符集裁剪，BOM 不在默认
    // 空白集里（它也不是空白），所以 `trim` 不动它。
    let line = if line.length() > 0 &&
      (line.get_char(0) : Char?) == Some('\u{FEFF}') {
      line[1:].to_owned()
    } else {
      line
    }
    let trimmed = line.trim(chars=" \t\r").to_owned()
    if trimmed.length() == 0 {
      continue
    }
    match @lib.parse_jsonl_row(layout, trimmed) {
      Ok(m) => rows.push(m)
      Err(msg) => {
        // 报错带行号与原因；若这一行开头带 BOM 而其余都正常，说明是编码问题
        eprintln("encode: line \{i + 1}: \{msg}")
        if line.length() > 0 && (line.get_char(0) : Char?) == Some('\u{FEFF}') {
          eprintln(
            "encode: line \{i + 1} starts with a UTF-8 BOM (U+FEFF); save the file as plain UTF-8 without BOM",
          )
        }
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
  let (layout, cpy_text) = match load_layout_with_text(cpy, opts.float_mode) {
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
  // **SYNC 警告要排在结论之前**（CB-20-1）：`verify` 的成功结论是
  // 「byte-identical roundtrip」，而带 SYNC 的布局与真实 IBM 偏移不同 ——
  // 这条往返自洽只证明「本工具自己的布局自洽」，不证明「这份文件能按
  // copybook 读对」。`2>&1` 合并后警告必须先于结论行，否则顺序会反过来
  // 变成「结论先成立、然后才提醒」。`layout` 子命令的 stdout 报告里已有
  // 逐行 + 汇总标注，这里只对 verify 的 stderr 负责。
  warn_sync_layout(layout)
  warn_layout_holes(layout)
  let data = match read_binary_file(data_path) {
    Some(b) => b
    None => {
      eprintln("verify: cannot read data file '\{data_path}'")
      return EXIT_DATA
    }
  }
  let rec_len = match opts.record_length {
    Some(n) => n
    None => layout.byte_length
  }
  // CB-2（2026-11-08 审计）：--record-length 在白名单里承诺对 verify
  // 合法，cmd_verify 却写死布局长度把它静默丢弃 —— 9 字节数据 +
  // --record-length 8 报 "not a multiple of record length 4"，8 字节
  // 时又碰巧 exit 0。消费方式与 decode 完全同款：
  // N < 布局 → 用法错误；N > 布局 → 警告尾字节并按 N 切分。
  if rec_len < layout.byte_length {
    eprintln(
      "verify: --record-length \{rec_len} is smaller than the layout length \{layout.byte_length}",
    )
    return EXIT_USAGE
  }
  if rec_len > layout.byte_length {
    eprintln(
      "warning: --record-length \{rec_len} exceeds the layout length \{layout.byte_length}; the trailing \{rec_len - layout.byte_length} byte(s) of each record are outside the copybook and are NOT checked against any field",
    )
  }
  // N > 布局时只校验每条记录的前 layout.byte_length 字节：roundtrip_check
  // 是「整记录重编码必须逐字节一致」的语义，直接喂 N 字节切片会因为
  // 「重编码只有布局长」而必然 byte mismatch @ 布局长度（实测）。与
  // decode 的「尾字节在 copybook 之外」语义对齐 —— 只对布局覆盖的字节
  // 做往返校验。
  let check_len = if rec_len < layout.byte_length {
    rec_len
  } else {
    layout.byte_length
  }
  // 零长度布局（如只有 `01 EMPTY.`）没有任何字段，除零会以运行时栈崩溃的
  // 方式暴露。空布局意味着「没有任何数据契约」，verify 对它无事可做。
  if rec_len == 0 {
    eprintln("verify: layout has zero length (no fields); nothing to verify")
    return EXIT_DATA
  }
  // 空文件不是「成功校验了 0 条记录」，而是没有数据可校验——与 decode
  // 的空数据分支（main.mbt decode 侧）同一措辞与退出码，避免脚本把
  // 「verify: 0 record(s) OK」误读为文件正常。
  if data.length() == 0 {
    eprintln(
      "verify: data file '\{data_path}' is empty (expected \{rec_len}-byte records)",
    )
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
    let rec = data[pos:pos + check_len]
    match @lib.roundtrip_check(layout, rec) {
      Err(e) => {
        // CB-19：decode 与 encode 的失败含义不同，措辞必须区分 ——
        // 编码失败说明「数据解得出来，但写不回去」，把它说成 decode failed
        // 会把排查方向指错。EncodeFailed 自带的文案已含 "encode failed"。
        match e {
          @lib.EncodeFailed(_) =>
            eprintln("verify: record \{checked}: " + e.to_display())
          _ =>
            eprintln(
              "verify: record \{checked}: decode failed: " + e.to_display(),
            )
        }
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
  eprintln(verify_conclusion(layout.byte_length, rec_len, checked))
  EXIT_OK
}

///|
/// verify 成功时的结论文案。
///
/// `rec_len` 与 `layout_len` 的关系决定「往返」的覆盖范围：`cmd_verify`
/// 在 `rec_len > layout_len` 时只把每条记录的前 `layout_len` 字节喂给
/// `roundtrip_check`（整记录重编码必然在布局长度处 mismatch），尾字节
/// 根本不参与往返。结论文案必须跟着这个夹取一起改口，否则用户拿到的
/// 是「同一行输出里先声明没检查、再宣称逐字节一致」。
fn verify_conclusion(
  layout_len : Int32,
  rec_len : Int32,
  checked : Int32,
) -> String {
  if rec_len > layout_len {
    // 尾字节不在布局内、也就没参加往返：encode 只写 layout_len 字节/记录，
    // 所以整个文件的 `encode(decode(bytes)) == bytes` **不成立**。这里把
    // 两句都写出来，避免调用方把「前 L 字节一致」读成「文件无损」。
    "verify: \{checked} record(s) OK, first \{layout_len} byte(s) of each record roundtrip byte-identical; the trailing \{rec_len - layout_len} byte(s) per record are outside the copybook and are NOT part of the roundtrip"
  } else {
    "verify: \{checked} record(s) OK, byte-identical roundtrip"
  }
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
/// 子命令接受的选项白名单（NEW-8）。
///
/// 单独成函数是为了能被白盒测试锁定：`main` 里调用 `@sys.exit`，退出码本身
/// 测不了，但「哪个子命令接受哪些键」这张表可以。
///
/// `--float-mode` 是全局选项（浮点字节解释是数据源属性），四个子命令都接受。
/// 未知子命令返回空表，调用方据此跳过校验（由后面的 unknown-subcommand
/// 分支报错）。
fn allowed_options(sub : String) -> Array[String] {
  match sub {
    "layout" => ["--copybook", "--float-mode"]
    "decode" =>
      ["--copybook", "--data", "--format", "--record-length", "--float-mode"]
    "encode" => ["--copybook", "--json", "--out", "--float-mode"]
    "verify" => ["--copybook", "--data", "--record-length", "--float-mode"]
    _ => []
  }
}

///|
/// `@env.args()` 前面有几个元素不属于本程序。
///
/// `@env.args()` 是**整个进程**的命令行。js 后端把解释器也算进去：`node` 是
/// `argv[0]`、编译产物的路径是 `argv[1]`，而这个 CLI 把 `args[1]` 当子命令，于是 js 上
/// `copybook layout ...` 的子命令被读成那个 `.js` 路径 —— 实测（`moonc v1.0.0-rc1`）
/// 同一个 `help` 在 wasm/wasm-gc 上 2 个元素、在 js 上 3 个。0.1.20261117 上一样，
/// 所以这是 js 构建的性质，不是 1.0 引入的。
///
/// 把「程序自身」重新放回 index 0 再往下走，`args[1]` / `args[2:]` 的语义一点没变，
/// js 上丢掉的只是 `node`。
///
/// 两条 `#cfg` 声明：`#cfg` 只能挂在声明上，挂在语句上不通过解析。
#cfg(not(target="js"))
let argv_prefix : Int32 = 1

///|
#cfg(target="js")
let argv_prefix : Int32 = 2

///|
fn main {
  let all = @env.args()
  let args : Array[String] = Array::new(capacity=all.length())
  // index 0 放「程序自身」：wasm/wasm-gc 取 `all[0]`，js 取 `all[1]`（`all[0]` 是 node）。
  for i = argv_prefix - 1; i < all.length(); i = i + 1 {
    args.push(all[i])
  }
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
        given: [],
      }
    }
  }
  // **子命令级选项白名单**（NEW-8，2026-11-04 审计）。
  //
  // 旧实现只做全局键识别，于是 `encode --data x --format table
  // --record-length 3` 这类「从别的命令复制过来 / 打错子命令」的命令行
  // 会被静默接受并 exit 0 —— 用户以为选项生效了，实际一个都没用上。
  // 这里按子命令校验：给不属于它的键就报用法错误，并列出它接受什么。
  // `--float-mode` 是全局选项（影响浮点解释），四个子命令都接受。
  let allowed : Array[String] = allowed_options(sub)
  if allowed.length() > 0 {
    let wrong : Array[String] = []
    for key in opts.given {
      if !allowed.contains(key) {
        wrong.push(key)
      }
    }
    if wrong.length() > 0 {
      let wrong_text = wrong.join(", ")
      let allowed_text = allowed.join(", ")
      eprintln("error: option(s) \{wrong_text} not accepted by '\{sub}'")
      eprintln("error: '\{sub}' accepts: \{allowed_text}")
      @sys.exit(EXIT_USAGE)
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
