///|
/// 从 JSONL 行解析出一个记录的值映射。
///
/// 接受两种数值形态：
///   - `Json::Number` 带 `repr`（`render_jsonl` 写出的原文）→ 直接当十进制串
///   - `Json::Number` 无 `repr`（手写 JSON，如 `42`）→ 用 Double 的字符串形式
///
/// 其他值：
///   - `String` → Text（数值字段在 encode 层会被解析成 Decimal；
///     但 `"Infinity"` / `"-Infinity"` / `"NaN"` 是 render_jsonl 为
///     COMP-1/2 非有限值写出的**专用表示**，解回 Float 而不是 Text）
///   - `null`   → Null（编码时按 0/空格补齐）
///   - `true/false` → Bool
///   - 数组/对象 → 该字段跳过（不猜含义）
pub fn parse_jsonl_row(
  layout : RecordLayout,
  line : String,
) -> Result[Map[String, CellValue], String] {
  let parsed = try @json.parse(line) catch {
    _ => return Err("invalid JSON")
  } noraise {
    v => v
  }
  match parsed {
    Object(obj) => {
      // 字节保真的旁路信息：`{"__nibbles": {"字段路径": {"sign": 12, "pad": 15}}}`
      // 见 render_jsonl / FIDELITY.md。没有这个键时行为与旧版完全一致。
      let nibbles : Map[String, (Int32?, Int32?)] = Map([])
      match obj.get("__nibbles") {
        Some(Json::Object(nobj)) =>
          for k, jv in nobj {
            match jv {
              Object(entry) => {
                let sn = match entry.get("sign") {
                  Some(Json::Number(v, ..)) => Some(v.to_int())
                  _ => None
                }
                let pn = match entry.get("pad") {
                  Some(Json::Number(v, ..)) => Some(v.to_int())
                  _ => None
                }
                nibbles[k] = (sn, pn)
              }
              _ => ()
            }
          }
        _ => ()
      }
      // 同时按完整路径和裸名查找，兼容手写与导出的两种写法
      let out : Map[String, CellValue] = Map([])
      for field in layout.fields {
        let raw = match obj.get(field.path) {
          Some(v) => Some(v)
          None => obj.get(field.name)
        }
        match raw {
          None => ()
          Some(Json::String(s)) =>
            // 非有限浮点的字符串表示（IEEE 754 文本约定）优先于 Text
            if s == "Infinity" {
              out[field.path] = Float(1.0 / 0.0)
            } else if s == "-Infinity" {
              out[field.path] = Float(-1.0 / 0.0)
            } else if s == "NaN" {
              out[field.path] = Float(0.0 / 0.0)
            } else {
              out[field.path] = Text(s)
            }
          Some(Json::Number(d, repr~)) => {
            let text = match repr {
              Some(r) => r
              None => format_json_number(d)
            }
            out[field.path] = Text(text)
          }
          Some(Json::Null) => out[field.path] = Null
          Some(Json::True) => out[field.path] = Bool(true)
          Some(Json::False) => out[field.path] = Bool(false)
          Some(_) => ()
        }
      }
      // 把旁路 nibble 附回到对应字段：能解析成十进制的，直接产出带 nibble
      // 的 Decimal（scale 已按字段对齐），这样编码器拿到的就是带原始
      // 半字节的值，「decode → JSONL → encode」也能逐字节还原。
      // 解析不出来（例如浮点字段的 "Infinity"）就保持原 CellValue。
      for field in layout.fields {
        match nibbles.get(field.path) {
          Some((sn, pn)) =>
            match out.get(field.path) {
              Some(Text(s)) =>
                match parse_decimal_with_scale(s, field.pic) {
                  Some(d) => {
                    // **符号以符号半字节为准**：0xD 是字节层的负号事实。
                    // 文本在系数为 0 时会丢掉负号 —— JSON 不允许定点类型，
                    // `-0` 经核心 JSON 词法后原文不保留（repr 只为超出 double
                    // 精确范围的数字保留），文本只剩 "0"。若这里只看文本，
                    // zoned `F0 F0 D0` / packed `00 0D` 会被重编码成正零
                    // `F0 F0 F0` / `00 0C`（CB-2）。非零值仍由文本与半字节
                    // 共同决定（文本写 `-123`，半字节写 D），两者一致。
                    let negative = d.negative || sn == Some(0xD)
                    out[field.path] = Decimal(Decimal::{
                      coefficient: d.coefficient,
                      scale: d.scale,
                      negative,
                      sign_nibble: sn,
                      pad_nibble: pn,
                    })
                  }
                  None => ()
                }
              _ => ()
            }
          None => ()
        }
      }
      // 尾部字节旁路（CB-9）：render_jsonl 写出的 `__tail_hex` 在这里还原成
      // Bytes，键名不变，由 encode_record 在写完全部字段后原样回填到
      // 「只有重定义视图覆盖」的空洞区间。没有这个键时行为与旧版完全一致。
      match obj.get("__tail_hex") {
        Some(Json::String(h)) =>
          match hex_to_bytes(h) {
            Some(bs) => out["__tail_hex"] = Bytes(bs)
            None => ()
          }
        _ => ()
      }
      Ok(out)
    }
    _ => Err("JSONL line must be an object")
  }
}

