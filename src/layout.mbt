// 字节布局计算 —— 把 copybook 语法树编译成带绝对偏移的字段表
//
// ## 这一层为什么最容易错
//
// COBOL 记录的"长度"不是各字段 PIC 长度之和。有四个独立机制在改写偏移：
//
//   1. **层级号（01..49）**：数字越小层级越高。一个层级更低的项出现时，
//      当前组**闭合**，父组继续往后排。常见 bug：把 05 之后出现的 01 当成兄弟。
//
//   2. **REDEFINES**：被重定义的字段**从目标字段的起始偏移重新开始**，
//      并且**不推进**记录游标。等价于 C 的 `union`。常见 bug：把两块长度相加。
//
//   3. **OCCURS**：组出现 n 次，组内所有子项的偏移是**相对于组第 0 次出现**的。
//      单个元素长度 × n 才是占用空间。常见 bug：只算一次，或把子项偏移乘以 n。
//
//   4. **冗余的隐式填充**：本实现**不做**隐式对齐填充（COBOL 也没有；
//      对齐靠 SYNCHRONIZED 子句显式声明，本子集不支持）。
//
// ## 长度公式的统一表达
//
// 所有数值类的字节数都能写成同一个式子，见 `pic_byte_length`：
//
//   Display 文本类（X/A）：       digits
//   Display 国家字符（N）：       digits * 2
//   Display 数值（zoned）：       digits + scale        （符号覆盖末位，不加字节）
//   COMP 二进制：                 <=4 → 1, <=9 → 2, <=18 → 4
//   COMP-3 打包：                 ceil((digits + scale + 1) / 2)
//   SIGN SEPARATE：               +1（只对 Display 数值类）
//
// `9(n)` 的 zoned 长度是 n 而不是 ceil(n/2)，因为**每位占一个完整字节**：
// 每字节低半字节是数字，高半字节是 0xF（未符号化）或符号（末字节）。

///|
/// 单个字段的布局结果。
///
/// `offset` 是**绝对**偏移（记录起点为 0），已经包含所有外层 OCCURS 的基址与
/// 所有外层组的起始位置。`byte_length` 是**单个元素**的长度（不含 OCCURS）；
/// `total_length == byte_length * occurs`。
///
/// 组项（中间层）也有 FieldLayout：`byte_length` 是组**单次出现**的总长，
/// 但它的 `pic` 是合成的（见 `group_pic`），这样 `render_layout` 与
/// `decode` 都能统一按 `pic.usage == Display && category == Alphanumeric` 处理。
pub(all) struct FieldLayout {
  name : String
  path : String
  offset : Int32
  byte_length : Int32
  occurs : Int32
  total_length : Int32
  pic : PicClause
  level : Int32
  redefine_group : Int32
}

///|
/// 整条记录的布局。
///
/// `fields` 只含**叶子**字段（真正承载数据、可以直接解码的项），按 offset 排序。
/// `all_fields` 含中间层，按 offset 稳定排序（同偏移时层级深的在后）。
///
/// **注意**：REDEFINES 的成员在 `fields` 里保留全部成员（同一偏移会有多条），
/// 因为解码时可能想同时看两种视图。`byte_length` 只按"最大并集"累计一次。
pub(all) struct RecordLayout {
  name : String
  byte_length : Int32
  fields : Array[FieldLayout]
  all_fields : Array[FieldLayout]
}

