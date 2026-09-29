// EBCDIC 编码层 —— cp037（US/Canada）码表与转换
//
// ## 为什么需要这一层
//
// 大型机（z/OS、VSE、AS/400）上的字符数据一律以 **EBCDIC** 存放，而不是 ASCII。
// 二者不只是"编号不同"，连**布局逻辑**都不一样：
//
//   ASCII :  '0'..'9' = 0x30..0x39，字母连续排列，'A'(0x41) < 'a'(0x61)
//   EBCDIC:  '0'..'9' = 0xF0..0xF9，字母按 16 字节为一个"区"跳着排：
//            A..I = 0xC1..0xC9   J..R = 0xD1..0xD9   S..Z = 0xE2..0xE9
//            a..i = 0x81..0x89   j..r = 0x91..0x99   s..z = 0xA2..0xA9
//
// 所以 `EBCDIC 'A' < 'J'` 数值上成立（0xC1 < 0xD1），但 `'I'(0xC9) < 'J'(0xD1)`
// 也成立 —— 而 `'R'(0xD9) < 'S'(0xE2)` 同样成立。整个字母序靠"跳区"维持，
// 这是 IBM 当年为了让**卡片穿孔机的 12 行 × 8 列**直接对应字节而付出的代价。
//
// 数字区在 0xF0 起，是 zoned decimal 的关键：末字节高半字节放符号
// （0xC/0xF 正，0xD 负），低半字节就是数字本身。见 decode.mbt。
//
// ## 无映射字节的处理选择
//
// cp037 是一张**全定义**码表：256 个字节**全部**映射到具体 Unicode 码点
// （0x00..0x3F 映射到 C0 控制符、0xCA→U+00AD 软连字符、0xFF→U+009F 等）。
// 因此 `ebcdic_to_unicode` 对任何 0..255 的输入都返回真实码点，**不会**返回 U+FFFD。
//
// U+FFFD（REPLACEMENT CHARACTER）只作为**越界输入的防御性兜底**：
// `byte < 0 || byte > 255` 时返回 0xFFFD。正常调用路径不会走到。
//
// 反方向的 `unicode_to_ebcdic`：码点不在表中（例如任何中日韩字符、ASCII 的
// `@`(0x40) 以外未收录符号）→ 返回 `None`，由调用方决定是报错还是替换。
//
// 这保证了 API.md 要求的「全 256 项往返一致性」严格成立：
//   for b in 0..=255: unicode_to_ebcdic(ebcdic_to_unicode(b)) == Some(b)

