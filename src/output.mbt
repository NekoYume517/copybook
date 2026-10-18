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
        Json::number(f, repr=f.to_string())
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