///|
/// 计算单个 PIC 子句占用的字节数。
///
/// 这是全项目最核心的一张表，逐项对应 API.md 第 3 节：
///
/// | PIC              | Usage   | 字节数                          |
/// |------------------|---------|---------------------------------|
/// | X(n) / A(n)      | Display | n                               |
/// | N(n)             | Display | n * 2                           |
/// | 9(n)             | Display | n        （zoned，一位一字节）   |
/// | S9(n)            | Display | n        （符号覆盖末位）        |
/// | 9(n)             | COMP    | n<=4→1, n<=9→2, n<=18→4         |
/// | 9(n)V9(m)        | COMP-3  | ceil((n+m+1)/2)                 |
/// | 9(n)             | COMP-3  | ceil((n+1)/2)                   |
/// | COMP-1 / COMP-2  | -       | 4 / 8                           |
/// | 任意 + SEPARATE  | Display | +1                              |
///
/// `digits` 对数值类是**整数位**，对字符类是**字符数**；总位数 = digits + scale。
fn pic_byte_length(pic : PicClause) -> Int32 raise ParseError {
  let total_digits = pic.digits + pic.scale
  match pic.category {
    National => {
      // 国家字符（UTF-16）在 EBCDIC 记录里是双字节，n 个字符 → 2n 字节。
      guard pic.scale == 0 else {
        raise InvalidLayout("PIC N: scale must be 0, got scale=\{pic.scale}")
      }
      pic.digits * 2
    }
    Alphabetic | Alphanumeric => {
      guard pic.scale == 0 else {
        raise InvalidLayout("PIC X/A: scale must be 0, got scale=\{pic.scale}")
      }
      match pic.usage {
        Display => {
          let base = pic.digits
          if pic.sign_separate {
            base + 1
          } else {
            base
          }
        }
        _ =>
          raise InvalidLayout(
            "PIC X/A cannot use numeric USAGE (COMP/COMP-3/COMP-1/COMP-2)",
          )
      }
    }
    // 编辑型 PIC（ZZ,ZZ9.99 / $9,999.99 / 9(5)CR）的存储宽度 = **模式串展开后的
    // 显示字符数**（含 $ , . CR/DB + - 这些插入字符）。
    //
    // 不能用 `digits + scale`：`ZZ,ZZ9.99` 的 digits=5 scale=2 → 7，但实际显示
    // 宽度是 9（多了逗号和小数点两个插入字符）。parser 的 `pic_storage_len`
    // 正是为此提供：把 `(n)` 展开后数长度。
    Edited => pic_storage_len(pic.pic_text)
    Numeric =>
      match pic.usage {
        Display => {
          // zoned decimal：每一位一个字节，符号盖在最后一字节的高半字节上。
          let base = total_digits
          if pic.sign_separate {
            base + 1
          } else {
            base
          }
        }
        Comp =>
          // 二进制：容量由**总位数**决定（含小数位，整个数值是一个整数）。
          if total_digits <= 4 {
            1
          } else if total_digits <= 9 {
            2
          } else if total_digits <= 18 {
            4
          } else {
            raise InvalidLayout(
              "COMP supports at most 18 digits, got \{total_digits}",
            )
          }
        // 打包十进制：两个数字挤一字节，末尾半字节放符号 →
        // 需要 total_digits + 1 个半字节，向上取整到字节。
        Comp3 => (total_digits + 2) / 2
        Comp1 => 4
        Comp2 => 8
      }
  }
}

///|
/// 为组项合成一个"伪 PIC"。
///
/// 组项本身没有 PIC，但 `FieldLayout.pic` 是非可空的。合成一个
/// `X(byte_length) DISPLAY` 让上层（render_layout / decode）不必对组特判：
/// 组的字节数已经算好，按字符字段处理即可（组不直接解码）。
fn group_pic(byte_length : Int32) -> PicClause {
  let sb = StringBuilder()
  sb.write_string("X(")
  sb.write_string(byte_length.to_string())
  sb.write_string(")")
  {
    category: Alphanumeric,
    digits: byte_length,
    scale: 0,
    signed: false,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    pic_text: sb.to_string(),
  }
}

