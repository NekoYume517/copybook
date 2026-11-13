///|
/// 该字段是否会产出/消费 `__nibbles`（符号半字节与 packed 填充半字节）。
///
/// 只有 zoned（Numeric + Display）与 packed（Numeric + Comp3）在存储层有
/// 这两个半字节。文本 / NATIONAL / 编辑型 / COMP 二进制 / 浮点都没有这个
/// 位置；把 `__nibbles` 套到它们身上会把文本强行解析成 Decimal，静默改写
/// 内容（`PIC X(5)` 的 `"00012"` 会变成 `"12"`）—— 见 2026-11-11 审计。
fn field_accepts_nibbles(field : FieldLayout) -> Bool {
  match field.pic.category {
    Numeric =>
      match field.pic.usage {
        Display => true
        Comp3 => true
        _ => false
      }
    _ => false
  }
}

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
      //
      // **内容损坏必须报错，不能静默降级**（NEW-6b，2026-11-08 审计）。
      // NEW-6 对 `__` 保留键的承诺是「损坏必须报错，没有误伤面」，
      // __tail_hex/__filler_hex/__float_hex 都照做，唯独这里的三种损坏
      // 形态曾被静默吞掉：整键非对象、条目非对象、半字节超出 0..15
      // （超域值会落进 encode 的默认分支丢掉符号 —— 与 __filler_hex
      // 损坏后静默写 0x40 完全同型）。这些键只可能来自 decode 的输出
      // 或蓄意构造，报错没有误伤面。
      let nibbles : Map[String, (Int32?, Int32?)] = Map([])
      match obj.get("__nibbles") {
        Some(Json::Object(nobj)) =>
          for k, jv in nobj {
            match jv {
              Object(entry) => {
                let nib_val = fn(key : String) -> Result[Int32?, String] {
                  match entry.get(key) {
                    Some(Json::Number(v, repr~)) =>
                      // 半字节值域 0..=15：超域值（256、1e20 的饱和/回绕）
                      // 必须报错而不是静默落默认分支丢符号。
                      // 大数用 repr 原文报错；无 repr 的按 Double 形式。
                      if v != v.to_int64().to_double() ||
                        v.to_int64() < 0L ||
                        v.to_int64() > 15L {
                        let shown = match repr {
                          Some(r) => r
                          None => v.to_string()
                        }
                        Err(
                          "__nibbles['\{k}'].\{key} must be an integer in 0..=15, got \{shown}",
                        )
                      } else if key == "sign" &&
                        v.to_int64() != 12L &&
                        v.to_int64() != 13L &&
                        v.to_int64() != 15L {
                        // **sign 只认 C/D/F**（CB-A3，2026-11-10 审计）：
                        // decode 的 zoned/packed 侧只接受 0xC/0xF 正号、
                        // 0xD 负号（其余区号本来就是 InvalidNumeric），
                        // 所以 sign=10/11/14 是 decode 永远写不出来的值——
                        // 静默收下会落进 encode 默认分支丢掉符号
                        // （sign 12 → 写出 F 区号，exit 0）。
                        let shown = match repr {
                          Some(r) => r
                          None => v.to_string()
                        }
                        Err(
                          "__nibbles['\{k}'].sign must be one of 12 (C, positive), 13 (D, negative), 15 (F, unsigned), got \{shown}",
                        )
                      } else {
                        Ok(Some(v.to_int()))
                      }
                    Some(Json::Null) | None => Ok(None)
                    Some(other) =>
                      Err(
                        "__nibbles['\{k}'].\{key} must be a number, got \{json_kind_name(other)}",
                      )
                  }
                }
                let sn = match nib_val("sign") {
                  Err(e) => return Err(e)
                  Ok(v) => v
                }
                let pn = match nib_val("pad") {
                  Err(e) => return Err(e)
                  Ok(v) => v
                }
                nibbles[k] = (sn, pn)
              }
              other =>
                return Err(
                  "__nibbles['\{k}'] must be an object of {sign?, pad?}, got \{json_kind_name(other)}",
                )
            }
          }
        Some(other) =>
          return Err(
            "__nibbles must be an object of {field: {sign?, pad?}}, got \{json_kind_name(other)}",
          )
        None => ()
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
          // **已知字段收到对象/数组：报错而不是静默跳过**（NEW-5，2026-11-04 审计）。
          //
          // 旧实现是 `Some(_) => ()`，于是 `{"R.NAME":{"evil":1}}` 让该字段
          // 从 map 里消失，`encode` 按「未赋值存储」写一整片 0x40 空格，
          // exit 0、零提示 —— 手写 JSON 的嵌套错误变成整字段空白，正是
          // 「绝不静默修正」要拒绝的形态。
          Some(other) =>
            return Err(
              "field '\{field.path}': expected a string/number/null, got \{json_kind_name(other)}",
            )
        }
      }
      // **超精度浮点旁路**（CB-21）：render_jsonl 在 HFP `COMP-2` 尾数低 3 位
      // 非零时写出 `{"字段路径": "<hex>"}`。这里还原成 `FloatRaw(数值, 原字节)`，
      // 让 encode 原样写回——否则「导出 JSON、编辑、导回」这条工作流会把
      // `41 80 00 00 00 00 00 01` 悄悄改成 `...00`。
      //
      // 数值取自同一行已解析的文本（字段值本身仍是近似 double），
      // 这样 `FloatRaw` 的 `f` 与 JSON 里看到的数字始终一致。
      let float_raw : Map[String, Bytes] = Map([])
      match obj.get("__float_hex") {
        Some(Json::Object(fobj)) =>
          for k, jv in fobj {
            match jv {
              Json::String(h) =>
                match hex_to_bytes(h) {
                  Some(bs) => float_raw[k] = bs
                  None =>
                    return Err(
                      "__float_hex['\{k}'] is not valid hex (odd length or non-hex character): '\{h}'",
                    )
                }
              _ => return Err("__float_hex['\{k}'] must be a hex string")
            }
          }
        _ => ()
      }
      for field in layout.fields {
        // __float_hex 只服务浮点字段：decode 只为 COMP-1/COMP-2 写这个键
        // （output.mbt 只在 FloatRaw 时发出）。其他字段上的条目保持未消费，
        // 由键对账统一报错，而不是给一条误导性的长度报错。
        let is_float_usage = match field.pic.usage {
          Comp1 => true
          Comp2 => true
          _ => false
        }
        if !is_float_usage {
          continue
        }
        let is_comp2 = match field.pic.usage {
          Comp2 => true
          _ => false
        }
        // 旁路键查找与字段值查询同款宽容度（CB-5）：先完整路径，失败
        // 回退裸名。decode 导出恒为路径键；裸名后备只服务手写构造。
        let float_bypass = match float_raw.get(field.path) {
          Some(bs) => Some((field.path, bs))
          None =>
            match float_raw.get(field.name) {
              Some(bs) => Some((field.name, bs))
              None => None
            }
        }
        match float_bypass {
          Some((bkey, bs)) => {
            // **长度必须精确**（CB-A1，2026-11-10 审计）：decode 写出的
            // 旁路恒为 COMP-2 8 字节 / COMP-1 4 字节。短了会让下面的 HFP
            // 解码固定读 8/4 字节而越界 panic（没有任何业务错误信息的
            // 契约外第六态）；长了会被静默截断、按截断值重编码 exit 0
            // （`4180000000000001` + 8 字节零尾 → 写出 `4180000000000000`）。
            // 两种都是「损坏必须报错」要拒绝的形态，与奇数长度 / 非法
            // hex 字符的既有报错同一哲学。
            let want = if is_comp2 { 8 } else { 4 }
            if bs.length() != want {
              let kind = if is_comp2 { "COMP-2" } else { "COMP-1" }
              return Err(
                "__float_hex['\{bkey}'] must be exactly \{want} bytes for \{kind}, got \{bs.length()}",
              )
            }
            // 记账：该键已被布局内的浮点字段消费（CB-A4 对账用）。
            float_raw.remove(bkey)
            // 字段文本：Text 单元格直接用；**Float 单元格**是 57-68 行把
            // "NaN"/"±Infinity" 字符串解回的特殊值 —— 渲染回它的文本形式，
            // 让下面的非有限值分支能识别（否则 NaN 会被 parse_double 的
            // catch 兜底成 0.0，误判成「编辑成 0」而丢旁路）。
            //
            // **None 与「空文本」必须分开**（2026-11-12 审计）：只有这一行
            // 真的给出了字段值才算「有值」。旧实现用 `_ => ""` 把「没有这个
            // 键」和「值是一串解析不出数字的文本」合并成同一个空串，再被
            // parse_double 的 catch 兜成 0.0，于是
            // `{"__float_hex":{"R.D":"4180000000000001"}}` 被判成「用户把值
            // 编辑成了 0」，旁路当陈旧快照丢弃，encode 写出整片 0x00 ——
            // 声明的字节事实被静默换成 0.0，退出码 0、零提示。
            // **空串 = 没有值**（契约 A2，2026-11-12）：数值/浮点字段上的
            // `""` 表示「本行没有给这个字段值」，与 `null` / 缺键同义，
            // 绝不等于 0.0。文本字段的空串在 encode 侧另有语义（若干空格），
            // 但它不会走到这里 —— 本循环只处理 COMP-1/COMP-2。
            //
            // 旧实现把 `""` 交给 `parse_double`，异常被下面的
            // `catch { _ => 0.0 }` 兜成 0.0，于是与旁路字节解出的值比较时
            // 判成「用户把值编辑成了 0」，旁路当陈旧快照丢弃 → 整片 0x00。
            let value_text : String? = match out.get(field.path) {
              Some(Text(s)) => if s.length() == 0 { None } else { Some(s) }
              Some(Float(f)) =>
                Some(
                  if f.is_nan() {
                    "NaN"
                  } else if f == 1.0 / 0.0 {
                    "Infinity"
                  } else if f == -1.0 / 0.0 {
                    "-Infinity"
                  } else {
                    format_json_number(f)
                  },
                )
              // None 与 Null 同义：这一行没有给该字段任何值（Null 是 decode
              // 对「视图解不出」的表示，浮点字段的旁路只在解出时才写出）。
              _ => None
            }
            // 非有限值先于 parse_double：`parse_double("NaN")` 抛异常，catch
            // 兜底给 0.0 会让 NaN 误判成「编辑成 0」而丢掉整条旁路。
            let f : Double = match value_text {
              None => 0.0
              Some(text) =>
                if text == "NaN" {
                  0.0 / 0.0
                } else if text == "Infinity" {
                  1.0 / 0.0
                } else if text == "-Infinity" {
                  -1.0 / 0.0
                } else {
                  try @string.parse_double(text) catch {
                    _ => 0.0
                  } noraise {
                    x => x
                  }
                }
            }
            // **值感知**（RJ-3b，2026-11-06 组委会验收意见）：
            // `__float_hex` 只在它与字段值**一致**时才生效 —— 即原始字节
            // reinterpret 回来的数与文本描述的是同一个值。不一致说明用户
            // **编辑了值**而旁路是 decode 时的旧快照：`{"R.D":9,
            // "__float_hex":{"R.D":"4180000000000001"}}`（原值 8.0+ulp 改成 9）
            // 必须按 9 编码，而不是被旧字节静默覆盖成 8.0+ulp —— 那是
            // 「编辑不生效」，与 CB-16 在视图通道上的教训同族。
            //
            // 一致性判定不能比 double 相等：8.0+ulp 的原始字节解出的 f 就是
            // 文本 "8" 的 double（文本本来就是这个近似值），比 double 会把
            // 真 CB-21 场景误判成"一致"从而失效。
            //
            // **一致性判据**（RJ-3b）：旁路字节 reinterpret 回来的 double，
            // 与字段文本解析出的 double，是否描述同一个数值。
            //
            // 为什么不比「文本重编码出的字节 vs 旁路字节」：CB-21 的旁路
            // 存在的理由恰恰是**字节 ≠ 数值**（56 位尾数塞不进 53 位 double，
            // 文本 "8" 是 `41 80 …01` 的近似）——按字节比会让真正的旁路场景
            // 全部失效。比数值则两边都是 double：CB-21 场景文本 "8" 与字节
            // 解出的 8.0 相等（旁路生效）；用户把值改成 9 后 8.0+ulp ≠ 9.0
            // （旁路过时，编辑生效）。
            //
            // NaN 特判：文本 "NaN" 解析不出数值，但 decode 写 "NaN" 的前提
            // 就是字节本身非有限 —— 文本与字节都不有限即视为一致（符号位与
            // payload 仍由旁路字节保真）。
            let mut raw : UInt64 = 0UL
            // 长度已在入口精确校验为 want（CB-A1），这里不会越界。
            for i = 0; i < want; i = i + 1 {
              raw = (raw << 8) | bs[i].to_int().to_uint64()
            }
            // **用与 decode 相同的解释函数**读旁路字节：HFP 字节必须按 HFP
            // 解（`41 80 …01` 按 HFP 是 8.0+ulp → 舍入 8.0；按 IEEE double
            // 解则是 ~1e-309 的垃圾，两个世界不能混）。IEEE 字节按位模式
            // reinterpret（NaN 场景 payload 也原样保留）。
            let byte_value : Double = if layout.float_mode == Hfp {
              // HFP 字节走 decode 同款解释（`41 80 …01` 按 HFP ≈ 8.0；
              // 按 IEEE double 解释则是 ~1e-309 的垃圾，两个世界不能混）
              if is_comp2 {
                hfp_decode_long(Bytes::from_array(bs.to_array()))
              } else {
                hfp_decode_short(Bytes::from_array(bs.to_array()))
              }
            } else if is_comp2 {
              raw.to_int64().reinterpret_as_double()
            } else {
              Float::reinterpret_from_int(raw.to_int()).to_double()
            }
            // ±Inf 的文本与字节都是 Inf，走 equal_values 自然成立；
            // NaN 的 payload 与符号位文本表示不了，`both_nan` 视作一致。
            //
            // **没有值就没有竞争的编辑**（2026-11-12 审计）：旁路键是字节层的
            // 真值，行里既然没给数值，就按声明的字节原样写回 —— 与
            // `__tail_hex` / `__filler_hex` 无条件还原同一规则。有值时才走
            // 「值一致保留旁路、值被编辑则编辑生效」的判定。
            let consistent = (f.is_nan() && byte_value.is_nan()) ||
              f == byte_value
            if value_text is None {
              out[field.path] = FloatRaw(byte_value, bs)
            } else if consistent {
              out[field.path] = FloatRaw(f, bs)
            } else {
              // 编辑后的值：丢弃过时旁路，按文本数值走普通 Float 编码。
              // 无声丢弃这里是**正确**语义（用户的编辑优先），与 NEW-6 的
              // 「hex 损坏必须报错」不同：损坏是字节级事实错误，过时是
              // 编辑的正常结果。
              out[field.path] = Float(f)
            }
          }
          None => ()
        }
      }
      // 把旁路 nibble 附回到对应字段：能解析成十进制的，直接产出带 nibble
      // 的 Decimal（scale 已按字段对齐），这样编码器拿到的就是带原始
      // 半字节的值，「decode → JSONL → encode」也能逐字节还原。
      // 解析不出来（例如浮点字段的 "Infinity"）就保持原 CellValue。
      //
      // **值感知**（RJ-3a，2026-11-06 组委会验收意见）：`__nibbles` 只在
      // 它与字段文本**一致**时才生效。不一致说明用户编辑了值 ——
      // `{"R.N":25,"__nibbles":{"R.N":{"sign":13}}}`（原值 -25 改成 +25）
      // 必须编出 `F0 F2 C5`（正号），而不是被旧符号半字节压成 `F0 F2 D5`
      // —— 那是「改正数仍写负数」，与 CB-16 在视图通道上的教训同族。
      //
      // 一致性判定：符号半字节若为 0xD（负），文本必须也描述负数；
      // 0xC/0xF（正）时文本必须非负。**零的豁免（CB-2）只保护 `"-0"`**：
      // decode 对负零写出的文本恒为 `"-0"`（CLI 实测），JSON 词法吞负号
      // 只发生在「读取」侧；因此文本 `"-0"` + sign 13 是原样往返，保持
      // 旁路优先。而文本 `"0"` + sign 13 **不可能是 decode 的输出** ——
      // 它只能是编辑（用户把 -0 改成 +0 而行尾旁路键被文本编辑器原样
      // 保留）或下游系统的显式规范化，编辑必须生效（RJ-3a 补遗，
      // 2026-11-08 审计：旧豁免把 `"-0"` 与 `"0"` 一起豁免，编辑后的
      // 正零被静默翻回负零 `00 0D`）。
      for field in layout.fields {
        // 只有 zoned / packed 十进制有符号半字节与填充半字节。其它字段上的
        // `__nibbles` 保持未消费，交给末尾的键对账报错 —— 否则文本会被
        // 强行解析成 Decimal 并改写（2026-11-11 审计）。
        if !field_accepts_nibbles(field) {
          continue
        }
        // 旁路键查找与字段值查询同款宽容度（CB-5）：先完整路径，失败
        // 回退裸名。命中即从 map 里移除（CB-A4 对账用：剩下来的键就是
        // 没有命中任何字段的损坏键）。
        let nib = match nibbles.get(field.path) {
          Some(np) => {
            nibbles.remove(field.path)
            Some(np)
          }
          None =>
            match nibbles.get(field.name) {
              Some(np) => {
                nibbles.remove(field.name)
                Some(np)
              }
              None => None
            }
        }
        match nib {
          Some((sn, pn)) => {
            // **pad 只在 COMP-3 有意义**（CB-A3，2026-11-10 审计）：非零
            // pad 是 packed 尾字节的高半字节，zoned 等其他用法根本没有
            // 这个位置——decode 从不为它们写 pad，非零 pad 只可能是损坏，
            // 静默忽略会让损坏的 JSONL 悄悄编出「看起来正常」的字节。
            // pad=0 是恒等值，任何用法都无害。
            match pn {
              Some(p) =>
                if p != 0 {
                  let is_comp3 = match field.pic.usage {
                    Comp3 => true
                    _ => false
                  }
                  if !is_comp3 {
                    return Err(
                      "__nibbles['\{field.path}'].pad applies only to COMP-3 fields, got \{p}",
                    )
                  }
                }
              None => ()
            }
            match out.get(field.path) {
              Some(Text(s)) =>
                match parse_decimal_with_scale(s, field.pic) {
                  Some(d) => {
                    // **符号以符号半字节为准**：0xD 是字节层的负号事实。
                    // 文本 "-0" 在系数为 0 时是唯一能把符号带进 JSON 的
                    // 形态（CB-2）；只有它享受豁免。非零值仍由文本与
                    // 半字节共同决定（文本写 `-123`，半字节写 D）。
                    let sn_negative = sn == Some(0xD)
                    let zero = d.coefficient == 0L
                    // 编辑检测：半字节说负、文本说正，两者矛盾 → 文本是
                    // 用户的编辑，旁路过时。零值上：文本 "0"（非 "-0"）
                    // + 0xD 同样矛盾 —— decode 原文不会是裸 "0"。
                    let zero_exempt = zero && s == "-0"
                    let edited = sn_negative && !d.negative && !zero_exempt
                    if edited {
                      // 编辑后的正数（含 -0 → +0）：sign_nibble 给 0xC
                      // （zoned/packed 正号的最常见形态）。给 None 会让
                      // encode 写 F 区号 —— 也合法（CB-12），但 C 是
                      // 「有符号字段的正号」，与字段声明 PIC S9 的语义更贴。
                      out[field.path] = Decimal(Decimal::{
                        coefficient: d.coefficient,
                        scale: d.scale,
                        negative: false,
                        sign_nibble: Some(0xC),
                        pad_nibble: pn,
                      })
                    } else {
                      let negative = d.negative || sn_negative
                      out[field.path] = Decimal(Decimal::{
                        coefficient: d.coefficient,
                        scale: d.scale,
                        negative,
                        sign_nibble: sn,
                        pad_nibble: pn,
                      })
                    }
                  }
                  None => ()
                }
              // **没有值 = 没有竞争的编辑**（2026-11-12 审计）：与
              // `__float_hex` / `__tail_hex` / `__filler_hex` 统一，旁路键
              // 就是字节真值。旧实现在这里 `_ => ()` 走掉，于是
              // `{"__nibbles":{"R.N":{"sign":13}}}`（行里没给 R.N 的值）
              // 声明的 0xD 被静默丢弃，encode 写出 `F0 F0 F0` / `00 0C`
              // —— 负号变成正号，exit 0、零提示。
              //
              // 系数按「未赋值存储 = 0」取零，符号与填充半字节按声明写回
              // （`PIC S9(3)` 的负零 = `F0 F0 D0`，COMP-3 的负零 = `00 0D`）。
              // 只处理 None/Null：其它非文本单元格（Int/Decimal/…）保持
              // 既有行为不动 —— 那才可能带着用户的编辑。
              //
              // **重定义视图的「没有值」不物化**（2026-11-13 审计）：视图的
              // `null` 在契约里是「这一段我不写，字节由主视图决定」（API.md §6
              // 的视图跳过 / A2 的 null 语义）。物化成一个负零数字就是**以视图
              // 身份覆盖主视图的字节** —— `{"R.M":123,"R.V":null,
              // "__nibbles":{"R.V":{"sign":13}}}` 修复前写出 `F0 F0 D0`，
              // 主视图的 123 被静默改成 −0，exit 0、零提示。
              //
              // 旁路键在查找阶段已被 `nibbles.remove` 消费，因此这里跳过
              // 不会落进末尾的键对账（不会报 "does not match any field"）。
              Some(Null) | None =>
                if !field.is_redefining {
                  out[field.path] = Decimal(Decimal::{
                    coefficient: 0L,
                    scale: field.pic.scale,
                    negative: sn == Some(0xD),
                    sign_nibble: sn,
                    pad_nibble: pn,
                  })
                }
              _ => ()
            }
          }
          None => ()
        }
      }
      // **键对账**（CB-A4，2026-11-10 审计）：上面两轮按字段消费时把命中
      // 的键从 map 里移除，这里还剩着的键要分两类：
      //   - 指向**不存在字段**（或浮点键落在非浮点字段上）→ 损坏，报错。
      //     decode 写出的键恒为布局内字段，静默忽略会让符号/原始字节
      //     信息无声丢失。
      //   - 指向**真实字段**但被同字段的路径键遮蔽（CB-5：裸名与路径
      //     同时出现时路径优先）→ 合法冗余，沿用字段值同键双写的宽容。
      let nib_known = fn(k : String) -> Bool {
        for f in layout.fields {
          if (f.path == k || f.name == k) && field_accepts_nibbles(f) {
            return true
          }
        }
        false
      }
      let float_known = fn(k : String) -> Bool {
        for f in layout.fields {
          let is_float = match f.pic.usage {
            Comp1 => true
            Comp2 => true
            _ => false
          }
          if (f.path == k || f.name == k) && is_float {
            return true
          }
        }
        false
      }
      for k in nibbles.keys() {
        if !nib_known(k) {
          return Err(
            "__nibbles['\{k}'] does not match any field in this copybook",
          )
        }
      }
      for k in float_raw.keys() {
        if !float_known(k) {
          return Err(
            "__float_hex['\{k}'] does not match any COMP-1/COMP-2 field in this copybook",
          )
        }
      }
      // 尾部字节旁路（CB-9）：render_jsonl 写出的 `__tail_hex` 在这里还原成
      // Bytes，键名不变，由 encode_record 在写完全部字段后原样回填到
      // 「只有重定义视图覆盖」的空洞区间。没有这个键时行为与旧版完全一致。
      match obj.get("__tail_hex") {
        Some(Json::String(h)) =>
          match hex_to_bytes(h) {
            Some(bs) => out["__tail_hex"] = Bytes(bs)
            None =>
              return Err(
                "__tail_hex is not valid hex (odd length or non-hex character): '\{h}'",
              )
          }
        Some(_) => return Err("__tail_hex must be a hex string")
        None => ()
      }
      // **空洞几何旁路**（B1，2026-11-12）：`__tail_gap` / `__filler_gap`
      // 写出空洞的**区间**，让 encode 能按绝对位置映射快照（只带字节序列时
      // 长度只能证明字节数对，证明不了位置对）。规范成 `"6:10;4:6"` 存进
      // 行映射 —— `CellValue` 没有区间变体，encode 端按同一格式还原。
      for key in ["__tail_gap", "__filler_gap"] {
        match obj.get(key) {
          None => ()
          Some(j) =>
            match parse_gap_intervals(key, j, layout.byte_length) {
              Ok(spec) => out[key] = Text(spec)
              Err(e) => return Err(e)
            }
        }
      }
      // 中部空洞旁路（P1-2）：render_jsonl 写出的 `__filler_hex` 在这里
      // 还原成 Bytes，由 encode_record 在写完全部字段后回填 FILLER 区。
      // 没有这个键时行为与旧版完全一致。
      //
      // **内容损坏必须报错，不能静默降级**（NEW-6，2026-11-04 审计）。
      // 旧实现解析失败走 `None => ()`，于是把 `__filler_hex` 改成奇数长度的
      // "e" 之后 encode 仍 exit 0，对应字节被写成 0x40 —— 文件截断/传输损坏
      // 之后，「无损往返」变成静默改字节，用户毫无信号。
      // 这些键都以 `__` 开头：它们只可能来自 decode 的输出或蓄意构造，
      // 报错没有误伤面（不像未知字段那样要容忍手写 JSON 的额外键）。
      match obj.get("__filler_hex") {
        Some(Json::String(h)) =>
          match hex_to_bytes(h) {
            Some(bs) => out["__filler_hex"] = Bytes(bs)
            None =>
              return Err(
                "__filler_hex is not valid hex (odd length or non-hex character): '\{h}'",
              )
          }
        Some(_) => return Err("__filler_hex must be a hex string")
        None => ()
      }
      Ok(out)
    }
    _ => Err("JSONL line must be an object")
  }
}

