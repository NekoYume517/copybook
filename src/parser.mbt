// Copybook 语法分析：PIC 子句解析 + 层级号建树
//
// ## COBOL 数据描述的整体形状
//
// 一份 copybook 就是一系列"数据描述项"（data description entry），每项以
// **层级号**（level number）开头，用句点收尾：
//
//     01  CUSTOMER-RECORD.
//         05  CUST-ID    PIC 9(8).
//         05  BALANCE    PIC S9(7)V99 COMP-3.
//         05  FLAGS.
//             10  ACTIVE PIC X(1).
//
// 层级号本身**不是**缩进、不是重复次数，而是**树深度的编码**：
//
//   - 层级号更大的项是"前面最近的、层级号更小的项"的子项；
//   - 层级号相同的项互为兄弟；
//   - 层级号更小的项回到上层。
//
// 这是 COBOL 唯一的结构表达方式 —— 缩进只是给人看的，编译器只看数字。
// 因此 `05` 之后出现 `10` 是子项，出现 `05` 是兄弟，出现 `01` 是新的记录。
//
// ## 组项 vs 基本项
//
// - 有 `PIC` 子句 → **基本项**（elementary item），有实际数据类型和长度；
// - 无 `PIC` 子句 → **组项**（group item），长度由子项求和决定。
//
// 基本项下面不能再挂子项，本实现对此**显式报错**（COBOL 也不允许）。
//
// ## 66 / 88 为什么不进树
//
// - `88` 是**条件名**（condition-name），挂在某个基本项下面，用 `VALUE`
//   列举该字段的合法取值，例如 `88 IS-ACTIVE VALUE 'Y'.`。它不占存储空间。
// - `66` 是 **RENAMES**，把一段连续字段重新命名成另一个视图，也不占空间。
//
// 二者都不是数据本身，混进 children 会让布局层把它们当成真实字段、
// 算出错误的字节偏移。所以本实现把它们**单独收集**
// （`parse_copybook_with_extras` / `parse_copybook_conditions`），
// 主树里只有 01..49 / 77 的数据项。
//
// ## 建树策略：先展平，再递归
//
// MoonBit 的 struct 是**值类型**：把节点 push 进父数组后再改 `node.children`
// 改不到数组里的那份副本。所以本实现不玩"压栈再回填"，而是两步走：
//
//   1. 扫描阶段把所有数据项解析成一个**扁平的** `Array[RawEntry]`（保持顺序）；
//   2. 建树阶段用 `level > parent_level` 做递归分界，纯函数式地组装出树。
//
// 第 2 步的判定很直接：一棵以 `parent_level` 为父的子树，就由「连续的、
// 层级号都 > parent_level 的项」组成；遇到第一个 `<= parent_level` 的项就收工。

///|
/// PIC 类别。`USAGE` 决定物理表示，`PIC` 类别决定逻辑含义。
pub(all) enum PicCategory {
  Numeric // PIC 9(...) / S9(...) / V / P
  Alphabetic // PIC A(...)
  Alphanumeric // PIC X(...)
  National // PIC N(...)，UTF-16，每字符 2 字节
  Edited // 含 Z * $ , . + - CR DB / B 0 的编辑型
}

///|
/// PIC 类别的规范名，用于布局报告
pub fn PicCategory::name(self : PicCategory) -> String {
  match self {
    Numeric => "NUMERIC"
    Alphabetic => "ALPHABETIC"
    Alphanumeric => "ALPHANUMERIC"
    National => "NATIONAL"
    Edited => "EDITED"
  }
}

///|
/// USAGE 子句：数据在存储里的物理形式。默认 `Display`。
pub(all) enum Usage {
  Display // 默认：zoned decimal 或字符
  Comp // COMP / COMP-4 / COMP-5 / BINARY：二进制整数
  Comp3 // COMP-3 / PACKED-DECIMAL：打包十进制
  Comp1 // COMP-1 / FLOAT-SHORT：单精度浮点（4 字节）
  Comp2 // COMP-2 / FLOAT-LONG：双精度浮点（8 字节）
}

///|
/// USAGE 的规范名，用于布局报告
pub fn Usage::name(self : Usage) -> String {
  match self {
    Display => "DISPLAY"
    Comp => "COMP"
    Comp3 => "COMP-3"
    Comp1 => "COMP-1"
    Comp2 => "COMP-2"
  }
}