///|
/// 把 PIC 子句渲染成人类可读的类型串（用于 layout 报告）。
///
/// 输出格式必须与 API.md 一致：
///   `9(8) DISPLAY`、`X(30) DISPLAY`、`S9(7)V99 COMP-3`
///
/// 规则：
///   - Numeric: `S`? `9(digits)` (`V` + 9^scale)? 空格 usage
///   - X/A:     `X(n)` 空格 DISPLAY（A 也渲染成 A(n)，保留可读差异）
///   - N:       `N(n)` 空格 DISPLAY
///   - Edited:  原样 digits 位占位，附 EDIT
pub fn pic_type_name(pic : PicClause) -> String {
  let sb = StringBuilder()
  match pic.category {
    Alphanumeric => {
      sb.write_string("X(")
      sb.write_string(pic.digits.to_string())
      sb.write_string(")")
    }
    Alphabetic => {
      sb.write_string("A(")
      sb.write_string(pic.digits.to_string())
      sb.write_string(")")
    }
    National => {
      sb.write_string("N(")
      sb.write_string(pic.digits.to_string())
      sb.write_string(")")
    }
    Edited => {
      sb.write_string("EDITED(")
      sb.write_string(pic.digits.to_string())
      sb.write_string(")")
    }
    Numeric => {
      if pic.signed {
        sb.write_string("S")
      }
      sb.write_string("9(")
      sb.write_string(pic.digits.to_string())
      sb.write_string(")")
      if pic.scale > 0 {
        sb.write_string("V")
        for i = 0; i < pic.scale; i = i + 1 {
          sb.write_string("9")
        }
      }
    }
  }
  sb.write_string(" ")
  sb.write_string(
    match pic.usage {
      Display => "DISPLAY"
      Comp => "COMP"
      Comp3 => "COMP-3"
      Comp1 => "COMP-1"
      Comp2 => "COMP-2"
    },
  )
  sb.to_string()
}

///|
/// 累加器：编译过程中的可写状态。
///
/// 用结构体而不是多个局部变量，是因为 REDEFINES 需要"回退游标到目标字段的起点"，
/// 需要同时访问：当前游标、已产出的叶子列表、名字→偏移索引。
priv struct Builder {
  mut cursor : Int32
  leaves : Array[FieldLayout]
  all : Array[FieldLayout]
  by_name : Map[String, Int32]
}

///|
/// 预扫描：为每个 REDEFINES 组分配统一 id。
///
/// **目标字段和重定义视图拿到同一个 id**（组 id 描述的是"这段字节被复用"这件事，
/// 不是"谁是原主"）。这样调用方按 `redefine_group != 0` 就能找出所有共享视图，
/// 而不需要知道谁先谁后。
///
/// 若 A REDEFINES B、C 也 REDEFINES B，则 A/B/C 三个字段共享同一个 id。
/// 若 D REDEFINES A（嵌套重定义），同样归入该 id。
///
/// 返回：小写字段名 → 组 id（从 1 开始）。
fn collect_redefine_groups(specs : Array[FieldSpec]) -> Map[String, Int32] {
  let groups : Map[String, Int32] = Map([])
  let mut next_id = 1
  // 反复扫描直到不再新增，以处理"重定义链"（D→A→B）的顺序无关性。
  let mut changed = true
  while changed {
    changed = false
    let pending : Array[FieldSpec] = []
    collect_flat(specs, pending)
    for spec in pending {
      match spec.redefines {
        Some(target) => {
          let t = target.to_lower()
          let s = spec.name.to_lower()
          if !groups.contains(t) && !groups.contains(s) {
            // 全新的一组：目标与视图同时登记。
            groups[t] = next_id
            groups[s] = next_id
            next_id = next_id + 1
            changed = true
          } else if groups.contains(t) && !groups.contains(s) {
            groups[s] = groups[t]
            changed = true
          } else if !groups.contains(t) && groups.contains(s) {
            groups[t] = groups[s]
            changed = true
          }
        }
        None => ()
      }
    }
  }
  groups
}

///|
/// 把（可能嵌套的）spec 树摊平成数组，便于预扫描。
fn collect_flat(specs : Array[FieldSpec], out : Array[FieldSpec]) -> Unit {
  for spec in specs {
    out.push(spec)
    collect_flat(spec.children, out)
  }
}

