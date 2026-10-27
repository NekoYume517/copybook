// 输出渲染 —— JSONL / 定宽表格 / 布局报告
//
// 三个 `render_*` 都返回 `String`，不直接打印：这样调用方可以写文件、
// 可以做测试断言、可以在 CLI 里加前缀，也可以组合成流式输出。
//
// 全部用 `StringBuilder` 累积，不做字符串 `+=`（那会造成 O(n²) 拷贝）。

///|
/// 把 `CellValue` 转成 JSON 值。
///
/// 映射规则：
///   - `Null`    → `null`
///   - `Text`    → JSON string（`Json::string` 负责转义 `"` `\` 与控制字符）
///   - `Int`     → JSON number（**用 `repr` 传十进制原文**，避免 Int64 被
///                 Double 截断：`123456789012345678` 转 Double 会丢精度）
///   - `Decimal` → JSON number，按 `to_string()` 的十进制原文
///   - `Float`   → 有限值输出 JSON number（`repr` 原文）；**±Inf/NaN 不是
///                 合法 JSON 字面量**，按 IEEE 754 文本约定输出带引号的
///                 字符串 `"Infinity"` / `"-Infinity"` / `"NaN"`。
///                 `parse_jsonl_row` 能把这三个串解回 Float（R4 契约）。
///   - `Bool`    → JSON boolean
///   - `Bytes`   → 十六进制小写字符串（`"0102AB"`），因为 JSON 没有字节类型
///
/// **不使用 `Json::number(d)` + 自动格式化**：那会把 `1234567.89` 变成
/// `1234567.8900000001` 这类浮点噪声。COBOL 数值必须原样呈现。
fn cell_to_json(v : CellValue) -> Json {
  match v {
    Null => Json::null()
    Text(s) => Json::string(s)
    Int(i) => Json::number(0.0, repr=i.to_string())
    Decimal(d) => Json::number(0.0, repr=d.to_string())
    Bool(b) => Json::boolean(b)
    Float(f) =>
      if f != f {
        // NaN：自反不等是 NaN 的唯一可靠判定
        Json::string("NaN")
      } else if f == 1.0 / 0.0 {
        Json::string("Infinity")
      } else if f == -1.0 / 0.0 {
        Json::string("-Infinity")
      } else {
        // **用 format_json_number，不用 f.to_string()**（CB-17）：
        // `Double::to_string()` 对 -0.0 与 +0.0 都返回 "0"，符号位在文本
        // 这一环丢失 —— 而 HFP 的 ±0 字节不同（`80 00 00 00` vs
        // `00 00 00 00`），FIDELITY.md §2.3/§3 明确承诺两者各自往返。
        // `format_json_number` 已经用 reinterpret 的符号位正确处理负零
        // （jsonl.mbt），这里与它统一，避免同一语义两处实现漂移。
        Json::number(f, repr=format_json_number(f))
      }
    Bytes(bs) => {
      let sb = StringBuilder()
      for i = 0; i < bs.length(); i = i + 1 {
        let v = bs[i].to_int()
        let hi = (v >> 4) & 0xF
        let lo = v & 0xF
        sb.write_string(hex_lower(hi))
        sb.write_string(hex_lower(lo))
      }
      Json::string(sb.to_string())
    }
  }
}

///|
fn hex_lower(v : Int32) -> String {
  if v < 10 {
    v.to_string()
  } else {
    match v {
      10 => "a"
      11 => "b"
      12 => "c"
      13 => "d"
      14 => "e"
      _ => "f"
    }
  }
}