///|
/// PIC 子句解析结果。
///
/// `digits` 与 `scale` 的语义（与布局层对齐的契约）：
/// - `PIC S9(7)V99` → digits=7（整数位数）、scale=2，总位数 = digits + scale
/// - `PIC 9(8)` → digits=8、scale=0
/// - `PIC X(30)` → digits=30（字符数）、scale=0
/// - `PIC N(5)` → digits=5（字符数，字节数 = 5*2 由布局层算）
/// - `S` 前缀不进 digits，只置 `signed`
///
/// 编辑型（`ZZ,ZZ9.99`）的 `digits`/`scale` 与数字型同构：
/// 小数点左边的数字位计 `digits`，右边计 `scale`。插入字符（`$` `,` `.`
/// `CR` `DB` `+` `-`）不是数字位，但它们**确实占存储位置** ——
/// 布局层算这类字段的字节数应使用 `pic_storage_len(pic_text)`。
pub(all) struct PicClause {
  category : PicCategory
  digits : Int32
  scale : Int32
  // 实际占存储的数字位数（C10）：P 缩放字符不占存储，所以
  // storage_digits = 整数位 + 小数位（不含 leading/trailing P）。
  // zoned/packed/COMP 的字节长度按它计算；`digits + scale` 仍是
  // 数值语义上的总位数（含 P 的隐含位），用于容量校验。
  storage_digits : Int32
  signed : Bool
  usage : Usage
  sign_separate : Bool
  sign_leading : Bool // SIGN SEPARATE 的位置：true = LEADING（符号字节在前），false = TRAILING
  pic_text : String // PIC 模式串原文（大写），供布局层兜底
}

///|
/// 数据描述项（语法树节点）。
///
/// `pic == None` 表示组项（group item），其长度由 `children` 求和。
pub(all) struct FieldSpec {
  level : Int32
  name : String
  pic : PicClause?
  redefines : String?
  occurs : Int32 // 默认 1；OCCURS 1 TO 5 取上界 5
  occurs_min : Int32 // OCCURS 1 TO 5 取下界 1；无 TO 时等于 occurs
  occurs_depending_on : String?
  value_literal : String?
  children : Array[FieldSpec]
  line : Int32
  group_usage : Usage? // 组项上写的 USAGE，供子项继承
}

///|
/// 88 条件名（不占存储空间）
pub(all) struct ConditionName {
  name : String
  parent : String // 所挂的基本项名字
  values : Array[String] // VALUE 列举的取值（原始字面量文本）
  line : Int32
}

///|
/// 66 RENAMES 项（不占存储空间）
pub(all) struct RenamesEntry {
  name : String
  from : String
  thru : String? // RENAMES A THRU B 的 B
  line : Int32
}

///|
/// 扫描阶段的中间表示：一个已解析完子句的数据项，尚未建树
priv struct RawEntry {
  level : Int32
  name : String
  line : Int32
  pic : PicClause?
  redefines : String?
  occurs : Int32
  occurs_min : Int32
  occurs_depending_on : String?
  value_literal : String?
  group_usage : Usage?
}

///|
/// 语法分析器的可变状态
priv struct ParserState {
  toks : Array[Token]
  mut pos : Int32
  conditions : Array[ConditionName]
  renames : Array[RenamesEntry]
}

///|
/// 当前 token（越界返回 Eof）
fn ParserState::peek(self : ParserState) -> Token {
  if self.pos < self.toks.length() {
    self.toks[self.pos]
  } else {
    { kind: Eof, line: 0, column: 0, }
  }
}

///|
/// 吃掉当前 token 并返回它
fn ParserState::advance(self : ParserState) -> Token {
  let t = self.peek()
  if self.pos < self.toks.length() {
    self.pos = self.pos + 1
  }
  t
}

///|
/// 当前是否 Eof
fn ParserState::at_eof(self : ParserState) -> Bool {
  match self.peek().kind {
    Eof => true
    _ => false
  }
}

///|
/// 当前是否是句点
fn ParserState::at_dot(self : ParserState) -> Bool {
  match self.peek().kind {
    Dot => true
    _ => false
  }
}

///|
/// 当前是否是某个关键字（大小写已在词法层统一为大写）
fn ParserState::at_keyword(self : ParserState, word : String) -> Bool {
  match self.peek().kind {
    Keyword(w) => w == word
    _ => false
  }
}

///|
/// 当前若是该关键字则吃掉，返回是否成功
fn ParserState::eat_keyword(self : ParserState, word : String) -> Bool {
  if self.at_keyword(word) {
    let _ = self.advance()
    true
  } else {
    false
  }
}

///|
/// 当前若是字段名则返回其文本（FILLER 视作名字）
fn ParserState::ident_here(self : ParserState) -> String? {
  match self.peek().kind {
    Identifier(s) => Some(s)
    Keyword(w) => if w == "FILLER" { Some("FILLER") } else { None }
    _ => None
  }
}

// ============================================================================
// 对外入口
// ============================================================================

///|
/// 语法分析主入口：把 copybook 源码解析成顶层记录数组。
///
/// 每个顶层数据项（通常是 `01`，也可能是 `77`）对应返回数组的一个元素。
/// 88 条件名与 66 RENAMES 不进树，需要时用 `parse_copybook_with_extras`。
pub fn parse_copybook(source : StringView) -> Array[FieldSpec] raise ParseError {
  let p = new_parser(tokenize(source))
  parse_program(p)
}

///|
/// 同 `parse_copybook`，但同时取出 88 条件名与 66 RENAMES。
pub fn parse_copybook_with_extras(
  source : StringView,
) -> (Array[FieldSpec], Array[ConditionName], Array[RenamesEntry]) raise ParseError {
  let p = new_parser(tokenize(source))
  let roots = parse_program(p)
  (roots, p.conditions, p.renames)
}