///|
/// 编译一个字段（递归）。
///
/// **偏移完全由 `b.cursor` 驱动**，不使用"父组累加子项长度"的写法 ——
/// 后者一旦遇到 REDEFINES 就会把共享字节重复计入（开发时真实踩到的 bug：
/// `redefines.cpy` 算成 35 而非 29）。
///
/// 规则：
///   - 普通字段：起点 = 当前 cursor，结束后 cursor = 起点 + 跨度。
///   - REDEFINES 字段：先存 `save = cursor`，把 cursor 挪到目标字段偏移，
///     编译自身得到跨度，最后 `cursor = max(save, target + span)`。
///     这样"重定义视图比原字段更长"时记录会正确延长，短则不变。
///   - 组：起点 = cursor，递归子项，组单次跨度 = 递归后的 cursor - 起点。
///
/// `group_id` 由 `collect_redefine_groups` 预先分配好；0 表示不参与重定义。
///
/// 返回值是该字段**单次出现**占用的字节数。
fn compile_field(
  b : Builder,
  spec : FieldSpec,
  path_prefix : String,
  groups : Map[String, Int32],
  inherited_group : Int32,
) -> Int32 raise ParseError {
  let save = b.cursor
  // 自身被登记为重定义成员则用自身 id，否则继承父组 id（REDEFINES 组的子项
  // 与组本身共享同一段字节，必须标同一个组）。
  let group_id = match groups.get(spec.name.to_lower()) {
    Some(id) => id
    None => inherited_group
  }
  // REDEFINES：把游标挪回目标字段的偏移，让两者共享同一段字节。
  match spec.redefines {
    Some(target_name) => {
      let key = target_name.to_lower()
      match b.by_name.get(key) {
        Some(target_offset) => b.cursor = target_offset
        None =>
          raise InvalidLayout(
            "REDEFINES target '\{target_name}' not found (line \{spec.line})",
          )
      }
    }
    None => ()
  }
  let field_base = b.cursor
  let path = if path_prefix == "" {
    spec.name
  } else {
    path_prefix + "." + spec.name
  }
  let occurs = if spec.occurs <= 0 { 1 } else { spec.occurs }
  // FILLER：COBOL 语义是「占字节但不进输出」——必须推进游标、参与布局，
  // 但不能进入 fields（否则它会出现在解码结果里，且多个 FILLER 会撞同一个
  // map 键）。把它登记进 all_fields（render_layout 的中间层视图仍可见其占位
  // 结构）但不进 leaves，组项转发逻辑不受影响。
  let is_filler = spec.name == "FILLER"
  let span = match spec.pic {
    Some(pic) => {
      // 叶子字段：按 PIC 公式算单元素长度。
      let len = pic_byte_length(pic)
      let total = len * occurs
      let fl = FieldLayout::{
        name: spec.name,
        path,
        offset: field_base,
        byte_length: len,
        occurs,
        total_length: total,
        pic,
        level: spec.level,
        redefine_group: group_id,
      }
      if !is_filler {
        b.leaves.push(fl)
      }
      b.all.push(fl)
      if !is_filler {
        b.by_name[spec.name.to_lower()] = field_base
        b.by_name[path.to_lower()] = field_base
      }
      b.cursor = field_base + total
      total
    }
    None => {
      // 组项：递归子项，组单次跨度 = 组内游标推进量。
      for child in spec.children {
        let _ = compile_field(b, child, path, groups, group_id)
      }
      let inner = b.cursor - field_base
      let total = inner * occurs
      let fl = FieldLayout::{
        name: spec.name,
        path,
        offset: field_base,
        byte_length: inner,
        occurs,
        total_length: total,
        pic: group_pic(inner),
        level: spec.level,
        redefine_group: group_id,
      }
      b.all.push(fl)
      b.by_name[spec.name.to_lower()] = field_base
      b.by_name[path.to_lower()] = field_base
      b.cursor = field_base + total
      total
    }
  }
  // REDEFINES 成员不延长记录：只有当自身跨度超出原字段时才延长。
  if group_id != 0 && spec.redefines is Some(_) {
    let end = field_base + span
    b.cursor = if end > save { end } else { save }
  }
  span
}