///|
/// 解析并校验空洞几何旁路键（B1，2026-11-12）：`"__tail_gap":[[6,10]]`。
///
/// 返回规范串 `"6:10"` / `"4:6;8:10"`，encode 端按同一格式还原区间。
///
/// 校验三条：每项必须是 `[start, end]` 二元数组、两个偏移都是
/// `0..=byte_length` 内的整数、`start < end`。损坏必须报错而不是静默丢弃 ——
/// 与 `__tail_hex` / `__filler_hex` 同族（NEW-6）：这些键只来自 decode 的
/// 输出或蓄意构造，报错没有误伤面。**没有这个键时行为与旧版完全一致**，
/// 这是旧 JSONL 迁移的前提。
fn parse_gap_intervals(
  key : String,
  j : Json,
  byte_length : Int32,
) -> Result[String, String] {
  match j {
    Json::Array(items) => {
      let parts : Array[String] = []
      for it in items {
        match it {
          Json::Array(pair) => {
            if pair.length() != 2 {
              return Err(
                "\{key} entries must be [start, end] pairs, got \{pair.length()} element(s)",
              )
            }
            let vals : Array[Int32] = []
            for p in pair {
              match p {
                Json::Number(v, repr~) => {
                  let vi = v.to_int64()
                  if vi.to_double() != v ||
                    vi < 0L ||
                    vi > byte_length.to_int64() {
                    let shown = match repr {
                      Some(r) => r
                      None => v.to_string()
                    }
                    return Err(
                      "\{key} offsets must be integers in 0..=\{byte_length}, got \{shown}",
                    )
                  }
                  vals.push(vi.to_int())
                }
                other =>
                  return Err(
                    "\{key} offsets must be numbers, got \{json_kind_name(other)}",
                  )
              }
            }
            let s = vals[0]
            let e = vals[1]
            if s >= e {
              return Err(
                "\{key} interval [\{s}, \{e}) must be non-empty (start < end)",
              )
            }
            parts.push(s.to_string() + ":" + e.to_string())
          }
          other =>
            return Err(
              "\{key} must be an array of [start, end] pairs, got \{json_kind_name(other)}",
            )
        }
      }
      Ok(parts.join(";"))
    }
    other =>
      Err(
        "\{key} must be an array of [start, end] pairs, got \{json_kind_name(other)}",
      )
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
/// JSON 值的种类名，用于「已知字段收到错误类型的值」的报错。
///
/// 只在报错路径调用，所以实现可以是简单的 match —— 目的不是给调用方
/// 一个可编程分类，而是让错误消息能说清「你给的是对象，这里要字符串」，
/// 而不是只丢一句 invalid。
fn json_kind_name(j : Json) -> String {
  match j {
    Object(_) => "an object"
    Array(_) => "an array"
    String(_) => "a string"
    Number(_, ..) => "a number"
    True => "true"
    False => "false"
    Null => "null"
  }
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