///|
/// 只取 88 条件名
pub fn parse_copybook_conditions(
  source : StringView,
) -> Array[ConditionName] raise ParseError {
  let (_, conds, _) = parse_copybook_with_extras(source)
  conds
}

///|
/// 只取 66 RENAMES
pub fn parse_copybook_renames(
  source : StringView,
) -> Array[RenamesEntry] raise ParseError {
  let (_, _, ren) = parse_copybook_with_extras(source)
  ren
}

///|
fn new_parser(toks : Array[Token]) -> ParserState {
  { toks, pos: 0, conditions: [], renames: [], }
}

// ============================================================================
// 第一遍：扫描成扁平表
// ============================================================================

///|
fn parse_program(p : ParserState) -> Array[FieldSpec] raise ParseError {
  let flat : Array[RawEntry] = []
  let mut last_elementary : String = ""

  while !p.at_eof() {
    // 多余的句点（空语句）直接跳过
    if p.at_dot() {
      let _ = p.advance()
      continue
    }

    let start = p.peek()
    let lvl = match start.kind {
      Level(n) => n
      Number(n) =>
        raise SyntaxError(
          start.line,
          start.column,
          "期望级别号，得到数字 '\{n}'（合法级别号：01..49、66、77、88）",
        )
      other =>
        raise SyntaxError(
          start.line,
          start.column,
          "期望数据描述项（以级别号开头），得到 \{other.describe()}",
        )
    }
    let _ = p.advance()

    // ---- 66 RENAMES ----
    if lvl == 66 {
      let entry = parse_renames(p, start.line)
      p.renames.push(entry)
      skip_to_dot(p)
      continue
    }

    // ---- 88 条件名 ----
    if lvl == 88 {
      let name = match p.ident_here() {
        Some(s) => {
          let _ = p.advance()
          s
        }
        None =>
          raise SyntaxError(
            p.peek().line,
            p.peek().column,
            "88 级条件名缺少名字，得到 \{p.peek().kind.describe()}",
          )
      }
      let values = parse_condition_values(p)
      p.conditions.push({
        name,
        parent: last_elementary,
        values,
        line: start.line,
      })
      skip_to_dot(p)
      continue
    }

    // ---- 77 / 01..49 ----
    let name = match p.ident_here() {
      Some(s) => {
        let _ = p.advance()
        s
      }
      None => "FILLER"
    }

    let entry = parse_entry_clauses(p, name)
    if entry.pic is Some(_) {
      last_elementary = name
    }
    flat.push({
      level: lvl,
      name,
      line: start.line,
      pic: entry.pic,
      redefines: entry.redefines,
      occurs: entry.occurs,
      occurs_min: entry.occurs_min,
      occurs_depending_on: entry.occurs_depending_on,
      value_literal: entry.value_literal,
      group_usage: entry.group_usage,
    })
  }

  // 第二遍：建树，同时传播组级 USAGE（C5）。
  // COBOL 允许把 USAGE 写在组项上（`05 G USAGE COMP-3.`），组内没有自己
  // USAGE 子句的基本项继承它。逐项解析时互相看不到，而 FieldSpec 是不可变
  // 值，构造完成后再改写不了 —— 所以继承必须在 build_children **构造**
  // FieldSpec 时完成，自上而下把 inherited usage 传进去。
  // 优先级：自身显式声明 > 上层继承；无法区分「显式 USAGE DISPLAY」与
  // 「默认 DISPLAY」时按 IBM 编译器的行为，组声明优先。
  let (roots, _) = build_children(flat, 0, 0, None)
  roots
}

///|
/// 递归建树。
///
/// 从 `start` 开始，收集所有 `level > parent_level` 的连续项作为兄弟，
/// 每项再递归收集自己的子项。返回 `(本层子树, 下一个未消费的下标)`。
///
/// 这个判定之所以成立，是因为 COBOL 的层级号保证了：
/// 一棵子树的全部后代层级号都严格大于子树根的层级号，
/// 而子树结束后遇到的下一个项的层级号一定 `<= 子树根层级`。

///|
/// Usage 的结构相等比较（enum 无参数变体；类型未实现 Eq trait）。
fn usage_same(a : Usage, b : Usage) -> Bool {
  match (a, b) {
    (Display, Display) => true
    (Comp, Comp) => true
    (Comp3, Comp3) => true
    (Comp1, Comp1) => true
    (Comp2, Comp2) => true
    _ => false
  }
}

