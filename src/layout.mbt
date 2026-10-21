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
//   COMP 二进制：                 <=4 → 2, <=9 → 4, <=18 → 8
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
  /// COMP-1 / COMP-2 的字节解释方式。
  ///
  /// 这是**数据源属性**（同一份 copybook 在不同主机上落盘字节不同），
  /// 不是字段属性，所以挂在 layout 上而不是 `PicClause` 上。
  /// 默认 `Hfp`（IBM z/OS 主机）；GnuCOBOL / Micro Focus 产物用 `Ieee754`。
  float_mode : FloatMode
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
/// | 9(n)             | COMP    | n<=4→2, n<=9→4, n<=18→8         |
/// | 9(n)V9(m)        | COMP-3  | ceil((n+m+1)/2)                 |
/// | 9(n)             | COMP-3  | ceil((n+1)/2)                   |
/// | COMP-1 / COMP-2  | -       | 4 / 8                           |
/// | 任意 + SEPARATE  | Display | +1                              |
///
/// `digits` 对数值类是**整数位**，对字符类是**字符数**；总位数 = digits + scale。
fn pic_byte_length(pic : PicClause) -> Int32 raise ParseError {
  // C10：存储位数用 storage_digits（P 不占存储）；数值语义的总位数
  // （digits + scale，含 P 的隐含位）只用于容量校验。
  let total_digits = pic.storage_digits
  match pic.category {
    National => {
      // NATIONAL 是 UTF-16BE，PIC N(n) 分配 n 个码元，即 2n 字节。
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
        Comp => {
          let width = comp_byte_width(total_digits)
          if width == 0 {
            raise InvalidLayout(
              "COMP supports 1..18 digits, got \{total_digits}",
            )
          }
          width
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
    storage_digits: byte_length,
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

///|
/// 带溢出检查的偏移加法（C9）。
///
/// \`PIC X(100000) OCCURS 100000\` 的真实跨度是 10^10，Int32 装不下，
/// 静默回绕成 1410065408 —— 一个看起来正常但完全错误的记录长度。
/// 偏移运算必须显式检查：布局是后续一切解码的基线，这里的错误
/// 传播到每一条记录。

///|
/// 带溢出检查的乘法（C9 配套）：跨度 = 单元素长度 × 出现次数。
/// 乘法必须先于加法受保护：10^10 在乘法处就已回绕，checked_offset
/// 看到的已是垃圾值。
fn checked_mul(
  len : Int32,
  occurs : Int32,
  what : String,
) -> Int32 raise ParseError {
  let total = len.to_int64() * occurs.to_int64()
  if total > 2147483647L {
    raise InvalidLayout(
      "\{what}: length \{len} x OCCURS \{occurs} exceeds Int32 (\{total}); reduce field sizes or OCCURS counts",
    )
  }
  total.to_int()
}

///|
fn checked_offset(
  base : Int32,
  span : Int32,
  what : String,
) -> Int32 raise ParseError {
  let total = base.to_int64() + span.to_int64()
  if total > 2147483647L {
    raise InvalidLayout(
      "\{what} exceeds Int32 offset range (\{base} + \{span}); reduce field sizes or OCCURS counts",
    )
  }
  total.to_int()
}

///|
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
      //
      // **叶子自带 OCCURS 也在这里摊平**（与组级摊平同一机制，回归修复）。
      // C1 修复只摊平了组级 OCCURS：组内叶子拿到 PATH(i) 键，而带自身
      // OCCURS 的叶子保留 path=R.A、occurs=3。decode_record_impl 看见
      // occurs>1 在运行时展开成 R.A(1..3)，但 render_jsonl / render_table
      // / encode 查的是裸 R.A —— 输出 {"R.A":null}、verify 字节不匹配、
      // encode 写空格。摊平必须只有一个权威实现，且发生在布局层：
      // 数据面四条路径（decode/render/jsonl/encode）就全部自动一致。
      let len = pic_byte_length(pic)
      let total = checked_mul(len, occurs, "field '\{spec.name}'")
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
      if occurs > 1 {
        // 展开成 occurs 份独立叶子：offset 逐元素推进，键带 1 起始下标，
        // occurs 归 1（数据面不再看到任何展开语义）。第 1 份同时登记
        // 裸路径别名（by_name），手写 JSON 用裸名仍能命中第一个元素。
        let mut k = 1
        while k <= occurs {
          let expanded : FieldLayout = {
            ..fl,
            offset: field_base + (k - 1) * len,
            path: "\{path}(\{k})",
            occurs: 1,
            total_length: len,
          }
          if !is_filler {
            b.leaves.push(expanded)
          }
          b.all.push(expanded)
          k = k + 1
        }
      } else {
        if !is_filler {
          b.leaves.push(fl)
        }
        b.all.push(fl)
      }
      if !is_filler {
        b.by_name[spec.name.to_lower()] = field_base
        b.by_name[path.to_lower()] = field_base
      }
      b.cursor = checked_offset(field_base, total, "field '\{spec.name}' span")
      total
    }
    None => {
      // 组项：递归子项，组单次跨度 = 组内游标推进量。
      //
      // **OCCURS n>1 的组必须把组内叶子展开成 n 份**（C1）。
      // 旧实现只在布局层算对总长度，数据面（decode/encode）面对的
      // leaves 里每组字段只有第 0 次出现的条目 —— `OCCURS 5` 的记录
      // 有 4/5 的数据被静默丢弃。
      //
      // 展开方法：记下递归前的叶子数，递归后得到单元素跨度 inner，
      // 把这批新叶子重写为 occurs 份 —— 第 i 份的 offset 加 i*inner，
      // 路径加 `(i)` 后缀（1 起始），occurs 归 1（下游不再需要展开）。
      // FieldLayout 是不可变值，但 Builder.leaves 是可变数组，可以
      // 在编译期整体替换。
      //
      // **下标序列**（R2）：嵌套 OCCURS 摊平必须把外层下标也带上。
      // 递归期间组内叶子已经携带了**内层**已拼好的下标后缀
      // （`...X(1)`、`...X(2)`，由更深的组写入），本层展开时要把
      // 本层下标拼在**最前**：leaf 的新后缀 = "(i)" + leaf 原后缀。
      // 展开顺序 = 存储顺序（外层先行、内层跟随），所以 offset 为
      // base + rel + (k-1)*inner。唯一权威实现收敛在布局层这里，
      // decode/render/encode 拿到的键名自动一致。
      let leaf_mark = b.leaves.length()
      let all_mark = b.all.length()
      for child in spec.children {
        let _ = compile_field(b, child, path, groups, group_id)
      }
      let inner = b.cursor - field_base
      let total = checked_mul(inner, occurs, "group '\{spec.name}'")

      // 摊平组级 OCCURS：把递归期间新增的每个叶子重写为 occurs 份。
      // 叶子分支已保证新叶子 occurs==1（叶子自带 OCCURS 同样在叶子分支
      // 摊平），所以这里的展开总是安全的。
      if occurs > 1 {
        let mut i = leaf_mark
        while i < b.leaves.length() {
          let leaf = b.leaves[i]
          if leaf.occurs > 1 {
            // 防御：不应到达；保留原样避免错位
            i = i + 1
            continue
          }
          // 该叶子在单元素组内的相对偏移
          let rel = leaf.offset - field_base
          // 剥出叶子既有的下标后缀（内层摊平写入的 "(j)(k)..."），
          // 本层下标插在最前：X(j) 展开为 X(k)(j) —— 外层→内层顺序。
          let (base_path, inner_suffix) = split_index_suffix(leaf.path)
          // 先移除原条目，再按出现序插入展开副本
          let _removed = b.leaves.remove(i)
          let mut k = 1
          while k <= occurs {
            let expanded : FieldLayout = {
              ..leaf,
              offset: field_base + rel + (k - 1) * inner,
              path: "\{base_path}(\{k})\{inner_suffix}",
              occurs: 1,
              total_length: leaf.byte_length,
            }
            b.leaves.insert(i + (k - 1), expanded)
            k = k + 1
          }
          // 数组增长了 occurs-1；下一个源条目位置相应后移
          i = i + occurs
        }
      }

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
      b.cursor = checked_offset(field_base, total, "group '\{spec.name}' span")
      // all_mark 之后新增的子项条目保持原样（渲染组结构用），
      // 但数据面只看 leaves，已经展开完毕。
      ignore(all_mark)
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
    float_mode: Hfp,
  }
}

///|
/// 指定浮点表示编译布局。
///
/// `COMP-1` / `COMP-2` 在 IBM 主机上是 HFP、在 GnuCOBOL / Micro Focus 上
/// 是 IEEE 754 —— 字节布局完全互不兼容（见 `hfp.mbt` 文件头对照表）。
/// 解码前必须先声明数据源属于哪一种，否则浮点字段会解出毫无意义的数。
pub fn compile_layout_with_float_mode(
  specs : Array[FieldSpec],
  float_mode : FloatMode,
) -> RecordLayout raise ParseError {
  let base = compile_layout(specs)
  { ..base, float_mode, }
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
/// 把路径尾部的 `(n)(m)...` 下标序列从名字里剥出来。
///
/// 返回 `(去掉下标后缀的主体, 原样的下标后缀)`。
/// `R.G1.G2.X(1)` → `("R.G1.G2.X", "(1)")`；`R.A` → `("R.A", "")`。
///
/// COBOL 字段名不可能含 `(`（词法层拒绝），所以路径里出现的所有
/// `(...)` 都来自摊平展开，从最后一个字符向前扫到第一个 `(` 即可。
/// COBOL 名也不能含 `.`，主体里不会再有歧义。
fn split_index_suffix(path : String) -> (String, String) {
  let cs = path.to_array()
  // 从尾向前：最后一段必须是 `(...)` 才算下标后缀
  if cs.length() == 0 || cs[cs.length() - 1] != ')' {
    return (path, "")
  }
  // 找与之配对的 `(`：后缀里不会再有嵌套括号（下标是纯数字）
  let mut j = cs.length() - 1
  let mut depth = 0
  let mut open = -1
  while j >= 0 {
    let c = cs[j]
    if c == ')' {
      depth = depth + 1
    } else if c == '(' {
      depth = depth - 1
      if depth == 0 {
        open = j
        break
      }
    }
    j = j - 1
  }
  if open < 0 {
    return (path, "")
  }
  // 继续向前：如果 `(` 之前紧跟 `)`，说明还有更多层下标（嵌套 OCCURS）
  let mut end = open
  while end > 0 && cs[end - 1] == ')' {
    // 向前找这一层的 `(`
    let mut d2 = 0
    let mut o2 = -1
    let mut k = end - 1
    while k >= 0 {
      let c = cs[k]
      if c == ')' {
        d2 = d2 + 1
      } else if c == '(' {
        d2 = d2 - 1
        if d2 == 0 {
          o2 = k
          break
        }
      }
      k = k - 1
    }
    if o2 < 0 {
      break
    }
    end = o2
  }
  let suffix = String::from_array(cs[end:cs.length()])
  let base = String::from_array(cs[:end])
  (base, suffix)
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

///|
/// IBM BINARY / COMP / COMP-4 storage width by decimal precision.
fn comp_byte_width(digits : Int32) -> Int32 {
  if digits < 1 || digits > 18 {
    0
  } else if digits <= 4 {
    2
  } else if digits <= 9 {
    4
  } else {
    8
  }
}