///|
/// 计算一条记录里「只有重定义视图覆盖」的**尾部**字节区间（所有主视图字段
/// 结束之后、记录长度之前的部分，见 encode 层 `primary_tail_gaps`），并从
/// `row` 携带的原始记录字节（`__record_bytes`，由宽容解码在布局存在尾部
/// 空洞时写入）中取出这段字节，渲染为小写十六进制串。
///
/// 返回 `None` 的情形：没有尾部空洞 / 空洞字节全为 0x40（未赋值工作存储区
/// 惯例，不携带信息）/ 没有原始字节信息（手写 JSON、非 decode 来源——
/// encode 会按惯例写 0x40）。全 0x00 **会**带出：0x00 与 0x40 字节不同，
/// 静默改写同样是数据损坏。
fn layout_tail_gap_bytes(
  layout : RecordLayout,
  row : Map[String, CellValue],
) -> String? {
  // 用真实行值判定空洞（CB-16）：值为非 Null 的视图会把自己那段字节写好，
  // 那段就**不是**空洞，不能把原始字节当旁路信息带出去（否则编码时回填会
  // 覆盖视图的值，编辑被静默丢弃）。
  let gaps = primary_tail_gaps(layout, Some(row))
  if gaps.length() == 0 {
    return None
  }
  // 原始记录字节：宽容解码在布局有尾部空洞时把整个 BytesView 挂在保留键上
  let record : BytesView = match row.get("__record_bytes") {
    Some(Bytes(bs)) => bs
    _ => return None
  }
  // 空洞必须完整落在原始记录内
  for (s, e) in gaps {
    if e > record.length() {
      return None
    }
    ignore(s)
  }
  let sb = StringBuilder()
  let mut uniform_space = true
  let mut any = false
  for (s, e) in gaps {
    for i = s; i < e; i = i + 1 {
      let v = record[i].to_int()
      if v != 0x40 {
        uniform_space = false
      }
      any = true
      sb.write_string(hex_lower((v >> 4) & 0xF))
      sb.write_string(hex_lower(v & 0xF))
    }
  }
  if !any || uniform_space {
    return None
  }
  Some(sb.to_string())
}

///|
/// 中部空洞旁路（P1-2）：FILLER 占据的区间（或手工布局的裂缝）不属于
/// 任何字段，decode 结果里没有承载，JSONL 必须把它带出去才能字节保真。
/// 与 layout_tail_gap_bytes 同一手法：区间并集 → 从 `__record_bytes`
/// 取字节 → 小写十六进制；全 0x40（未赋值工作存储区惯例）不携带。
fn layout_filler_gap_bytes(
  layout : RecordLayout,
  row : Map[String, CellValue],
) -> String? {
  // 同上（CB-16）：按真实行值算空洞 —— 视图非 Null 时它那段不是空洞。
  let gaps = filler_gaps(layout, Some(row))
  if gaps.length() == 0 {
    return None
  }
  let record : BytesView = match row.get("__record_bytes") {
    Some(Bytes(bs)) => bs
    _ => return None
  }
  for (s, e) in gaps {
    if e > record.length() {
      return None
    }
    ignore(s)
  }
  let sb = StringBuilder()
  let mut uniform_space = true
  let mut any = false
  for (s, e) in gaps {
    for i = s; i < e; i = i + 1 {
      let v = record[i].to_int()
      if v != 0x40 {
        uniform_space = false
      }
      any = true
      sb.write_string(hex_lower((v >> 4) & 0xF))
      sb.write_string(hex_lower(v & 0xF))
    }
  }
  if !any || uniform_space {
    return None
  }
  Some(sb.to_string())
}