///|
fn build_children(
  flat : Array[RawEntry],
  start : Int32,
  parent_level : Int32,
  inherited_usage : Usage?,
) -> (Array[FieldSpec], Int32) raise ParseError {
  let out : Array[FieldSpec] = []
  let mut i = start
  while i < flat.length() && flat[i].level > parent_level {
    let e = flat[i]
    i = i + 1
    // 本节点的有效组级 USAGE：自身声明的优先，否则继承上层
    let down : Usage? = match e.group_usage {
      Some(u) => Some(u)
      None => inherited_usage
    }
    let (kids, next_i) = build_children(flat, i, e.level, down)
    i = next_i
    // 基本项（有 PIC）不能再挂子项
    if kids.length() > 0 {
      match e.pic {
        Some(_) =>
          raise SyntaxError(
            e.line,
            e.level * 0 + 1, // 列号在扁平表里已丢失，给 1
            "基本项 '\{e.name}' 带 PIC 子句，不能有下级项（COBOL 不允许）",
          )
        None => ()
      }
    }
    // 组级 USAGE 落到基本项：仅有 PIC 且继承到的 usage 与自身不同时改写。
    // Usage 没有 Eq，按构造子比较（enum 无参数变体，结构相等即可）。
    let final_pic : PicClause? = match e.pic {
      Some(pc) =>
        match down {
          Some(u) =>
            if usage_same(pc.usage, u) {
              Some(pc)
            } else {
              Some({ ..pc, usage: u, })
            }
          None => Some(pc)
        }
      None => None
    }
    out.push({
      level: e.level,
      name: e.name,
      pic: final_pic,
      redefines: e.redefines,
      occurs: e.occurs,
      occurs_min: e.occurs_min,
      occurs_depending_on: e.occurs_depending_on,
      value_literal: e.value_literal,
      children: kids,
      line: e.line,
      group_usage: e.group_usage,
    })
  }
  (out, i)
}

// ============================================================================
// 子句解析
// ============================================================================

///|
/// 一个数据项上各子句的临时结果
priv struct EntryClauses {
  pic : PicClause?
  redefines : String?
  occurs : Int32
  occurs_min : Int32
  occurs_depending_on : String?
  value_literal : String?
  group_usage : Usage?
}

///|
/// 解析级别号与名字之后的全部子句，直到句点。
fn parse_entry_clauses(
  p : ParserState,
  name : String,
) -> EntryClauses raise ParseError {
  let mut pic : PicClause? = None
  let mut redefines : String? = None
  let mut occurs = 1
  let mut occurs_min = 1
  let mut occurs_depending_on : String? = None
  let mut value_literal : String? = None
  // 显式写的 USAGE；None 表示没写（由 PIC 子句自带或默认 Display）
  let mut explicit_usage : Usage? = None
  let mut sign_separate = false
  // SIGN SEPARATE 的位置；默认 TRAILING（COBOL 默认对带符号数值是 TRAILING）
  let mut sign_leading = false

  while !p.at_eof() && !p.at_dot() {
    let tok = p.peek()

    // ---- PIC / PICTURE ----
    if p.at_keyword("PIC") {
      let _ = p.advance()
      let (text, text_tok) = match p.peek().kind {
        PicString(s) => (s, p.advance())
        PicX => ("X", p.advance())
        PicN => ("N", p.advance())
        other =>
          raise SyntaxError(
            tok.line,
            tok.column,
            "PIC 子句缺少模式串，得到 \{other.describe()}",
          )
      }
      pic = Some(parse_pic_clause(text, text_tok.line, text_tok.column))
      continue
    }

    // ---- USAGE [IS] ... ----
    if p.at_keyword("USAGE") {
      let _ = p.advance()
      let _ = p.eat_keyword("IS")
      explicit_usage = Some(parse_usage_word(p))
      continue
    }

    // ---- 裸的 COMP 族（USAGE 省略的标准写法）----
    match tok.kind {
      Keyword(w) =>
        match usage_from_word(w) {
          Some(u) => {
            let _ = p.advance()
            explicit_usage = Some(u)
            continue
          }
          None => ()
        }
      _ => ()
    }

    // ---- SIGN [IS] [LEADING|TRAILING] [SEPARATE] ----
    if p.at_keyword("SIGN") {
      let _ = p.advance()
      let _ = p.eat_keyword("IS")
      if p.eat_keyword("LEADING") {
        sign_leading = true
      } else {
        let _ = p.eat_keyword("TRAILING")
        sign_leading = false
      }
      if p.eat_keyword("SEPARATE") {
        sign_separate = true
      }
      continue
    }
    // 单独的 SEPARATE（SIGN IS 被省略的写法）
    if p.at_keyword("SEPARATE") {
      let _ = p.advance()
      sign_separate = true
      continue
    }

    // ---- REDEFINES ----
    if p.at_keyword("REDEFINES") {
      let _ = p.advance()
      redefines = Some(expect_ident(p, "REDEFINES 缺少目标字段名"))
      continue
    }

    // ---- OCCURS n [TO m] TIMES [DEPENDING ON x] ----
    if p.at_keyword("OCCURS") {
      let occ_tok = p.advance()
      let first = expect_number(p, "OCCURS")
      occurs = first
      occurs_min = first
      let mut saw_to = false
      if p.at_keyword("TO") {
        let _ = p.advance()
        let upper = expect_number(p, "OCCURS ... TO")
        occurs_min = first
        occurs = upper
        saw_to = true
      }
      let _ = p.eat_keyword("TIMES")
      if p.at_keyword("DEPENDING") {
        let _ = p.advance()
        let _ = p.eat_keyword("ON")
        match p.ident_here() {
          Some(s) => {
            occurs_depending_on = Some(s)
            let _ = p.advance()
          }
          None => ()
        }
      }
      if occurs < 1 || occurs_min < 1 {
        raise SyntaxError(
          occ_tok.line,
          occ_tok.column,
          "OCCURS 次数必须 >= 1，得到 \{occurs_min} TO \{occurs}",
        )
      }
      if saw_to && occurs_min > occurs {
        raise SyntaxError(
          occ_tok.line,
          occ_tok.column,
          "OCCURS 下界 \{occurs_min} 大于上界 \{occurs}",
        )
      }
      continue
    }

    // ---- VALUE [IS] literal ----
    if p.at_keyword("VALUE") || p.at_keyword("VALUES") {
      let _ = p.advance()
      let _ = p.eat_keyword("IS")
      value_literal = Some(parse_value_literal(p))
      continue
    }

    // ---- 对布局无影响的修饰子句 ----
    if p.at_keyword("JUSTIFIED") || p.at_keyword("JUST") {
      let _ = p.advance()
      // RIGHT / LEFT 在词法层是普通标识符，这里一并吃掉
      let _ = p.eat_keyword("RIGHT")
      match p.ident_here() {
        Some(w) => if w == "RIGHT" || w == "LEFT" { let _ = p.advance() }
        None => ()
      }
      continue
    }
    if p.at_keyword("SYNC") || p.at_keyword("SYNCHRONIZED") {
      let _ = p.advance()
      // 可选的 LEFT / RIGHT
      match p.ident_here() {
        Some(w) => if w == "RIGHT" || w == "LEFT" { let _ = p.advance() }
        None => ()
      }
      continue
    }
    if p.at_keyword("EXTERNAL") || p.at_keyword("GLOBAL") {
      let _ = p.advance()
      continue
    }
    if p.at_keyword("BLANK") {
      let _ = p.advance()
      let _ = p.eat_keyword("WHEN")
      let _ = p.eat_keyword("ZERO")
      continue
    }

    raise SyntaxError(
      tok.line,
      tok.column,
      "数据项 '\{name}' 的子句里出现意料之外的 \{tok.kind.describe()}",
    )
  }

  // 收尾：吃掉句点
  if p.at_dot() {
    let _ = p.advance()
  }

  // 合并 USAGE 与 SIGN SEPARATE 进 PIC 子句。
  // 优先级：显式 USAGE 子句 > PIC 里自带的（几乎总是 Display）> 默认。
  let final_pic = match pic {
    Some(pc) => {
      let u = match explicit_usage {
        Some(u) => u
        None => pc.usage
      }
      Some({
        category: pc.category,
        digits: pc.digits,
        scale: pc.scale,
        storage_digits: pc.storage_digits,
        signed: pc.signed || sign_separate,
        usage: u,
        sign_separate,
        sign_leading,
        pic_text: pc.pic_text,
      })
    }
    None => None
  }

  // 组项上的 USAGE 单独记下来供子项继承（组项自己没有 PIC）
  let group_usage = match pic {
    Some(_) => None
    None => explicit_usage
  }

  {
    pic: final_pic,
    redefines,
    occurs,
    occurs_min,
    occurs_depending_on,
    value_literal,
    group_usage,
  }
}