///|
/// 小写/大写十六进制串 → Bytes。长度非偶或含非十六进制字符返回 None。
fn hex_to_bytes(h : String) -> Bytes? {
  let cs = h.to_array()
  if cs.length() % 2 != 0 {
    return None
  }
  fn nib(c : Char) -> Int32? {
    if c >= '0' && c <= '9' {
      Some(c.to_int() - '0'.to_int())
    } else if c >= 'a' && c <= 'f' {
      Some(c.to_int() - 'a'.to_int() + 10)
    } else if c >= 'A' && c <= 'F' {
      Some(c.to_int() - 'A'.to_int() + 10)
    } else {
      None
    }
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < cs.length() {
    let hi = nib(cs[i])
    let lo = nib(cs[i + 1])
    match (hi, lo) {
      (Some(a), Some(b)) => out.push(((a << 4) | b).to_byte())
      _ => return None
    }
    i = i + 2
  }
  Some(Bytes::from_array(out))
}

///|
/// 把十进制文本解析成 `Decimal`，scale 按字段的 PIC 对齐，
/// 并（由调用方）挂上原始半字节。
///
/// 只在 JSONL 旁路 nibble 存在时使用；解析失败返回 `None`，
/// 由调用方保持原有的宽容行为（把错误留给编码层报）。
fn parse_decimal_with_scale(s : String, pic : PicClause) -> Decimal? {
  match parse_decimal_text(s) {
    Some(d) => {
      let want = pic.scale
      if d.scale == want {
        Some(d)
      } else if d.scale < want {
        let mut coef = d.coefficient
        let mut k = d.scale
        while k < want {
          if coef > 922337203685477580L || coef < -922337203685477580L {
            return None
          }
          coef = coef * 10L
          k = k + 1
        }
        Some(Decimal::{
          coefficient: coef,
          scale: want,
          negative: d.negative,
          sign_nibble: None,
          pad_nibble: None,
        })
      } else {
        let mut coef = d.coefficient
        let mut k = d.scale
        while k > want {
          if coef % 10L != 0L {
            return None
          }
          coef = coef / 10L
          k = k - 1
        }
        Some(Decimal::{
          coefficient: coef,
          scale: want,
          negative: d.negative,
          sign_nibble: None,
          pad_nibble: None,
        })
      }
    }
    None => None
  }
}

///|
/// 把 Double 渲染成不带科学计数法的十进制串。
///
/// `42.0` → `"42"`，`12345.67` → `"12345.67"`。
/// 只用于**手写 JSON 没有 repr** 的兜底路径；导出的 JSONL 总是带 repr。
///
/// **负零必须写成 `-0`**：`(-0.0).to_int()` 是 0，走整数折叠就把符号丢了，
/// 而 `Decimal{coefficient:0, negative:true}` 编码出的字节与正零不同
/// （zoned `F0 F0 D0` vs `F0 F0 F0`，packed `00 0D` vs `00 0C`）。CB-2 正是
/// 在这一步把负零变成正零，于是 verify（内存路径）与 JSONL 路径互相矛盾。
fn format_json_number(d : Double) -> String {
  // Double 的符号位是 ±0 唯一的区别；reinterpret 成 Int64 后最高位即符号位。
  if d == 0.0 {
    return if d.reinterpret_as_int64() < 0L { "-0" } else { "0" }
  }
  // 整数值直接去掉小数点
  if d == d.to_int().to_double() {
    return d.to_int().to_string()
  }
  d.to_string()
}
