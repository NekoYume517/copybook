// Copybook 词法分析
//
// ## COBOL 的固定列格式 vs 自由格式
//
// 经典 COBOL 源文件是 80 列的穿孔卡格式：
//
//    列  1-6   序号区（sequence area），现代代码通常留空
//    列  7     指示符（indicator）：空格=语句，`*`=注释，`/`=换页，`-`=续行
//    列  8-11  区 A（division / section / 01 级 / 77 级）
//    列  12-72 区 B（普通语句）
//    列  73-80 标识区（identification area），编译器忽略
//
// **列 73-80 只在行真的写到第 73 列时才存在。** 本词法器在固定格式下把
// 代码区截到第 72 列（`hi = 72`），因此：
//
//   - 行长 ≥ 73 的固定格式行：第 73 列起的标识号被丢弃，不参与词法；
//   - 行长 < 73 的固定格式行：根本没有标识区，行尾字符**全部属于代码区**；
//   - 自由格式：整行都是代码区，不做任何截断（自由格式没有标识区）。
//
// 这条边界容易被误读成"截断失效"：`000300   05 B PIC X(2).000400` 只有
// 29 列，前 6 列虽是序号，但行尾的 `000400` 落在列 24-29，属于代码区 ——
// 它会被拼进 PIC 模式串并报错，这是正确行为（见 lexer_test.mbt 的两条
// 锁定测试：80 列的标识区被忽略、29 列的行尾数字仍是代码）。
// 要真正忽略标识号，行必须按 80 列写满。
//
// 而现代 copybook 往往直接写成自由格式（`01  RECORD.` 从第 1 列开始）。
// 本词法器**两种都支持**，判定方式是**整文件级**的：
//
//   若任意一行的前 6 列全是数字 → 判定为定长格式（有真实序号区），
//   此后每行按列 7 取指示符、列 8 起取代码区、到第 72 列为止（行长不足
//   72 列就到行尾；列 73-80 的标识区只在行足够长时才被丢弃）。
//   否则判定为自由格式，整行都是代码区。
//
// 为什么不做逐行判定：像 `    05  LINES OCCURS 5 TIMES.` 这种行，前 6 列
// 是「4 空格 + 05」，逐行判定会误判成定长格式并从第 8 列开始切，把级别号
// 的十位切掉。整文件判定没有这个歧义。
//
// 注释在两种格式下都识别：
//   - 定长：第 7 列（索引 6）是 `*` 或 `/`
//   - 通用：代码区第一个非空白字符是 `*`
//
// ## 续行（列 7 `-`）
//
// 固定格式下第 7 列的 `-` 是**续行**：该行代码区（列 8..72）接到上一条
// 逻辑行后面再统一做词法，长 `PIC` / `VALUE` 因此可以跨行书写。实现见
// `collect_code_lines`；拼接时两端空白被剥掉，所以 `'ABC` + `DEF'` 得到
// `'ABCDEF'`、`X(` + `5)` 得到 `X(5)`。
//
// 自由格式没有续行符：行首 `-` 明确报错（静默跳过会让内容凭空消失）。
// 列 7 的 `-` 前面没有可续接的逻辑行时同样报错。
//
// ## 级别号 vs 普通数字
//
// `01`..`49`、`66`、`77`、`88` 是级别号，但 `OCCURS 5 TIMES` 里的 `5`
// 不是。区分依据是 **语句起点**：只有出现在语句开头（文件开头，或前一个
// token 是 `.`）的 1-2 位数字才是级别号，其它一律是 `Number`。
//
// ## PIC 模式串的边界
//
// `PIC S9(7)V99.` 里，`S9(7)V99` 要整体作为一个模式串，末尾的 `.` 是
// 语句终止符。判别方法：把 PIC 之后到空白的整段非空白串当作候选，
// 若它以 `.` 结尾就弹掉最后那个 `.`（作为 Dot token 单独发射）。
// 这样 `PIC ZZ,ZZ9.99.` 也能正确切成模式串 `ZZ,ZZ9.99` + Dot。
//
// 另有一个少见的写法是 PIC 模式里带空格（`PIC S9(7) V99`），
// 处理办法是：若下一个非空白段以 `V` 开头且其余字符都是数字/括号/`P`，
// 就把它拼回模式串。`VALUE` 不会被误吞（`ALUE` 含非 PIC 字符）。

///|
/// 词法与语法错误统一用这个类型。
///
/// MoonBit 实测限制：`suberror` 的变体**只能用位置参数**，不能写具名字段
/// （`V(Line : Int)` 会报 "Expected upper case identifier for type name"）。
///
/// - `LexError(line, column, message)`  词法错误
/// - `SyntaxError(line, column, message)` 语法错误
/// - `InvalidLayout(message)` 布局层的错误（无行列号），供 layout/decode 复用
pub(all) suberror ParseError {
  LexError(Int32, Int32, String)
  SyntaxError(Int32, Int32, String)
  InvalidLayout(String)
}