///|
/// 期待一个标识符（字段名）
fn expect_ident(p : ParserState, what : String) -> String raise ParseError {
  let t = p.peek()
  match p.ident_here() {
    Some(s) => {
      let _ = p.advance()
      s
    }
    None =>
      raise SyntaxError(
        t.line,
        t.column,
        "\{what}，得到 \{t.kind.describe()}",
      )
  }
}

///|
/// 期待一个数字
fn expect_number(p : ParserState, what : String) -> Int32 raise ParseError {
  let t = p.peek()
  match t.kind {
    Number(n) => {
      let _ = p.advance()
      n
    }
    // 语句起点处的 `5` 可能被词法层判成 Level（极少见），这里照样接受
    Level(n) => {
      let _ = p.advance()
      n
    }
    other =>
      raise SyntaxError(
        t.line,
        t.column,
        "\{what} 缺少次数，得到 \{other.describe()}",
      )
  }
}

///|
/// 解析 USAGE 关键字之后的取值
fn parse_usage_word(p : ParserState) -> Usage raise ParseError {
  let t = p.peek()
  match t.kind {
    Keyword(w) =>
      match usage_from_word(w) {
        Some(u) => {
          let _ = p.advance()
          u
        }
        None =>
          raise SyntaxError(t.line, t.column, "USAGE 的取值不认识：\{w}")
      }
    other =>
      raise SyntaxError(
        t.line,
        t.column,
        "USAGE 后面期望 USAGE 名（COMP / COMP-3 / DISPLAY 等），得到 \{other.describe()}",
      )
  }
}

///|
/// USAGE 关键字 -> Usage
///
/// 注意 COMP-1/COMP-2 在 COBOL-74 里不存在，且浮点不是定点小数，
/// 本项目的 Decimal 表示覆盖不到它们，因此仅作为布局信息保留。
fn usage_from_word(w : String) -> Usage? {
  match w {
    "DISPLAY" => Some(Display)
    "COMP"
    | "COMPUTATIONAL"
    | "COMP-4"
    | "COMPUTATIONAL-4"
    | "COMP-5"
    | "COMPUTATIONAL-5"
    | "BINARY" => Some(Comp)
    "COMP-3" | "COMPUTATIONAL-3" | "PACKED-DECIMAL" => Some(Comp3)
    "COMP-1" | "COMPUTATIONAL-1" | "FLOAT-SHORT" => Some(Comp1)
    "COMP-2" | "COMPUTATIONAL-2" | "FLOAT-LONG" => Some(Comp2)
    _ => None
  }
}