///|
/// JSONL：每行一个 JSON 对象，键是字段路径。
///
/// 每行以 `\n` 结尾（包括最后一行）—— 这是 JSONL 的通行约定，也是
/// `wc -l` 与流式读取器预期的行为。
///
/// **键的顺序**按 `layout.fields` 的偏移顺序，而不是 `Map` 的插入序：
/// 稳定顺序让 diff 有意义，也让"同一份数据两次导出"可逐字节比较。
pub fn render_jsonl(
  layout : RecordLayout,
  rows : Array[Map[String, CellValue]],
) -> String {
  let sb = StringBuilder()
  for row in rows {
    let obj : Map[String, Json] = Map([])
    for field in layout.fields {
      let v = match row.get(field.path) {
        Some(x) => x
        None =>
          match row.get(field.name) {
            Some(x) => x
            None => Null
          }
      }
      obj[field.path] = cell_to_json(v)
    }
    // **字节保真的旁路信息**：decoded 值里可能带着原始符号 / 填充半字节
    // （见 FIDELITY.md）。JSON 数字没有地方放这些位，若不单独带出来，
    // 「decode → JSONL → encode」这条路径就只能按默认写法重编码，
    // 结果是 `01 23 4F` 变成 `01 23 4C`、`F1 F2 C3` 变成 `F1 F2 F3`。
    //
    // 用 `__nibbles` 这个保留键承载：`{"字段路径": {"sign": 12, "pad": 15}}`。
    // 键名以双下划线开头，不会与 COBOL 字段名冲突（COBOL 标识符不允许
    // 下划线开头）。只有真的存在 nibble 信息时才写这个键，
    // 普通记录（无十进制字段）的 JSONL 输出保持不变。
    let nib : Map[String, Json] = Map([])
    for field in layout.fields {
      let v = match row.get(field.path) {
        Some(x) => x
        None =>
          match row.get(field.name) {
            Some(x) => x
            None => Null
          }
      }
      match v {
        Decimal(d) =>
          match (d.sign_nibble, d.pad_nibble) {
            (None, None) => ()
            (sn, pn) => {
              let entry : Map[String, Json] = Map([])
              match sn {
                Some(n) => entry["sign"] = Json::number(n.to_double())
                None => ()
              }
              match pn {
                Some(n) => entry["pad"] = Json::number(n.to_double())
                None => ()
              }
              nib[field.path] = Json::object(entry)
            }
          }
        _ => ()
      }
    }
    if nib.size() > 0 {
      obj["__nibbles"] = Json::object(nib)
    }
    // **尾部字节旁路**（CB-9）：REDEFINES 视图可以比主视图长（布局层把记录
    // 延长到 max(主, 视图)），而宽容解码对解不出的重定义视图置 Null、encode
    // 又跳过 Null 视图——于是「只有重定义视图覆盖」的尾部字节没有任何载体，
    // 重编码时被 Writer 初始的 0x40 静默改写（`12 3C FF EE` → `12 3C 40 40`）。
    // 与 __nibbles 同一手法：用保留键 `__tail_hex` 把这段字节以十六进制带出，
    // encode 前由 parse_jsonl_row 还原。全 0x40（未赋值工作存储区惯例）不携带
    // 信息，跳过——普通记录的 JSONL 输出保持不变。
    let tail = layout_tail_gap_bytes(layout, row)
    if tail is Some(hex) {
      obj["__tail_hex"] = Json::string(hex)
    }
    // **中部空洞旁路**（P1-2）：FILLER 占字节但不进输出（布局层契约），
    // 这段字节在字段值里没有载体，重编码时会被 Writer 初始的 0x40 静默
    // 替换（C1 C2 C3 C4 C5 C6 → C1 C2 40 40 C5 C6，verify 自身 exit 1）。
    // 与 __tail_hex 同一手法：`__filler_hex` 按偏移序携带空洞字节，
    // parse_jsonl_row / encode_record 回填。全 0x40 不携带——普通记录
    // （无 FILLER 或 FILLER 全空格）的 JSONL 输出保持不变。
    let filler = layout_filler_gap_bytes(layout, row)
    if filler is Some(hex) {
      obj["__filler_hex"] = Json::string(hex)
    }
    sb.write_string(Json::object(obj).stringify())
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// 定宽文本表格：给人看的对齐输出。
///
/// 列宽按**所有行 + 表头**的最大显示宽度决定，最少 1。数值右对齐、
/// 文本左对齐 —— 这是数据表的通行约定，也让大数字容易读。
///
/// 表格结构：
/// ```
/// CUST-ID    CUST-NAME   BALANCE
/// ---------  ----------  ----------
///        42  ALICE       1234567.89
/// ```
///
/// 结尾不带多余空行（最后一行的 `\n` 保留）。
pub fn render_table(
  layout : RecordLayout,
  rows : Array[Map[String, CellValue]],
) -> String {
  let fields = layout.fields
  let ncol = fields.length()
  if ncol == 0 {
    return ""
  }
  let sb = StringBuilder()
  // 列宽：表头 vs 所有单元格
  let widths : Array[Int32] = []
  for field in fields {
    widths.push(field.name.length())
  }
  // 先算每列内容最大宽度
  let cell_texts : Array[Array[String]] = []
  for row in rows {
    let texts : Array[String] = []
    for i = 0; i < ncol; i = i + 1 {
      let field = fields[i]
      let v = match row.get(field.path) {
        Some(x) => x
        None =>
          match row.get(field.name) {
            Some(x) => x
            None => Null
          }
      }
      let t = v.to_display()
      texts.push(t)
      if t.length() > widths[i] {
        widths[i] = t.length()
      }
    }
    cell_texts.push(texts)
  }
  // 表头
  for i = 0; i < ncol; i = i + 1 {
    if i > 0 {
      sb.write_string("  ")
    }
    sb.write_string(pad_right(fields[i].name, widths[i]))
  }
  sb.write_char('\n')
  // 分隔线
  for i = 0; i < ncol; i = i + 1 {
    if i > 0 {
      sb.write_string("  ")
    }
    for j = 0; j < widths[i]; j = j + 1 {
      sb.write_char('-')
    }
  }
  sb.write_char('\n')
  // 数据行：数值右对齐，文本左对齐
  for r = 0; r < cell_texts.length(); r = r + 1 {
    let texts = cell_texts[r]
    for i = 0; i < ncol; i = i + 1 {
      if i > 0 {
        sb.write_string("  ")
      }
      let field = fields[i]
      let numeric = match field.pic.category {
        Numeric => true
        _ => false
      }
      if numeric {
        sb.write_string(pad_left(texts[i], widths[i]))
      } else {
        sb.write_string(pad_right(texts[i], widths[i]))
      }
    }
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
fn pad_right(s : StringView, width : Int32) -> String {
  let n = s.length()
  if n >= width {
    return s.to_owned()
  }
  let sb = StringBuilder()
  sb.write_string(s.to_owned())
  for i = n; i < width; i = i + 1 {
    sb.write_char(' ')
  }
  sb.to_string()
}

///|
fn pad_left(s : StringView, width : Int32) -> String {
  let n = s.length()
  if n >= width {
    return s.to_owned()
  }
  let sb = StringBuilder()
  for i = n; i < width; i = i + 1 {
    sb.write_char(' ')
  }
  sb.write_string(s.to_owned())
  sb.to_string()
}

///|
/// 布局报告：字段名 / 偏移 / 长度 / 类型。
///
/// 输出格式**必须与 API.md 逐字符一致**，包括列宽。实测 API.md 的样例：
///
/// ```
/// RECORD: CUSTOMER-RECORD                          LENGTH: 54 bytes
///
/// OFFSET  LENGTH  OCCURS  TYPE              NAME
///      0       8       1  9(8) DISPLAY      CUSTOMER-RECORD.CUST-ID
///      8      30       1  X(30) DISPLAY     CUSTOMER-RECORD.CUST-NAME
///     38       5       1  S9(7)V99 COMP-3   CUSTOMER-RECORD.BALANCE
/// ```
///
/// 从样例反推出的列布局（0-based 字符位置）：
///   OFFSET  右对齐宽度  6  （"OFFSET" 本身 6 字符）
///   2 空格
///   LENGTH  右对齐宽度  6
///   2 空格
///   OCCURS  右对齐宽度  6
///   2 空格
///   TYPE    左对齐宽度 17  （"S9(7)V99 COMP-3" 长 15，右补 2 空格）`n///   2 空格 → NAME 从第 42 位开始
///   NAME    左对齐，无宽度上限
///
/// 标题行：`RECORD: ` + 记录名 + 右填充到第 49 位 + `LENGTH: ` + N + ` bytes`
///
/// 组项（中间层）**不出现**在报告里 —— 报告面向"能解码的字段"，
/// 组的字节已经由子项覆盖，列出来只会让偏移表变乱。这与 `layout.fields`
/// （仅叶子）一致。
pub fn render_layout(layout : RecordLayout) -> String {
  let sb = StringBuilder()
  // 标题行：记录名左对齐到第 49 列，然后 LENGTH
  sb.write_string("RECORD: ")
  sb.write_string(layout.name)
  let name_end = 8 + layout.name.length()
  // LENGTH 从第 49 列开始
  for i = name_end; i < 49; i = i + 1 {
    sb.write_char(' ')
  }
  sb.write_string("LENGTH: ")
  sb.write_string(layout.byte_length.to_string())
  sb.write_string(" bytes")
  sb.write_char('\n')
  sb.write_char('\n')
  // 表头
  sb.write_string(pad_left("OFFSET", 6))
  sb.write_string("  ")
  sb.write_string(pad_left("LENGTH", 6))
  sb.write_string("  ")
  sb.write_string(pad_left("OCCURS", 6))
  sb.write_string("  ")
  sb.write_string(pad_right("TYPE", 16))
  sb.write_string("  ")
  sb.write_string("NAME")
  sb.write_char('\n')
  // 数据行
  for field in layout.fields {
    sb.write_string(pad_left(field.offset.to_string(), 6))
    sb.write_string("  ")
    sb.write_string(pad_left(field.byte_length.to_string(), 6))
    sb.write_string("  ")
    sb.write_string(pad_left(field.occurs.to_string(), 6))
    sb.write_string("  ")
    sb.write_string(pad_right(pic_type_name(field.pic), 16))
    sb.write_string("  ")
    sb.write_string(field.path)
    sb.write_char('\n')
  }
  // 去掉末尾多余的换行：报告的行数应当恰好等于 2 + 1 + fields.length()
  // （标题、空行、表头、每个字段一行），最后一个字段行以 \n 结束即可。
  let s = sb.to_string()
  let n = s.length()
  if n > 0 && s[n - 1] == '\n' {
    s[:n - 1].to_owned()
  } else {
    s
  }
}