///|
/// 把一整个 copybook（`Array[FieldSpec]`，每个 01 一项）编译成 `RecordLayout`。
///
/// 取**第一个** 01 作为记录名与主体；若存在多个 01，其余 01 视为独立的记录，
/// 但 `RecordLayout` 只能容纳一条 —— 因此本实现把后续 01 当作**并列拼接**
/// （偏移连续），并在 `all_fields` 里保留全部。这与 COBOL 一个文件多记录型的
/// 语义不同，是刻意的简化：`compile_layout` 的契约是"一条记录一份布局"。
pub fn compile_layout(
  specs : Array[FieldSpec],
) -> RecordLayout raise ParseError {
  if specs.length() == 0 {
    raise InvalidLayout("empty copybook: no fields")
  }
  let groups = collect_redefine_groups(specs)
  let b = Builder::{ cursor: 0, leaves: [], all: [], by_name: Map([]), }
  let mut record_name = ""
  for spec in specs {
    if record_name == "" {
      record_name = spec.name
    }
    let _ = compile_field(b, spec, "", groups, 0)
  }
  // 叶子按偏移排序（稳定：同偏移保持定义顺序，便于 REDEFINES 可预测）
  let leaves = b.leaves
  let sorted_leaves : Array[FieldLayout] = []
  for f in leaves {
    sorted_leaves.push(f)
  }
  sorted_leaves.sort_by(fn(x, y) {
    if x.offset != y.offset {
      x.offset - y.offset
    } else {
      0
    }
  })
  let sorted_all : Array[FieldLayout] = []
  for f in b.all {
    sorted_all.push(f)
  }
  sorted_all.sort_by(fn(x, y) {
    if x.offset != y.offset {
      x.offset - y.offset
    } else {
      x.level - y.level
    }
  })
  RecordLayout::{
    name: record_name,
    byte_length: b.cursor,
    fields: sorted_leaves,
    all_fields: sorted_all,
  }
}

///|
/// 按名字查字段，大小写不敏感，支持 `RECORD.FIELD.SUB` 点分路径。
///
/// 查找顺序：
///   1. 完全匹配 path（大小写不敏感）
///   2. 完全匹配 name（大小写不敏感）
///   3. 后缀匹配：`NAME` 能命中 `RECORD.GROUP.NAME`
///
/// 后缀匹配是为了让 CLI 的 `--field CUST-ID` 这类简写可用，同时不牺牲精确性：
/// 若后缀命中多个，返回**第一个**（按 offset 排序），不做歧义报错 —— 这是
/// 查询辅助函数，不是数据入口。
pub fn RecordLayout::find(
  self : RecordLayout,
  name : StringView,
) -> FieldLayout? {
  let needle = name.to_owned().to_lower()
  for f in self.all_fields {
    if f.path.to_lower() == needle {
      return Some(f)
    }
  }
  for f in self.all_fields {
    if f.name.to_lower() == needle {
      return Some(f)
    }
  }
  let suffix = "." + needle
  for f in self.all_fields {
    if f.path.to_lower().has_suffix(suffix) {
      return Some(f)
    }
  }
  None
}

///|
/// 记录内所有**可解码叶子**的字节区间总数（用于校验"无空隙、无重叠"）。
///
/// 仅供测试与 `verify` 自检使用：正常情况下它应当等于 `byte_length`。
/// REDEFINES 会让总和大于 byte_length（共享字节被数了两次），因此本函数
/// 按**偏移并集**计算。
pub fn RecordLayout::covered_bytes(self : RecordLayout) -> Int32 {
  let ivs : Array[(Int32, Int32)] = []
  for f in self.fields {
    ivs.push((f.offset, f.offset + f.total_length))
  }
  ivs.sort_by(fn(x, y) { x.0 - y.0 })
  let mut covered = 0
  let mut cur_start = -1
  let mut cur_end = -1
  for iv in ivs {
    let (s, e) = iv
    if s > cur_end {
      if cur_end > cur_start {
        covered = covered + (cur_end - cur_start)
      }
      cur_start = s
      cur_end = e
    } else if e > cur_end {
      cur_end = e
    }
  }
  if cur_end > cur_start {
    covered = covered + (cur_end - cur_start)
  }
  covered
}