///|
/// cp037 码表：下标是 EBCDIC 字节值，值是 Unicode 码点。
/// 16 行 × 16 列，与 IBM CDRA 公布的 CP037 表一致。
let cp037_table : Array[Int32] = [
  // 0x00 - 0x0F：C0 控制符区（原样映射到同名控制码）
  0x0000, 0x0001, 0x0002, 0x0003, 0x009C, 0x0009, 0x0086, 0x007F, 0x0097, 0x008D,
  0x008E, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F,
  // 0x10 - 0x1F
   0x0010, 0x0011, 0x0012, 0x0013, 0x009D, 0x0085, 0x0008, 0x0087, 0x0018, 0x0019,
  0x0092, 0x008F, 0x001C, 0x001D, 0x001E, 0x001F,
  // 0x20 - 0x2F：C1 控制符区
   0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x000A, 0x0017, 0x001B, 0x0088, 0x0089,
  0x008A, 0x008B, 0x008C, 0x0005, 0x0006, 0x0007,
  // 0x30 - 0x3F
   0x0090, 0x0091, 0x0016, 0x0093, 0x0094, 0x0095, 0x0096, 0x0004, 0x0098, 0x0099,
  0x009A, 0x009B, 0x0014, 0x0015, 0x009E, 0x001A,
  // 0x40 - 0x4F：0x40 是**空格**（不是 ASCII 的 0x20）
  //                0x4B = '.'  0x4D = '('  0x4E = '+'  0x4F = '|'
   0x0020, 0x00A0, 0x00E2, 0x00E4, 0x00E0, 0x00E1, 0x00E3, 0x00E5, 0x00E7, 0x00F1,
  0x00A2, 0x002E, 0x003C, 0x0028, 0x002B, 0x007C,
  // 0x50 - 0x5F：0x5A = '!'  0x5B = '$'  0x5D = ')'
   0x0026, 0x00E9, 0x00EA, 0x00EB, 0x00E8, 0x00ED, 0x00EE, 0x00EF, 0x00EC, 0x00DF,
  0x0021, 0x0024, 0x002A, 0x0029, 0x003B, 0x00AC,
  // 0x60 - 0x6F：0x60 = '-'（连字符）  0x6B = ','（逗号）  0x6F = '?'
   0x002D, 0x002F, 0x00C2, 0x00C4, 0x00C0, 0x00C1, 0x00C3, 0x00C5, 0x00C7, 0x00D1,
  0x00A6, 0x002C, 0x0025, 0x005F, 0x003E, 0x003F,
  // 0x70 - 0x7F：0x7C = '@'  0x7D = '\''  0x7F = '"'
   0x00F8, 0x00C9, 0x00CA, 0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x0060,
  0x003A, 0x0023, 0x0040, 0x0027, 0x003D, 0x0022,
  // 0x80 - 0x8F：小写 a..i 在 0x81..0x89
   0x00D8, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067, 0x0068, 0x0069,
  0x00AB, 0x00BB, 0x00F0, 0x00FD, 0x00FE, 0x00B1,
  // 0x90 - 0x9F：小写 j..r 在 0x91..0x99
   0x00B0, 0x006A, 0x006B, 0x006C, 0x006D, 0x006E, 0x006F, 0x0070, 0x0071, 0x0072,
  0x00AA, 0x00BA, 0x00E6, 0x00B8, 0x00C6, 0x00A4,
  // 0xA0 - 0xAF：小写 s..z 在 0xA2..0xA9
   0x00B5, 0x007E, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007A,
  0x00A1, 0x00BF, 0x00D0, 0x00DD, 0x00DE, 0x00AE,
  // 0xB0 - 0xBF：0xBA = '['  0xBB = ']'
   0x005E, 0x00A3, 0x00A5, 0x00B7, 0x00A9, 0x00A7, 0x00B6, 0x00BC, 0x00BD, 0x00BE,
  0x005B, 0x005D, 0x00AF, 0x00A8, 0x00B4, 0x00D7,
  // 0xC0 - 0xCF：大写 A..I 在 0xC1..0xC9（C 是 0xC3，不是 0xC2=A）
   0x007B, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047, 0x0048, 0x0049,
  0x00AD, 0x00F4, 0x00F6, 0x00F2, 0x00F3, 0x00F5,
  // 0xD0 - 0xDF：大写 J..R 在 0xD1..0xD9（0xDA 起是带音符号，跳过）
   0x007D, 0x004A, 0x004B, 0x004C, 0x004D, 0x004E, 0x004F, 0x0050, 0x0051, 0x0052,
  0x00B9, 0x00FB, 0x00FC, 0x00F9, 0x00FA, 0x00FF,
  // 0xE0 - 0xEF：大写 S..Z 在 0xE2..0xE9（0xE0、0xE1 是 \ { ，与 S 无连续关系）
   0x005C, 0x00F7, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057, 0x0058, 0x0059, 0x005A,
  0x00B2, 0x00D4, 0x00D6, 0x00D2, 0x00D3, 0x00D5,
  // 0xF0 - 0xFF：数字 0..9 在 0xF0..0xF9。zoned decimal 的低半字节就是这里
   0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037, 0x0038, 0x0039,
  0x00B3, 0x00DB, 0x00DC, 0x00D9, 0x00DA, 0x009F,
]

///|
/// U+FFFD REPLACEMENT CHARACTER，越界字节的兜底返回值
const REPLACEMENT_CHAR : Int32 = 0xFFFD

///|
/// 不可编码字符在编码时的替换字节：0x6F 是 cp037 的 '?'
/// （EBCDIC 世界的问号，语义上就是"这里有个无法表示的字符"）
const SUBSTITUTE_BYTE : Int32 = 0x6F

///|
/// 反向表：Unicode 码点 -> EBCDIC 字节。
/// cp037 是**单射**的（256 个字节对应 256 个互不相同的码点，已实测无重复），
/// 所以反向查表不会有歧义。
let cp037_reverse : Map[Int32, Int32] = {
  let m : Map[Int32, Int32] = Map([])
  let mut i = 0
  while i < 256 {
    m[cp037_table[i]] = i
    i = i + 1
  }
  m
}

///|
/// EBCDIC 单字节 -> Unicode 码点。
///
/// 输入域 0..255，输出为 cp037 规定的真实码点。越界输入返回 U+FFFD。
///
/// 例：`ebcdic_to_unicode(0xC1) == 0x41`（'A'）
pub fn ebcdic_to_unicode(byte : Int32) -> Int32 {
  if byte < 0 || byte > 255 {
    return REPLACEMENT_CHAR
  }
  cp037_table[byte]
}

///|
/// Unicode 码点 -> EBCDIC 单字节。
///
/// 码点不在 cp037 表中时返回 `None`（例如中文、日文、绝大多数 emoji）。
/// 调用方应当在收到 `None` 时报错，而不是自己编一个字节 —— 猜字节正是
/// "几十年后才发现的错位 bug" 的来源。
///
/// 例：`unicode_to_ebcdic(0x41) == Some(0xC1)`
pub fn unicode_to_ebcdic(cp : Int32) -> Int32? {
  cp037_reverse.get(cp)
}