///|
/// 构造词法错误（行列号 1-based）
pub fn ParseError::at(
  line : Int32,
  column : Int32,
  message : String,
) -> ParseError {
  LexError(line, column, message)
}

///|
/// 构造布局错误（无行列号）
pub fn ParseError::invalid_layout(message : String) -> ParseError {
  InvalidLayout(message)
}

///|
/// 该错误的行号；`InvalidLayout` 无位置概念，返回 0
pub fn ParseError::line(self : ParseError) -> Int32 {
  match self {
    LexError(l, _, _) => l
    SyntaxError(l, _, _) => l
    InvalidLayout(_) => 0
  }
}

///|
/// 该错误的列号（1-based）；`InvalidLayout` 无位置概念，返回 0
pub fn ParseError::column(self : ParseError) -> Int32 {
  match self {
    LexError(_, c, _) => c
    SyntaxError(_, c, _) => c
    InvalidLayout(_) => 0
  }
}

///|
/// 错误正文（不含位置前缀）
pub fn ParseError::message(self : ParseError) -> String {
  match self {
    LexError(_, _, m) => m
    SyntaxError(_, _, m) => m
    InvalidLayout(m) => m
  }
}

///|
/// 可直接打印的错误描述：`行:列: 正文`；`InvalidLayout` 只有正文
pub fn ParseError::to_display(self : ParseError) -> String {
  match self {
    LexError(l, c, m) => "\{l}:\{c}: \{m}"
    SyntaxError(l, c, m) => "\{l}:\{c}: \{m}"
    InvalidLayout(m) => m
  }
}

///|
/// 词法单元类型。
///
/// 注意 `StringLiteral` 是对 API.md 的**追加**（原契约缺少 VALUE 字面量
/// 的承载方式），属于超集，不影响既有变体。
pub(all) enum TokenKind {
  Identifier(String) // CUST-ID（已转大写）
  Level(Int32) // 01, 05, 88
  PicString(String) // PIC 9(8) 里的 9(8)，已剥离 PIC 关键字、已转大写
  PicX // PIC X（不带长度）
  PicN // PIC N（不带长度）
  Number(Int32) // OCCURS 5 里的 5
  StringLiteral(String) // VALUE 'A' 里的 'A'（含引号原样保留）
  LParen
  RParen
  Dot
  Keyword(String) // VALUE REDEFINES OCCURS TIMES COMP COMP-3 USAGE SIGN SEPARATE ...
  Eof
}

///|
/// 带位置信息的词法单元
pub(all) struct Token {
  kind : TokenKind
  line : Int32
  column : Int32
}

///|
/// 便于错误信息与测试断言的 TokenKind 文本形式
pub fn TokenKind::describe(self : TokenKind) -> String {
  match self {
    Identifier(s) => "标识符 '\{s}'"
    Level(n) => "级别号 '\{n}'"
    PicString(s) => "PIC 模式串 '\{s}'"
    PicX => "PIC X"
    PicN => "PIC N"
    Number(n) => "数字 '\{n}'"
    StringLiteral(s) => "字面量 \{s}"
    LParen => "'('"
    RParen => "')'"
    Dot => "'.'"
    Keyword(s) => "关键字 '\{s}'"
    Eof => "文件结束"
  }
}

///|
/// 便于错误信息与测试断言的 Token 文本形式
pub fn Token::describe(self : Token) -> String {
  "\{self.kind.describe()}（第 \{self.line} 行第 \{self.column} 列）"
}

///|
/// COBOL copybook 里出现的关键字（全部大写）。
/// 用 Map 而不是长 match，便于后续扩充且没有分支数上限问题。
let copybook_keywords : Map[String, Bool] = {
  let m : Map[String, Bool] = Map([])
  let words : Array[String] = [
    // PIC 子句
    "PIC", "PICTURE",
    // 数据描述子句
     "VALUE", "VALUES", "REDEFINES", "OCCURS", "TIMES", "TO", "DEPENDING", "ON",
    "USAGE", "IS", "SIGN", "SEPARATE", "LEADING", "TRAILING", "JUSTIFIED", "JUST",
    "SYNC", "SYNCHRONIZED", "EXTERNAL", "GLOBAL", "BLANK", "WHEN", "ZERO",
    // USAGE 取值
     "DISPLAY", "COMP", "COMPUTATIONAL", "COMP-1", "COMPUTATIONAL-1", "COMP-2", "COMPUTATIONAL-2",
    "COMP-3", "COMPUTATIONAL-3", "COMP-4", "COMPUTATIONAL-4", "COMP-5", "COMPUTATIONAL-5",
    "BINARY", "PACKED-DECIMAL", "FLOAT-SHORT", "FLOAT-LONG", "NATIONAL", "INDEX",
    "POINTER",
    // 66 / 88
     "RENAMES", "THRU", "THROUGH", "ALL", "FILLER",
    // VALUE 的特殊字面量
     "SPACE", "SPACES", "ZEROS", "ZEROES", "HIGH-VALUE", "HIGH-VALUES", "LOW-VALUE",
    "LOW-VALUES", "QUOTE", "QUOTES", "NULL", "NULLS",
    // 表定义
     "ASCENDING", "DESCENDING", "KEY", "INDEXED", "BY",
  ]
  for w in words {
    m[w] = true
  }
  m
}