///|
/// 解析 VALUE 后面的字面量。
///
/// 覆盖：`'A'` 引号串、数字、`SPACE`/`ZERO`/`HIGH-VALUE` 等比喻常量、
/// 以及 `ALL 'x'` 前缀（`ALL` 会被吃掉，只返回后面的字面量）。
fn parse_value_literal(p : ParserState) -> String raise ParseError {
  let _ = p.eat_keyword("ALL")
  let t = p.peek()
  match t.kind {
    StringLiteral(s) => {
      let _ = p.advance()
      s
    }
    Number(n) => {
      let _ = p.advance()
      n.to_string()
    }
    Level(n) => {
      let _ = p.advance()
      n.to_string()
    }
    Keyword(w) =>
      match w {
        "SPACE"
        | "SPACES"
        | "ZERO"
        | "ZEROS"
        | "ZEROES"
        | "HIGH-VALUE"
        | "HIGH-VALUES"
        | "LOW-VALUE"
        | "LOW-VALUES"
        | "QUOTE"
        | "QUOTES"
        | "NULL"
        | "NULLS" => {
          let _ = p.advance()
          w
        }
        _ =>
          raise SyntaxError(
            t.line,
            t.column,
            "VALUE 后面期望字面量，得到 \{t.kind.describe()}",
          )
      }
    other =>
      raise SyntaxError(
        t.line,
        t.column,
        "VALUE 后面期望字面量，得到 \{other.describe()}",
      )
  }
}

///|
/// 解析 88 条件名的 VALUE 列表（可多个，空格或逗号分隔）
fn parse_condition_values(p : ParserState) -> Array[String] raise ParseError {
  let out : Array[String] = []
  let _ = p.eat_keyword("VALUE")
  let _ = p.eat_keyword("IS")
  let _ = p.eat_keyword("VALUES")
  while !p.at_eof() && !p.at_dot() {
    if p.at_keyword("VALUE") || p.at_keyword("VALUES") {
      let _ = p.advance()
      continue
    }
    if p.at_keyword("THRU") || p.at_keyword("THROUGH") {
      let _ = p.advance()
      let hi = parse_value_literal(p)
      out.push("THRU " + hi)
      continue
    }
    let t = p.peek()
    match t.kind {
      Number(_) | Level(_) | StringLiteral(_) =>
        out.push(parse_value_literal(p))
      Keyword(w) =>
        // 88 里也允许 SPACE/ZERO 之类的比喻常量
        match w {
          "SPACE"
          | "SPACES"
          | "ZERO"
          | "ZEROS"
          | "ZEROES"
          | "HIGH-VALUE"
          | "HIGH-VALUES"
          | "LOW-VALUE"
          | "LOW-VALUES"
          | "QUOTE"
          | "QUOTES" => {
            out.push(w)
            let _ = p.advance()
          }
          _ => break
        }
      _ => break
    }
  }
  out
}

///|
/// 解析 66 RENAMES
fn parse_renames(
  p : ParserState,
  line : Int32,
) -> RenamesEntry raise ParseError {
  let name = expect_ident(p, "66 级 RENAMES 缺少名字")
  if !p.eat_keyword("RENAMES") {
    raise SyntaxError(
      p.peek().line,
      p.peek().column,
      "66 级项必须跟 RENAMES 子句",
    )
  }
  let from = expect_ident(p, "RENAMES 缺少起始字段名")
  let mut thru : String? = None
  if p.at_keyword("THRU") || p.at_keyword("THROUGH") {
    let _ = p.advance()
    thru = Some(expect_ident(p, "THRU 缺少结束字段名"))
  }
  { name, from, thru, line, }
}

///|
/// 跳到下一个句点（用于 88/66 这类"整条语句可忽略"的场合）
fn skip_to_dot(p : ParserState) -> Unit {
  while !p.at_eof() && !p.at_dot() {
    let _ = p.advance()
  }
  if p.at_dot() {
    let _ = p.advance()
  }
}

// ============================================================================
// PIC 子句解析
// ============================================================================