///|
/// 整块解码：EBCDIC 字节序列 -> String。
///
/// 逐字节按 cp037 映射到 Unicode。**不做**任何 trim、不做空格填充处理 ——
/// 记录字段的定宽语义由 layout/decode 层负责，编码层只做无状态转换。
pub fn ebcdic_decode(bytes : BytesView) -> String {
  let out : Array[Char] = []
  for i = 0; i < bytes.length(); i = i + 1 {
    let cp = ebcdic_to_unicode(bytes[i].to_int())
    out.push(cp.unsafe_to_char())
  }
  String::from_array(out)
}

///|
/// 整块编码：String -> EBCDIC 字节序列。
///
/// 不可编码的字符（cp037 表中没有的码点）替换为 0x6F（'?'）。
/// 需要"宁可失败也不写错"的场合请用 `ebcdic_encode_strict`，它会返回
/// `None` 而不是静默替换 —— 往返测试必须走这条路径，否则替换会掩盖错误。
pub fn ebcdic_encode(s : StringView) -> Bytes {
  let out : Array[Byte] = []
  for ch in s {
    let b = match unicode_to_ebcdic(ch.to_int()) {
      Some(v) => v
      None => SUBSTITUTE_BYTE
    }
    out.push(b.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// 严格编码：任一字符不可编码时返回 `None`。
///
/// 返回值是**字节值数组**（0..255）而不是 `Bytes`，方便调用方在失败前
/// 就知道是哪一位出的问题（可以做精确的错误定位）。
pub fn ebcdic_encode_strict(s : StringView) -> Array[Int32]? {
  let out : Array[Int32] = []
  for ch in s {
    match unicode_to_ebcdic(ch.to_int()) {
      Some(v) => out.push(v)
      None => return None
    }
  }
  Some(out)
}

///|
/// 是否合法的 EBCDIC 数字：0xF0..0xF9（即 '0'..'9'）。
///
/// 注意这**不是** ASCII 的 0x30..0x39。zoned decimal 的低半字节判定也
/// 依赖这同一段区间，但那里还要额外检查高半字节的符号位。
pub fn is_ebcdic_digit(b : Int32) -> Bool {
  b >= 0xF0 && b <= 0xF9
}

///|
/// 是否 EBCDIC 空格：0x40。
///
/// ASCII 的空格是 0x20，在 EBCDIC 里 0x20 是 C1 控制符 U+0080。
/// 记录字段的尾部填充一律是 0x40，文本字段的 `trim_end` 必须按这个判。
pub fn is_ebcdic_space(b : Int32) -> Bool {
  b == 0x40
}

///|
/// 该字节在 cp037 表中是否有定义。
///
/// cp037 全定义，所以对 0..255 恒为 `true`；越界为 `false`。
/// 保留此函数是为了让 decode 层能表达"我要校验字节合法性"的意图，
/// 并且在未来切到 cp500/cp1047 等**存在空洞**的码表时不必改调用点。
pub fn ebcdic_has_mapping(byte : Int32) -> Bool {
  if byte < 0 || byte > 255 {
    return false
  }
  cp037_table[byte] != REPLACEMENT_CHAR
}

///|
/// 该字节映射到的字符是否"可打印"（不是控制符）。
///
/// 判定规则：映射码点不在 C0（U+0000..U+001F）、DEL（U+007F）、
/// C1（U+0080..U+009F）区间，且不是软连字符 U+00AD（Cf 类，不可见）。
/// 空格 0x40 算可打印。
///
/// decode 层校验文本字段时应使用本函数（而不是 `ebcdic_has_mapping`），
/// 因为 cp037 下后者恒真，无法区分"合法但不可见的控制字节"。
pub fn ebcdic_is_printable(byte : Int32) -> Bool {
  if byte < 0 || byte > 255 {
    return false
  }
  let cp = cp037_table[byte]
  if cp <= 0x1F {
    return false
  }
  if cp == 0x7F {
    return false
  }
  if cp >= 0x80 && cp <= 0x9F {
    return false
  }
  if cp == 0xAD {
    return false
  }
  true
}

///|
/// `ebcdic_to_unicode` 的 Char 版本，便于在 StringBuilder 里直接写。
pub fn ebcdic_char_to_unicode(b : Int32) -> Char {
  ebcdic_to_unicode(b).unsafe_to_char()
}

///|
/// `unicode_to_ebcdic` 的 Char 版本。
pub fn unicode_char_to_ebcdic(c : Char) -> Int32? {
  unicode_to_ebcdic(c.to_int())
}
