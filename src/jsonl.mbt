///|
/// 从 JSONL 行解析出一个记录的值映射。
///
/// 接受两种数值形态：
///   - `Json::Number` 带 `repr`（`render_jsonl` 写出的原文）→ 直接当十进制串
///   - `Json::Number` 无 `repr`（手写 JSON，如 `42`）→ 用 Double 的字符串形式
///
/// 其他值：
///   - `String` → Text（数值字段在 encode 层会被解析成 Decimal）
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
      // 同时按完整路径和裸名查找，兼容手写与导出的两种写法
      let out : Map[String, CellValue] = Map([])
      for field in layout.fields {
        let raw = match obj.get(field.path) {
          Some(v) => Some(v)
          None => obj.get(field.name)
        }
        match raw {
          None => ()
          Some(Json::String(s)) => out[field.path] = Text(s)
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
      Ok(out)
    }
    _ => Err("JSONL line must be an object")
  }
}

///|
/// 把 Double 渲染成不带科学计数法的十进制串。
///
/// `42.0` → `"42"`，`12345.67` → `"12345.67"`。
/// 只用于**手写 JSON 没有 repr** 的兜底路径；导出的 JSONL 总是带 repr。
fn format_json_number(d : Double) -> String {
  // 整数值直接去掉小数点
  if d == d.to_int().to_double() {
    return d.to_int().to_string()
  }
  d.to_string()
}