///|
/// 解析 PIC 模式串，得到类别、位数、scale、符号。
///
/// 算法：先展开 `(n)` 重复，再逐字符分类统计。
///
/// 判断顺序有讲究：
/// 1. 先看是否含**编辑字符**（`Z` `*` `$` `,` `.` `+` `-` `/` `B` `0` `CR` `DB`），
///    含则整体是 Edited —— 因为 `.` 在编辑型里是**插入字符**（占位），
///    在数字型里却根本不是合法字符。
/// 2. `S` 只置 signed，不计数（且只认首位）。
/// 3. `V` 划分小数点：V 之前的数字位计入整数位，之后的计入 scale。
/// 4. `P` 是缩放位（隐含 10 的幂），按 COBOL 规则折算。
/// 5. `X` / `A` / `N` 是字符位，一个字符算一位。
pub fn parse_pic_clause(
  text : String,
  line : Int32,
  column : Int32,
) -> PicClause raise ParseError {
  let chars = expand_pic(text, line, column)
  if chars.length() == 0 {
    raise SyntaxError(line, column, "PIC 模式串为空")
  }

  // ---- 第一步：判定是否编辑型 ----
  let has_z = array_has(chars, 'Z')
  let has_star = array_has(chars, '*')
  let has_dollar = array_has(chars, '$')
  let has_comma = array_has(chars, ',')
  let has_plus = array_has(chars, '+')
  let has_minus = array_has(chars, '-')
  let has_slash = array_has(chars, '/')
  let has_b = array_has(chars, 'B')
  let has_zero = array_has(chars, '0')
  // `.` 只有在数字型里不合法，所以出现即编辑型；但要注意
  // 数字型合法的 `V` 才是隐含小数点。
  let has_dot = array_has(chars, '.')
  // CR / DB 是两个字母的组合，必须成对
  let joined = String::from_array(chars)
  let has_cr_db = joined.contains("CR") || joined.contains("DB")

  let has_edit = has_z ||
    has_star ||
    has_dollar ||
    has_comma ||
    has_plus ||
    has_minus ||
    has_slash ||
    has_b ||
    has_zero ||
    has_dot ||
    has_cr_db

  if has_edit {
    return parse_edited(text, chars, line, column)
  }

  // ---- 第二步：非编辑型，判定字符类 ----
  let has_x = array_has(chars, 'X')
  let has_a = array_has(chars, 'A')
  let has_n = array_has(chars, 'N')
  let has_9 = array_has(chars, '9')

  if has_x || has_a || has_n {
    if has_9 || count_of(has_x) + count_of(has_a) + count_of(has_n) > 1 {
      raise SyntaxError(
        line,
        column,
        "PIC '\{text}' 混用了多种占位符（X/A/N/9），COBOL 不允许",
      )
    }
    let category = if has_n {
      National
    } else if has_x {
      Alphanumeric
    } else {
      Alphabetic
    }
    return {
      category,
      digits: count_placeholder(chars),
      scale: 0,
      storage_digits: count_placeholder(chars),
      signed: false,
      usage: Display,
      sign_separate: false,
      sign_leading: false,
      pic_text: text,
    }
  }

  // ---- 第三步：纯数字型 ----
  let mut signed = false
  let mut int_digits = 0
  let mut frac_digits = 0
  let mut after_point = false
  let mut trailing_p = 0
  let mut leading_p = 0

  for i, c in chars {
    match c {
      'S' => {
        if i != 0 {
          raise SyntaxError(
            line,
            column,
            "PIC '\{text}' 的符号 S 只能出现在首位",
          )
        }
        signed = true
      }
      'V' => after_point = true
      '9' =>
        if after_point {
          frac_digits = frac_digits + 1
        } else {
          int_digits = int_digits + 1
        }
      'P' =>
        // P 只能出现在两端：前面没有任何 9 → 前导缩放位；否则尾部缩放位
        if int_digits == 0 && !after_point {
          leading_p = leading_p + 1
        } else {
          trailing_p = trailing_p + 1
        }
      other =>
        raise SyntaxError(
          line,
          column,
          "PIC '\{text}' 里出现非法字符 '\{other}'",
        )
    }
  }

  if int_digits == 0 && frac_digits == 0 && leading_p == 0 {
    raise SyntaxError(line, column, "PIC '\{text}' 里没有任何数字位 9")
  }

  // COBOL 数字项上限 18 位（总位数 = 整数 + 小数 + 前导 P）。
  // 超限必须拒绝：zoned/packed 解码会把系数塞进 Int64，19 位起就静默回绕。
  let total_digits = int_digits + frac_digits + leading_p
  if total_digits > 18 {
    raise SyntaxError(
      line,
      column,
      "PIC '\{text}' 共 \{total_digits} 位数字，超过 COBOL 上限 18 位",
    )
  }

  {
    category: Numeric,
    // digits 只表示**整数位数**（契约），总位数 = digits + scale。
    // P 是隐含位、不占存储：前导 P 使实际小数位变多 → 计入 scale；
    // 尾随 P 只是把值放大，存储位数不变 → 不影响 digits。
    digits: int_digits,
    scale: frac_digits + leading_p,
    storage_digits: int_digits + frac_digits,
    signed,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    pic_text: text,
  }
}

///|
/// `has_x` 之类的布尔转 0/1 计数，仅用于"是否混用"的判定
fn count_of(b : Bool) -> Int32 {
  if b {
    1
  } else {
    0
  }
}

///|
/// 数组是否含某字符
fn array_has(cs : Array[Char], c : Char) -> Bool {
  for x in cs {
    if x == c {
      return true
    }
  }
  false
}

