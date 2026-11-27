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
    // COMP-2 超 `Double` 精度的值（CB-21）：数值列与 `Float` 完全一致，
    // 原始字节由 `__float_hex` 旁路单独携带（见 render_jsonl 末尾）。
    FloatRaw(f, _) =>
      if f != f {
        Json::string("NaN")
      } else if f == 1.0 / 0.0 {
        Json::string("Infinity")
      } else if f == -1.0 / 0.0 {
        Json::string("-Infinity")
      } else {
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
/// 字节串 → 小写十六进制（`__float_hex` / `__filler_hex` / `__tail_hex`
/// 三个旁路键共用同一表示，避免同一格式三处实现）。
fn bytes_to_hex_lower(bs : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < bs.length(); i = i + 1 {
    let v = bs[i].to_int()
    sb.write_string(hex_lower((v >> 4) & 0xF))
    sb.write_string(hex_lower(v & 0xF))
  }
  sb.to_string()
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
/// 空洞区间 → JSON 数组 `[[start, end], ...]`（B1，2026-11-12）。
///
/// 与 `__tail_hex` / `__filler_hex` 成对写出：字节序列本身说明「是什么」，
/// 区间说明「在哪里」。encode 端按区间做绝对位置映射，才能处理「部分视图
/// 解出 + 编辑」的任意形态——只带字节序列时，长度只能证明字节数对，证明
/// 不了位置对；快照长度恰好等于超集长度时会静默写到错误偏移上。
fn gap_intervals_json(gaps : Array[(Int32, Int32)]) -> Json {
  let arr : Array[Json] = []
  for (s, e) in gaps {
    arr.push(
      Json::array([
        Json::number(s.to_double(), repr=s.to_string()),
        Json::number(e.to_double(), repr=e.to_string()),
      ]),
    )
  }
  Json::array(arr)
}

///|
/// 计算一条记录里「只有重定义视图覆盖」的**尾部**字节区间（所有主视图字段
/// 结束之后、记录长度之前的部分，见 encode 层 `primary_tail_gaps`），并从
/// `row` 携带的原始记录字节（`__record_bytes`，由宽容解码在布局存在尾部
/// 空洞时写入）中取出这段字节，渲染为小写十六进制串。
///
/// **同时返回区间几何**（B1）：只有字节序列时 encode 无法把快照映射回原偏移。
///
/// 返回 `None` 的情形：没有尾部空洞 / 空洞字节全为 0x40（未赋值工作存储区
/// 惯例，不携带信息）/ 没有原始字节信息（手写 JSON、非 decode 来源——
/// encode 会按惯例写 0x40）。全 0x00 **会**带出：0x00 与 0x40 字节不同，
/// 静默改写同样是数据损坏。
fn layout_tail_gap_bytes(
  layout : RecordLayout,
  row : Map[String, CellValue],
) -> (String, Array[(Int32, Int32)])? {
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
  Some((sb.to_string(), gaps))
}

///|
/// 中部空洞旁路（P1-2）：FILLER 占据的区间（或手工布局的裂缝）不属于
/// 任何字段，decode 结果里没有承载，JSONL 必须把它带出去才能字节保真。
/// 与 layout_tail_gap_bytes 同一手法：区间并集 → 从 `__record_bytes`
/// 取字节 → 小写十六进制；全 0x40（未赋值工作存储区惯例）不携带。
/// **同时返回区间几何**（B1），理由同上。
fn layout_filler_gap_bytes(
  layout : RecordLayout,
  row : Map[String, CellValue],
) -> (String, Array[(Int32, Int32)])? {
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
  Some((sb.to_string(), gaps))
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
      // 取值口径与 encode_field / parse_jsonl_row / field_will_write 同一个
      // `field_value`（C4）：完整路径 → 裸路径 → 裸名，裸键只服务第一项。
      let v = match field_value(field, row) {
        Some(x) => x
        None => Null
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
      let v = match field_value(field, row) {
        Some(x) => x
        None => Null
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
    // **超精度浮点旁路**（CB-21）：IBM HFP `COMP-2` 的尾数是 56 位，
    // `Double` 只有 53 位。低 3 位非零的值读进 `Double` 会被舍入，重新
    // 编码就写不回原字节（`41 80 00 00 00 00 00 01` → `...00`），
    // 「L1 字节级往返」在这类字段上不成立。
    //
    // 与 `__nibbles` 同一手法：`{"字段路径": "<hex 原始字节>"}`。
    // encode 前由 parse_jsonl_row 还原成 `FloatRaw`，encode 优先写回原字节。
    // 只有真的超出 `Double` 精度的字段才写这个键——绝大多数记录的 JSONL
    // 输出保持不变。
    let floats : Map[String, Json] = Map([])
    for field in layout.fields {
      let v = match field_value(field, row) {
        Some(x) => x
        None => Null
      }
      match v {
        FloatRaw(_, raw) =>
          floats[field.path] = Json::string(bytes_to_hex_lower(raw))
        _ => ()
      }
    }
    if floats.size() > 0 {
      obj["__float_hex"] = Json::object(floats)
    }
    // **尾部字节旁路**（CB-9）：REDEFINES 视图可以比主视图长（布局层把记录
    // 延长到 max(主, 视图)），而宽容解码对解不出的重定义视图置 Null、encode
    // 又跳过 Null 视图——于是「只有重定义视图覆盖」的尾部字节没有任何载体，
    // 重编码时被 Writer 初始的 0x40 静默改写（`12 3C FF EE` → `12 3C 40 40`）。
    // 与 __nibbles 同一手法：用保留键 `__tail_hex` 把这段字节以十六进制带出，
    // encode 前由 parse_jsonl_row 还原。全 0x40（未赋值工作存储区惯例）不携带
    // 信息，跳过——普通记录的 JSONL 输出保持不变。
    let tail = layout_tail_gap_bytes(layout, row)
    if tail is Some((hex, gaps)) {
      obj["__tail_hex"] = Json::string(hex)
      // **几何旁路**（B1，2026-11-12）：光有字节序列，encode 只能比长度，比
      // 不了位置——快照长度恰好等于超集长度时会被摊到错误偏移上（静默错位），
      // 落在两者之间时又直接报错。区间把「在哪里」一起带出去。
      obj["__tail_gap"] = gap_intervals_json(gaps)
    }
    // **中部空洞旁路**（P1-2）：FILLER 占字节但不进输出（布局层契约），
    // 这段字节在字段值里没有载体，重编码时会被 Writer 初始的 0x40 静默
    // 替换（C1 C2 C3 C4 C5 C6 → C1 C2 40 40 C5 C6，verify 自身 exit 1）。
    // 与 __tail_hex 同一手法：`__filler_hex` 按偏移序携带空洞字节，
    // parse_jsonl_row / encode_record 回填。全 0x40 不携带——普通记录
    // （无 FILLER 或 FILLER 全空格）的 JSONL 输出保持不变。
    let filler = layout_filler_gap_bytes(layout, row)
    if filler is Some((hex, gaps)) {
      obj["__filler_hex"] = Json::string(hex)
      obj["__filler_gap"] = gap_intervals_json(gaps)
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
    // **全 FILLER 布局要能辨识**（C12，2026-11-17 审计）：`01 R. 05 FILLER
    // PIC X(4).` 是合法布局（`byte_length = 4`、`fields` 为空），JSONL 路径由
    // `__filler_hex` 承载（`all_filler_test.mbt` 已锁）。表格是给人看的输出，
    // 返回空串会让 CLI 打印一个空行、exit 0 —— 与「没有记录 / 命令没生效」
    // 不可区分。给一行说明并保留 exit 0（布局合法、解码成功，不是错误）。
    return "(no value fields; \{layout.byte_length} byte(s) of FILLER)\n"
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
      // 取值口径与 encode_field / parse_jsonl_row / render_jsonl /
      // field_will_write 同一个 `field_value`（C4 + 2026-11-17-b 审计）：
      // 完整路径 → 裸路径 → 裸名，且裸键只服务第一项。
      //
      // 这里是 C4 的**第五份拷贝**：旧实现自己写了一段
      // `row.get(field.path)` → `row.get(field.name)`，于是同一行数据在
      // 表格与 JSONL 上给出互相矛盾的结论 —— `{"A":"5"}` 让 `A OCCURS 3`
      // 的三个元素全显示 5（JSONL 是 5/null/null），而 `{"R.A":"7"}`
      // （裸路径，同样是第一项的后备）在表格里完全不认、三列全空。
      let v = match field_value(field, row) {
        Some(x) => x
        None => Null
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

///|
/// 有 `count` 个字段声明了 `SYNC` / `SYNCHRONIZED` 时的**唯一**警告文案。
///
/// 这句话此前只长在 `render_layout` 里，于是**只有 `layout` 子命令会出声**
/// （CB-20-1，2026-11-28 审计）：`verify` / `decode` / `encode` 读到同一份
/// 带 SYNC 的布局时一个字都不提。危害正是 NEW-4 当初要拦的那一条 ——
/// 本子集不做 IBM 半字/全字对齐，这份偏移拿去读主机数据时每个 COMP 数值
/// 都是错位解出的错误值，而 verify 抓不到（布局自洽、往返当然一致）。
/// 判据只有一个实现：CLI 的其余三个子命令都从 `render_layout` 这里取同一句，
/// 免得「文案在 A、判定在 B」再分裂一次。
///
/// 返回**不带**结尾换行的单行文本；`count == 0` 时返回空串（调用方据此
/// 决定是否打印）。
pub fn layout_sync_warning(count : Int32) -> String {
  if count <= 0 {
    return ""
  }
  "WARNING: \{count} field(s) declare SYNC/SYNCHRONIZED. This subset does not implement IBM half-word/full-word alignment: offsets above are computed without padding, so they differ from what a real z/OS compiler produces. Do not use this layout to read host data containing SYNC fields."
}

///|
/// 组上声明了 `SYNC` / `SYNCHRONIZED`、但组内一个基本项都没被点亮的警告
/// （CB-21-2，2026-11-29）。
///
/// 与 `layout_sync_warning` 分开是有意的：那条说的是「N 个字段受影响，偏移
/// 与 IBM 不同，别拿去读主机数据」；这条说的是「你写了 SYNC，但它什么也没
/// 影响」。合成一句会让 `affected_leaves == 0` 的情形报出「0 field(s)
/// declare ...」，比不说更糟。文案只有一个实现：CLI 的 stderr 与

///|
/// 「布局里有空洞」的**汇总告警文案** —— 只有一个实现（CB-21-3，2026-11-29）。
///
/// 空洞指记录里没有任何字段承载、只能靠旁路键保真的字节（FILLER 中部区，
/// 或只有重定义视图覆盖、而该视图解不出的尾部区）。本工具内部可以逐字节往返
/// （`verify` 的 `__record_bytes` 会回填），但**离开 `decode → JSONL → encode`
/// 这条侧道**（手写 JSONL、外部工具过滤 `__` 键、把值喂给下游系统），这几个
/// 字节就没有来源、会落回 `0x40`。四个子命令此前没有一处提过这件事。
///

///|
/// 布局**静态**空洞：无论行值如何、都不会被任何字段写到的字节区间
/// （CB-21-3，2026-11-29）。
///
/// 两种来源：
///   · **FILLER 区 / 叶子之间的裂缝**（`filler_gaps(layout, None)`）；
///   · **主视图末端之外的区间**（`primary_tail_gaps(layout, None)`）。
///
/// 与 `gap_carrier_report` 的关系：那个函数按**具体行值**算「某个视图这次
/// 有没有写」，本函数拿不到行值，所以问的是「全视图都不写时的洞」= 上界。
/// 两者共用同一对底层函数（`filler_gaps` / `primary_tail_gaps`），不重复实现
/// 区间逻辑；区别只在 `values` 传 `None` 还是 `Some(row)`。
pub fn layout_static_gaps(layout : RecordLayout) -> Array[(Int32, Int32)] {
  let out : Array[(Int32, Int32)] = []
  for iv in primary_tail_gaps(layout, None) {
    out.push(iv)
  }
  for iv in filler_gaps(layout, None) {
    out.push(iv)
  }
  out.sort_by(fn(x, y) { x.0 - y.0 })
  out
}

///|
/// `gaps` 为空时返回空串（调用方据此决定是否打印）。
pub fn layout_hole_warning(gaps : Array[(Int32, Int32)]) -> String {
  if gaps.length() == 0 {
    return ""
  }
  let mut total = 0
  let sb = StringBuilder()
  sb.write_string("warning: this layout has \{gaps.length()} hole segment(s), ")
  let mut first = true
  for (s, e) in gaps {
    total = total + (e - s)
    if first {
      sb.write_string("\{e - s} byte(s) at ")
      first = false
    } else {
      sb.write_string(", \{e - s} byte(s) at ")
    }
    sb.write_string("[\{s},\{e})")
  }
  ignore(total)
  sb.write_string(
    ": no field in the copybook covers these bytes. They survive only through the bypass keys (__tail_hex / __filler_hex / __record_bytes) carrying them out of decode; once that side channel is gone (hand-written JSONL, a tool that strips __ keys, values fed to another system) those bytes silently become 0x40. That is a space character in EBCDIC, so the damaged record still looks valid.",
  )
  sb.to_string()
}

///|
/// `render_layout` 的报告共用它。
pub fn layout_sync_inert_warning(paths : Array[String]) -> String {
  let joined = paths.join(", ")
  "WARNING: \{paths.length()} group item(s) declare SYNC/SYNCHRONIZED but contain no basic item: \{joined}. No offset changes; the declaration has no effect on this layout."
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
///   TYPE    左对齐宽度 16  （"S9(7)V99 COMP-3" 长 15，右补 1 空格）
///   2 空格 → NAME 从第 42 位开始（24 + 16 + 2）
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
  //
  // **SYNC 计数读布局层的唯一权威**（CB-21-2，2026-11-29）：此前这里自己
  // `let mut synced_count = 0` 数叶子，而 CLI 的 stderr 警告另扫源文本 ——
  // 两个数字在组级 SYNC、多处 SYNC、空组 SYNC 上都对不上。现在两边都读
  // `layout.sync_summary()`，逐行标注也用它的 `affected_leaves` 校验。
  let sync = layout.sync_summary()
  let mut unreportable_count = 0
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
    // **PIC 数值域警告**（2026-11-21 审计）：手建 PicClause 的 scale 越出
    // [-18, 18] 或位数为负时，`pic_type_name` 不再逐位展开（否则是挂死/
    // 溢出崩溃，或把尾随 P 静默吞掉），而是回一行 `<PIC out of range>`。
    // 这里逐行标注 + 末尾汇总，让"这份布局本工具其实不接受"当场可见：
    // decode/encode 对同一份布局会报 InvalidNumeric。
    if !pic_is_reportable(field.pic) {
      unreportable_count = unreportable_count + 1
      sb.write_string("   [PIC: out of supported decimal domain]")
    }
    // **SYNC 警告**（NEW-4，2026-11-04 审计）：
    // `SYNC` / `SYNCHRONIZED` 在 IBM 上是**对齐要求**——带 SYNC 的 COMP 字段
    // 必须落在半字/全字边界上，它前面的字段因此可能被填充（记录变长）。
    // 本子集不实现对齐（见 `FieldLayout.is_synced`），所以这份 copybook 的
    // 偏移与真实 IBM 布局不同：拿它去读主机数据，每个 COMP 数值都会是错位
    // 解出的错误值，而 verify 抓不到（布局自洽，往返当然一致）。
    // 这里逐行标注，让使用者当场看见，而不是静默给出看起来权威的错布局。
    if field.is_synced {
      sb.write_string(
        "   [SYNC: alignment not implemented, offsets differ from IBM]",
      )
    }
    sb.write_char('\n')
  }
  if sync.affected_leaves > 0 || sync.inert_groups.length() > 0 {
    sb.write_char('\n')
    if sync.affected_leaves > 0 {
      sb.write_string(layout_sync_warning(sync.affected_leaves))
      sb.write_char('\n')
    }
    // 组级 SYNC 没有作用对象（CB-21-2）：源文件里写了，但一个基本项都没被
    // 点亮 —— 不能报「N field(s)」却一行都不标，也不能沉默。
    if sync.inert_groups.length() > 0 {
      sb.write_string(layout_sync_inert_warning(sync.inert_groups))
      sb.write_char('\n')
    }
  }
  if unreportable_count > 0 {
    sb.write_char('\n')
    sb.write_string(
      "WARNING: \{unreportable_count} field(s) carry a PIC outside the supported decimal domain (scale beyond [-18, 18] or negative digit counts). decode/encode reject such a layout with InvalidNumeric; their TYPE column above shows the raw triple instead of a PIC type.\n",
    )
  }
  // 去掉末尾多余的换行：报告的行数应当恰好等于 2 + 1 + fields.length()

  // **空洞的机读汇总**（CB-21-3，2026-11-29）：FILLER 区与主视图之外的区间
  // 在报告里**不出现**（它们不是字段），但它们的字节只靠旁路键保真。脚本要
  // 能判断「这份布局有没有洞」，所以给一行固定格式；无洞时不追加。
  // 这是**静态**洞（与行值无关），JSONL 侧的动态洞另由 decode 的旁路键体现。
  let static_gaps = layout_static_gaps(layout)
  if static_gaps.length() > 0 {
    let mut hole_bytes = 0
    for (hs, he) in static_gaps {
      hole_bytes = hole_bytes + (he - hs)
    }
    sb.write_char('\n')
    sb.write_string(
      "HOLES: \{static_gaps.length()} segment(s), \{hole_bytes} byte(s)",
    )
    sb.write_char('\n')
  }
  // （标题、空行、表头、每个字段一行），最后一个字段行以 \n 结束即可。
  let s = sb.to_string()
  let n = s.length()
  if n > 0 && s[n - 1] == '\n' {
    s[:n - 1].to_owned()
  } else {
    s
  }
}