///|
/// 可见字符判定：空格与制表符视为分隔
fn is_blank(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
/// 判断累积中的逻辑行是否有未闭合的引号（' 与 " 各自计数，双写转义
/// 不算重新开引号——COBOL 字面量不允许跨行重开同类引号外的第二种引号，
/// 这里只需可靠的「是否在字面量内」信号，供续行拼接决定是否补空格）。
fn has_unclosed_quote(cs : Array[Char]) -> Bool {
  let mut sq = 0
  let mut dq = 0
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if c == '\'' {
      // 双写转义：'' 与 "" 都是字面量内容，不改变开/闭状态
      if i + 1 < cs.length() && cs[i + 1] == '\'' {
        i = i + 2
        continue
      }
      sq = sq + 1
    } else if c == '"' {
      if i + 1 < cs.length() && cs[i + 1] == '"' {
        i = i + 2
        continue
      }
      dq = dq + 1
    }
    i = i + 1
  }
  sq % 2 == 1 || dq % 2 == 1
}

///|
/// COBOL 名字字符：字母、数字、连字符（COBOL 2014 起允许下划线）
fn is_name_char(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_'
}

///|
fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ascii_letter(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

///|
/// 按 `\n` / `\r\n` / `\r` 切行，保留空行（行号必须与源文件一致，
/// 否则报错位置会错位）。
///
/// Windows 编辑器存 CRLF、Unix 存 LF、老 Mac 存裸 CR，混合换行也真实存在
/// （多人协作的老仓库）。把三种都当换行处理，而不是只认 `\n` 再补剥 `\r`。
fn split_lines(src : StringView) -> Array[String] {
  let out : Array[String] = []
  let n = src.length()
  let mut cur : Array[Char] = []
  let mut i = 0
  while i < n {
    let c = src.get_char(i).unwrap()
    if c == '\n' {
      out.push(String::from_array(cur))
      cur = []
      i = i + 1
    } else if c == '\r' {
      out.push(String::from_array(cur))
      cur = []
      // \r\n 算一个换行
      if i + 1 < n && src[i + 1] == '\n' {
        i = i + 2
      } else {
        i = i + 1
      }
    } else {
      cur.push(c)
      i = i + 1
    }
  }
  out.push(String::from_array(cur))
  out
}

///|
/// 取字符数组的一段构造新 String（避免依赖 Array 切片语法）
fn chars_sub(cs : Array[Char], start : Int32, stop : Int32) -> String {
  let out : Array[Char] = []
  let mut i = start
  while i < stop && i < cs.length() {
    out.push(cs[i])
    i = i + 1
  }
  String::from_array(out)
}

///|
/// 整文件判定：前 6 列全是数字的行存在 → 定长格式。
///
/// **追加判定**（RJ-2，2026-11-06 组委会验收意见）：存在「1-6 列全空白、
/// 第 7 列是 `-`」的行 → 也按定长格式。无序号固定格式（IBM 手写、教学
/// 样例的常见形态）与自由格式在 1-6 列上**不可区分**（都是空白/空），
/// 旧判定对它返回 false，于是列 7 的续行符被自由格式分支当成
/// 「行首 `-`」直接报错 —— 续行能力对最需要它的文件形态失效。
/// 而「列 7 恰好是 `-`」在自由格式里没有合法含义（自由格式的连字符只
/// 出现在标识符中间，不会顶在第七列的行首），它是定长格式的**强信号**，
/// 拿它补判不会误伤自由格式。
/// 追加判定的细节记录（CB-4）：文件是否**只靠**「列 7 '-'」翻成定长
/// （无任何序号行），以及命中的物理行号 —— 用于在次生报错里提示判定
/// 原因。`fixed_has_sequence = false && fixed_dash_line = Some(n)` 表示
/// 翻转唯一依据是第 n 行的 '-'，此时自由格式长行被列 72 截断的次生
/// 错误（如「字符串字面量缺少结束引号」）极易误导排查方向。
fn detect_fixed_format_ex(lines : Array[String]) -> (Bool, Bool, Int32?) {
  let mut dash_line : Int32? = None
  for i, line in lines {
    let cs = line.to_array()
    if cs.length() >= 6 {
      let mut all_digits = true
      let mut i2 = 0
      while i2 < 6 {
        if !is_digit_char(cs[i2]) {
          all_digits = false
          i2 = 6
        } else {
          i2 = i2 + 1
        }
      }
      if all_digits {
        return (true, true, None)
      }
    }
    // 无序号定长格式的续行信号：1-6 列全空白 + 第 7 列是 `-`
    if cs.length() >= 7 && cs[6] == '-' {
      let mut all_blank = true
      let mut i2 = 0
      while i2 < 6 {
        if !is_blank(cs[i2]) {
          all_blank = false
          i2 = 6
        } else {
          i2 = i2 + 1
        }
      }
      if all_blank && dash_line is None {
        dash_line = Some(i + 1)
      }
    }
  }
  match dash_line {
    Some(_) => (true, false, dash_line)
    None => (false, false, None)
  }
}

///|
/// 兼容包装：只取判定结果。
fn detect_fixed_format(lines : Array[String]) -> Bool {
  detect_fixed_format_ex(lines).0
}

///|
/// 从 `from` 开始找第一个非空白字符的下标
fn first_non_blank(cs : Array[Char], from : Int32) -> Int32 {
  let mut i = from
  while i < cs.length() && is_blank(cs[i]) {
    i = i + 1
  }
  i
}

///|
/// 逻辑行：物理行按列切出代码区、并按续行规则拼接之后的结果。
///
/// `base_col` 是 `text` 第 0 个字符对应的 1-based 源列号（固定格式的代码区
/// 从列 8 开始 → base_col = 7；自由格式从列 1 开始 → 0），保证既有报错的
/// 行列号不变。续行拼进来的内容列号按拼接后的位置递增（合成列号），
/// 因为它在源码里位于另一行 —— 报错会指到被续接的那一行。
priv struct CodeLine {
  line_no : Int32
  text : String
  base_col : Int32
}

///|
/// 代码区尾部：去掉尾部空白（空格/TAB）。
///
/// 续接时行尾空白会把 80 列填充的空格拼进 `VALUE` 字面量，所以每段都按
/// 「两端去空白」参与拼接。普通语句尾部本来就没有 token，去掉不影响词法。
fn trim_end_blank(cs : Array[Char], start : Int32, stop : Int32) -> Int32 {
  let mut end = stop
  while end > start && is_blank(cs[end - 1]) {
    end = end - 1
  }
  end
}

///|
/// 把物理行切成逻辑行（CB-4 的续行实现）。
///
/// 列 7 是 `-` 的行是**续行**：它的代码区（列 8..72）接到上一条逻辑行后面，
/// 再统一做词法。这样长 `PIC` / `VALUE` 可以跨行书写：
///
/// ```
/// 000200    05 A PIC X(10) VALUE 'ABC
/// 000300-        DEF'.
/// ```
///
/// 拼接规则：续接段先去掉两端空白再直接相接，于是 `'ABC` + `DEF'` 得到
/// `'ABCDEF'`、`X(` + `5)` 得到 `X(5)`。这是对 COBOL「续行从区 B 起、
/// 字面量要重开引号」的宽松简化：不需要重开引号，也不需要恰好从列 12 开始。
///
/// 边界：
///   - 自由格式**没有**续行符：行首 `-` 明确报错（不静默当标识符/跳过）；
///   - 列 7 的 `-` 前面没有可续接的逻辑行 → 报错（否则内容会凭空消失）；
///   - 注释行与空行结束当前逻辑行（注释不能夹在续行中间）；
///   - 行尾空白先剥掉，避免把 80 列填充的空格拼进字面量。
fn collect_code_lines(
  lines : Array[String],
  fixed : Bool,
) -> Array[CodeLine] raise ParseError {
  let out : Array[CodeLine] = []
  // 累积中的逻辑行（acc 为空表示没有 pending）
  let mut acc : Array[Char] = []
  let mut acc_line = 0
  let mut acc_base = 0
  let mut pending = false
  for idx, raw in lines {
    let line_no = idx + 1
    let cs = raw.to_array()
    let len = cs.length()
    let mut lo = 0
    let mut hi = len
    let mut is_comment = false
    let mut continuation = false
    if fixed {
      if len > 6 && (cs[6] == '*' || cs[6] == '/') {
        is_comment = true
      } else {
        if len > 6 && cs[6] == '-' {
          continuation = true
        }
        lo = 7
        if hi > 72 {
          hi = 72
        }
      }
    }
    // 代码区为空 / 注释行 → 结束当前逻辑行
    let mut empty = is_comment || lo >= hi
    if !empty {
      let fnb = first_non_blank(cs, lo)
      if fnb >= hi {
        empty = true
      } else if cs[fnb] == '*' {
        // 通用注释：代码区第一个非空白字符是 `*`
        empty = true
      } else if !fixed && cs[fnb] == '-' {
        // 自由格式没有续行符。静默跳过会让内容凭空消失，明确报错。
        raise LexError(
          line_no,
          fnb + 1,
          "续行符 '-' 只在固定格式的列 7 有效（本文件按自由格式解析）；自由格式请把续接内容写在同一行",
        )
      }
    }
    if empty {
      if pending {
        out.push({
          line_no: acc_line,
          text: String::from_array(acc),
          base_col: acc_base,
        })
        acc = []
        pending = false
      }
      continue
    }
    // 续行从第一个非空白字符开始（列 8 之后的前导空格不进字面量）；
    // 首行保持 lo 不变，报错列号才是真实源码列。
    let start = if continuation { first_non_blank(cs, lo) } else { lo }
    let stop = trim_end_blank(cs, start, hi)
    if stop <= start {
      // 整段空白（例如只写了续行符）—— 不改变当前逻辑行
      continue
    }
    if continuation {
      if !pending {
        raise LexError(
          line_no, 7, "续行符 '-' 前面没有可续接的逻辑行",
        )
      }
      // **拼接 = 直接相接，不补空格**（RJ-2b，2026-11-06 组委会验收意见；
      // 撤销 P2-3 的「词间断行补空格」）。
      //
      // IBM 标准：列 7 的 `-` 表示「把本行区 B 的内容**无空格地**接到上一条
      // 逻辑行尾」——这是分裂词续行（`CUST` + `OUNTER` → `CUSTOMER`）的
      // **唯一**实现手段，`PIC 9(3)` 断成 `PIC 9(3` + `V99` 也靠它。P2-3
      // 加的「字母×字母补空格」把这个语义破坏了：
      //   `05 CUST` + `-    OUNTER PIC 9(3).` 被拆成 `CUST OUNTER` 两个词，
      //   报「数据项 'CUST' 的子句里出现意料之外的 标识符 'OUNTER'」——
      //   组委会验收正是栽在这里。
      //
      // P2-3 想防的「`PIC` + `X(10)` 粘成 `PICX`」在 IBM 语义下**本来就
      // 应该粘**（那确实是用户的断行错误，粘出来的报错才指向真问题——
      // 断行位置），补空格把错误输入洗成了另一个错误。
      //
      // 字面量内拼接（`'ABC` + `DEF'` → `'ABCDEF'`）与零相接行为与此一致，
      // continuation_test 锁定的既有契约全部不变。
      for i = start; i < stop; i = i + 1 {
        acc.push(cs[i])
      }
    } else {
      if pending {
        out.push({
          line_no: acc_line,
          text: String::from_array(acc),
          base_col: acc_base,
        })
      }
      acc = []
      acc_line = line_no
      acc_base = if fixed { 7 } else { 0 }
      for i = start; i < stop; i = i + 1 {
        acc.push(cs[i])
      }
      pending = true
    }
  }
  if pending {
    out.push({
      line_no: acc_line,
      text: String::from_array(acc),
      base_col: acc_base,
    })
  }
  out
}

///|
/// 判断某个字符是否允许出现在 PIC 模式串里。
///
/// 覆盖：数字位 `9`/`Z`/`*`、字符位 `X`/`A`、国家字符 `N`、
/// 符号 `S`（前导/尾随）、隐含小数点 `V`、缩放位 `P`、
/// 编辑字符 `,` `.` `$` `+` `-` `/` `B` `0`、以及 `CR`/`DB` 的首字母 `C`/`D`、
/// 以及括号。
fn is_pic_char(c : Char) -> Bool {
  match c {
    '9'
    | '0'
    | '1'
    | '2'
    | '3'
    | '4'
    | '5'
    | '6'
    | '7'
    | '8'
    | 'X'
    | 'A'
    | 'N'
    | 'S'
    | 'V'
    | 'P'
    | 'Z'
    | '*'
    | 'B'
    | 'C'
    | 'D'
    | 'R'
    | 'E'
    | 'G'
    | '$'
    | '+'
    | '-'
    | ','
    | '.'
    | '/'
    | '('
    | ')' => true
    _ => false
  }
}

///|
/// PIC 模式串续接段的判定：`V99`、`V9(3)`、`P(2)`
/// 用于处理 `PIC S9(7) V99` 这种在模式中间带空格的写法。
fn is_pic_continuation(run : Array[Char]) -> Bool {
  if run.length() == 0 {
    return false
  }
  let head = run[0]
  if head != 'V' && head != 'P' {
    return false
  }
  if run.length() == 1 {
    return true
  }
  let mut i = 1
  while i < run.length() {
    let c = run[i]
    if !(is_digit_char(c) || c == 'P' || c == '(' || c == ')') {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 给任意 Lex / Syntax 错误附加「本文件被判定为定长格式的原因」（CB-B8）。
///
/// CB-4 只把判定原因写进**一条**错误路径（`tokenize` 里「字符串字面量缺少
/// 结束引号」）。实测 `_probe/p16_flip.cpy` 走的是完全不同的路径：
///
///     01 R.
///       05 A PIC S9(4)V99 VALUE
///           -123.45.        <- 6 空格 + '-'，命中追加判定
///
/// 整文件翻成定长后每行前 7 列被切掉，级别号消失，parser 报
/// `2:8: 期望数据描述项（以级别号开头），得到 关键字 'PIC'` —— 既没指向
/// 真正的第 3 行，也没说「格式被判成定长」这个根因。
///
/// 修法不是收窄翻转信号（那会回退 RJ-2 的无序号续行能力，`continuation_test`
/// 与 `format_detect_guard_test` 都锁定了它），而是把判定原因**统一附注**到
/// 所有会因翻转而失真的错误上。`InvalidLayout` 是布局层错误、与格式判定
/// 无关，不附注。
fn note_format_flip(
  err : ParseError,
  fixed : Bool,
  has_sequence : Bool,
  dash_line : Int32?,
) -> ParseError {
  // 只在本文件**仅凭**「列 7 '-'」翻转时附注：有真实序号区的定长文件
  // 是用户明确声明的格式，语法错误不该被疑似格式问题带偏。
  if fixed && !has_sequence && dash_line is Some(ln) {
    let note = "（本文件因第 \{ln} 行列 7 为 '-' 被判定为定长格式：每行前 7 列被当作序号区/指示符丢弃、长行在列 72 被截断；若这是自由格式文件，请改掉第 \{ln} 行或给文件加序号）"
    match err {
      LexError(l, c, m) => LexError(l, c, m + note)
      SyntaxError(l, c, m) => SyntaxError(l, c, m + note)
      InvalidLayout(m) => InvalidLayout(m)
    }
  } else {
    err
  }
}

///|
/// 词法分析主入口。
///
/// 返回的 token 数组**总是**以 `Eof` 结尾（不抛异常时）。
/// 出错时抛 `ParseError::LexError(line, column, message)`。
///
/// 先由 `collect_code_lines` 把物理行切成逻辑行（固定格式：列 7 指示符、
/// 列 73-80 忽略、列 7 `-` 续行；自由格式：整行都是代码区），再逐逻辑行
/// 扫描。续行内容按拼接后的位置递增列号，报错指到被续接的那一行。
///
/// 格式判定只做一次，判定结果供 `note_format_flip` 给错误附加根因说明
/// （CB-B8）—— 所以真正的扫描在 `tokenize_lines` 里。
pub fn tokenize(source : StringView) -> Array[Token] raise ParseError {
  // 剥掉 UTF-8 BOM（U+FEFF）。Windows 上的编辑器/PowerShell 重定向经常
  // 把它写进文件头，词法层不处理的话整份 copybook 直接报「无法识别的字符」。
  let src = if source.length() > 0 && source[0] == 0xFEFF {
    source[1:]
  } else {
    source
  }
  let lines = split_lines(src)
  let (fixed, has_sequence, dash_line) = detect_fixed_format_ex(lines)
  try tokenize_lines(lines, fixed) catch {
    e => raise note_format_flip(e, fixed, has_sequence, dash_line)
  } noraise {
    toks => toks
  }
}

///|
/// 真正的逐行扫描（格式判定由 `tokenize` 决定后传入）。
fn tokenize_lines(
  lines : Array[String],
  fixed : Bool,
) -> Array[Token] raise ParseError {
  let code_lines = collect_code_lines(lines, fixed)
  let toks : Array[Token] = []
  // 语句起点标记：只有这里的 1-2 位数字才当级别号
  let mut stmt_start = true
  let mut last_line = 1
  let mut last_col = 1

  for code in code_lines {
    let line_no = code.line_no
    let cs = code.text.to_array()
    let hi = cs.length()
    let base_col = code.base_col
    if hi == 0 {
      continue
    }

    // ----- 逐字符扫描 -----
    let mut i = 0
    while i < hi {
      let c = cs[i]
      let col = base_col + i + 1

      if is_blank(c) {
        i = i + 1
        continue
      }

      // 句点：语句终止
      if c == '.' {
        toks.push({ kind: Dot, line: line_no, column: col, })
        stmt_start = true
        i = i + 1
        last_line = line_no
        last_col = col
        continue
      }

      if c == '(' {
        toks.push({ kind: LParen, line: line_no, column: col, })
        stmt_start = false
        i = i + 1
        last_line = line_no
        last_col = col
        continue
      }

      if c == ')' {
        toks.push({ kind: RParen, line: line_no, column: col, })
        stmt_start = false
        i = i + 1
        last_line = line_no
        last_col = col
        continue
      }

      // 引号字面量：'A' / "A" / 'O''Brien'（双写引号转义）
      if c == '\'' || c == '"' {
        let quote = c
        let raw_chars : Array[Char] = [quote]
        let mut j = i + 1
        let mut closed = false
        while j < hi {
          let d = cs[j]
          if d == quote {
            raw_chars.push(d)
            if j + 1 < hi && cs[j + 1] == quote {
              // 双写 = 转义的引号本身
              raw_chars.push(quote)
              j = j + 2
            } else {
              j = j + 1
              closed = true
              j = j
              break
            }
          } else {
            raw_chars.push(d)
            j = j + 1
          }
        }
        if !closed {
          // CB-4 曾在这里内联拼「定长判定」说明；CB-B8 改为由
          // `note_format_flip` 在 `tokenize` 外层**对所有** Lex/SyntaxError
          // 统一附注（本路径也要覆盖，否则同一条根因在两处维护、措辞会漂）。
          raise LexError(
            line_no,
            col,
            "字符串字面量缺少结束引号 \{quote}",
          )
        }
        toks.push({
          kind: StringLiteral(String::from_array(raw_chars)),
          line: line_no,
          column: col,
        })
        stmt_start = false
        i = j
        last_line = line_no
        last_col = col
        continue
      }

      // 数字：语句起点处 1-2 位且属合法级别 → Level，否则 Number
      if is_digit_char(c) {
        let mut j = i
        while j < hi && is_digit_char(cs[j]) {
          j = j + 1
        }
        let text = chars_sub(cs, i, j)
        let n = parse_digits(text)
        let is_level = stmt_start && is_level_number(n) && j - i <= 2
        if is_level {
          toks.push({ kind: Level(n), line: line_no, column: col, })
        } else {
          toks.push({ kind: Number(n), line: line_no, column: col, })
        }
        stmt_start = false
        i = j
        last_line = line_no
        last_col = col
        continue
      }

      // 标识符 / 关键字 / PIC
      if is_ascii_letter(c) {
        let mut j = i
        while j < hi && is_name_char(cs[j]) {
          j = j + 1
        }
        let word = chars_sub(cs, i, j).to_upper()
        // COBOL 名字不能以连字符结尾
        if word.length() > 0 {
          match word.get_char(word.length() - 1) {
            Some(last) =>
              if last == '-' {
                raise LexError(
                  line_no,
                  col,
                  "标识符 '\{word}' 不能以连字符结尾",
                )
              }
            None => ()
          }
        }
        if word == "PIC" || word == "PICTURE" {
          toks.push({ kind: Keyword("PIC"), line: line_no, column: col, })
          stmt_start = false
          // 扫描 PIC 模式串
          let (pat, next, pat_col) = scan_pic(cs, j, hi, line_no, col)
          if pat.length() == 0 {
            raise LexError(line_no, pat_col, "PIC 子句缺少模式串")
          }
          let kind = if pat == "X" {
            PicX
          } else if pat == "N" {
            PicN
          } else {
            PicString(pat)
          }
          toks.push({ kind, line: line_no, column: pat_col, })
          i = next
          last_line = line_no
          last_col = pat_col
          continue
        }
        match copybook_keywords.get(word) {
          Some(_) =>
            toks.push({ kind: Keyword(word), line: line_no, column: col, })
          None =>
            toks.push({ kind: Identifier(word), line: line_no, column: col, })
        }
        stmt_start = false
        i = j
        last_line = line_no
        last_col = col
        continue
      }

      // 其它字符（如 `,` `;` 在语句层面出现）→ 明确报错，不静默跳过
      raise LexError(line_no, col, "无法识别的字符 '\{c}'")
    }
  }

  toks.push({ kind: Eof, line: last_line, column: last_col, })
  toks
}

///|
/// 纯数字文本转 Int，带溢出防护。
///
/// 照抄 parser 侧 digits_to_int 的限长：超过 9 位（Int32 十进制安全
/// 上限 2,147,483,647）报 LexError —— `OCCURS 99999999999` 这类输入
/// 曾经静默回绕成一个看似正常的值，进入布局层后产生完全错误的
/// 偏移。9 位上限已覆盖一切合法用途（OCCURS/级别号/PIC 重复次数
/// 都远小于此）。
fn parse_digits(text : String) -> Int32 raise ParseError {
  let cs = text.to_array()
  if cs.length() == 0 || cs.length() > 9 {
    raise LexError(
      0,
      0,
      "数字 '\{text}' 超出 Int32 范围（最多 9 位）",
    )
  }
  let mut n = 0
  let mut i = 0
  while i < cs.length() {
    n = n * 10 + (cs[i].to_int() - 48)
    i = i + 1
  }
  n
}

///|
/// 合法级别号：01..49、66、77、88
fn is_level_number(n : Int32) -> Bool {
  (n >= 1 && n <= 49) || n == 66 || n == 77 || n == 88
}

///|
/// 从 PIC 关键字之后扫描模式串。
///
/// 返回 `(模式串, 恢复扫描的下标, 模式串起始列)`。
///
/// 规则：
/// 1. 跳过空白，取一段连续非空白字符；
/// 2. 若该段以 `.` 结尾，弹掉最后那个 `.`（它属于语句终止符）；
/// 3. 若下一段是 PIC 续接形式（`V99` / `V9(3)` / `P(2)`），拼回来；
/// 4. 转大写。
fn scan_pic(
  cs : Array[Char],
  start : Int32,
  hi : Int32,
  line_no : Int32,
  pic_col : Int32,
) -> (String, Int32, Int32) raise ParseError {
  let mut i = start
  while i < hi && is_blank(cs[i]) {
    i = i + 1
  }
  if i >= hi {
    raise LexError(line_no, pic_col, "PIC 关键字后面没有模式串")
  }
  let pat_col = i + 1
  let pat : Array[Char] = []

  // 第一段
  let mut j = i
  while j < hi && !is_blank(cs[j]) {
    pat.push(cs[j])
    j = j + 1
  }
  i = j

  // 语句终止符 `.` 不属于模式串。注意这里必须把扫描位置**退回**到该 `.`，
  // 否则外层扫描从 `j` 继续，会把句点一起跳过去，Dot token 就丢了。
  if pat.length() > 0 {
    let last = pat[pat.length() - 1]
    if last == '.' {
      let _ = pat.pop()
      i = j - 1
    }
  }

  // 续接段
  let mut more = true
  while more {
    let mut k = i
    while k < hi && is_blank(cs[k]) {
      k = k + 1
    }
    if k >= hi {
      break
    }
    let seg : Array[Char] = []
    let mut m = k
    while m < hi && !is_blank(cs[m]) {
      seg.push(cs[m])
      m = m + 1
    }
    // **续接段尾随的 `.` 是语句终止符，不是模式内容**（NEW-7，2026-11-04 审计）。
    //
    // 缺陷形态：`05 N PIC S9(3) V99.` —— V 段是 PIC 的最后一段、后面紧跟
    // 语句终止符。旧判定 `is_pic_continuation` 要求段内每个字符都是
    // 数字/`P`/括号，于是 `V99.` 因末尾那个 `.` 被判「不是续接段」，
    // 整个段被当成普通标识符 → `parse error: 数据项 'N' 的子句里出现
    // 意料之外的 标识符 'V99'`。而 `lexer.mbt` 的注释第 65-67 行明确
    // 声称支持 `PIC S9(7) V99` 写法 —— 它自己举的例子作为语句末尾即失败。
    // `PIC S9(3) V99 COMP-3.`（句点在更后面）反而是好的，所以这是
    // 「只有 V/P 段恰好收尾」的退化形态。
    //
    // 修法：判定前剥掉尾随的单句点，并入模式串后把扫描位置退回一格，
    // 让外层照常发 Dot token。只剥**一个**句点：`V99..` 这种双点仍是
    // 语法错误（第二个点由外层处理）。
    let mut seg_len = seg.length()
    let mut trailing_dot = false
    if seg_len > 0 && seg[seg_len - 1] == '.' {
      seg_len = seg_len - 1
      trailing_dot = true
    }
    let core : Array[Char] = []
    for idx = 0; idx < seg_len; idx = idx + 1 {
      core.push(seg[idx])
    }
    if is_pic_continuation(core) {
      for ch in core {
        pat.push(ch)
      }
      if trailing_dot {
        // 句点留给外层：扫描位置停在它上面（-1 后再由 i = m 前进）
        i = m - 1
      } else {
        i = m
      }
      // 尾随句点意味着语句结束，续接循环就此收尾
      if trailing_dot {
        more = false
      }
    } else {
      more = false
    }
  }

  // 校验字符集，避免把 `PIC 9-5` 之类的笔误当成模式串静默接受
  for ch in pat {
    if !is_pic_char(ch) {
      raise LexError(
        line_no,
        pat_col,
        "PIC 模式串中出现非法字符 '\{ch}'",
      )
    }
  }

  (String::from_array(pat).to_upper(), i, pat_col)
}

///|
/// 在一组 token 里按序号取 token（越界返回 Eof），便于测试与解析器使用
pub fn token_at(toks : Array[Token], index : Int32) -> Token {
  if index < 0 || index >= toks.length() {
    return { kind: Eof, line: 0, column: 0, }
  }
  toks[index]
}

///|
/// 把 token 序列压成便于断言的文本形式：`Level(1) Identifier(...) Dot`
pub fn token_kinds_text(toks : Array[Token]) -> String {
  let parts : Array[String] = []
  for t in toks {
    parts.push(t.kind.describe())
  }
  let sb = StringBuilder()
  for i, p in parts {
    if i > 0 {
      sb.write_string(" ")
    }
    sb.write_string(p)
  }
  sb.to_string()
}