///|
/// 编辑型 PIC：统计有效数字位与小数位，类别固定为 Edited。
///
/// 插入字符（`$` `,` `.` `+` `-` `/` `B` `CR` `DB`）在 COBOL 里确实占存储位置，
/// 但它们不是数字位。布局层需要「存储长度」时应数 `pic_text` 的字符数
/// （`(n)` 展开后），本函数给出的 `digits` 只表示**有效数字位**。
fn parse_edited(
  text : String,
  chars : Array[Char],
  line : Int32,
  column : Int32,
) -> PicClause raise ParseError {
  let mut signed = false
  let mut int_digits = 0
  let mut frac_digits = 0
  let mut after_point = false
  for i, c in chars {
    match c {
      'S' =>
        if i == 0 {
          signed = true
        } else {
          raise SyntaxError(
            line,
            column,
            "PIC '\{text}' 的符号 S 只能出现在首位",
          )
        }
      'V' => after_point = true
      // 编辑型里的 `.` 是**真实的**小数点（占一个存储位），
      // 它同时是整数位与小数位的分界。
      '.' => after_point = true
      '9' | 'Z' | '*' | '0' =>
        if after_point {
          frac_digits = frac_digits + 1
        } else {
          int_digits = int_digits + 1
        }
      // 插入字符与 CR/DB 的字母，不占数字位
      'C' | 'D' | 'R' | 'B' | '+' | '-' | '$' | ',' | '/' | 'P' => ()
      other =>
        raise SyntaxError(
          line,
          column,
          "PIC '\{text}' 里出现非法字符 '\{other}'",
        )
    }
  }
  {
    category: Edited,
    // 与数字型保持同一契约：digits 是整数位，scale 是小数位
    digits: int_digits,
    scale: frac_digits,
    storage_digits: int_digits + frac_digits,
    signed,
    usage: Display,
    sign_separate: false,
    sign_leading: false,
    pic_text: text,
  }
}

///|
/// 统计字符占位符个数（X/A/N，已展开）
fn count_placeholder(chars : Array[Char]) -> Int32 {
  let mut n = 0
  for c in chars {
    match c {
      'X' | 'A' | 'N' => n = n + 1
      _ => ()
    }
  }
  n
}

///|
/// 把 `9(7)` 这类展开成 7 个 `9`。
///
/// 括号里必须是纯数字；括号必须匹配。`(n)` 可以跟在任意单位字符后面，
/// 包括编辑型的 `Z` `X` `*` `$`。
fn expand_pic(
  text : String,
  line : Int32,
  column : Int32,
) -> Array[Char] raise ParseError {
  let src = text.to_array()
  let out : Array[Char] = []
  let mut i = 0
  while i < src.length() {
    let c = src[i]
    if c == '(' {
      if out.length() == 0 {
        raise SyntaxError(
          line,
          column,
          "PIC '\{text}' 的 '(' 前面没有可重复的字符",
        )
      }
      let unit = out[out.length() - 1]
      let _ = out.pop()
      let mut j = i + 1
      let num : Array[Char] = []
      while j < src.length() && src[j] != ')' {
        if !(src[j] >= '0' && src[j] <= '9') {
          raise SyntaxError(
            line,
            column,
            "PIC '\{text}' 的括号里出现非数字 '\{src[j]}'",
          )
        }
        num.push(src[j])
        j = j + 1
      }
      if j >= src.length() {
        raise SyntaxError(
          line,
          column,
          "PIC '\{text}' 的 '(' 没有匹配的 ')'",
        )
      }
      if num.length() == 0 {
        raise SyntaxError(
          line,
          column,
          "PIC '\{text}' 的 '()' 里没有数字",
        )
      }
      let count = digits_to_int(String::from_array(num))
      match count {
        Some(n) =>
          if n <= 0 {
            raise SyntaxError(
              line,
              column,
              "PIC '\{text}' 的重复次数必须 >= 1，得到 \{n}",
            )
          } else {
            let mut k = 0
            while k < n {
              out.push(unit)
              k = k + 1
            }
          }
        None =>
          raise SyntaxError(
            line,
            column,
            "PIC '\{text}' 的重复次数无法解析",
          )
      }
      i = j + 1
    } else if c == ')' {
      raise SyntaxError(line, column, "PIC '\{text}' 有多余的 ')'")
    } else {
      out.push(c)
      i = i + 1
    }
  }
  out
}

///|
/// 纯数字文本 -> Int；超过 6 位视为非法（PIC 长度不会那么大）
fn digits_to_int(text : String) -> Int32? {
  let cs = text.to_array()
  if cs.length() == 0 || cs.length() > 6 {
    return None
  }
  let mut n = 0
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if c < '0' || c > '9' {
      return None
    }
    n = n * 10 + (c.to_int() - 48)
    i = i + 1
  }
  Some(n)
}

///|
/// 展开 `(n)` 后的 PIC 存储字符数（布局层对编辑型可用）。
///
/// 例：`X(30)` → 30，`9(5)CR` → 7，`ZZ,ZZ9.99` → 9。
pub fn pic_storage_len(text : String) -> Int32 {
  // 展开失败时退化为原串长度（不 raise：这是给布局层兜底用的）
  let chars = expand_pic(text, 0, 0) catch { _ => text.to_array() }
  chars.length()
}
