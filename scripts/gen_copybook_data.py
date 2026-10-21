"""生成 copybook 示例用的定长二进制数据（真实 EBCDIC + COMP-3）。

用来验证 decode/encode 的往返正确性。这是测试夹具的权威生成器：
如果 MoonBit 侧的 decode 输出与这里算的不一样，就是 MoonBit 侧错了。
"""

import struct

# ---------- EBCDIC cp037 关键映射 ----------
E2A = {
    "A": 0xC1, "B": 0xC2, "C": 0xC3, "D": 0xC4, "E": 0xC5,
    "F": 0xC6, "G": 0xC7, "H": 0xC8, "I": 0xC9,
    "J": 0xD1, "K": 0xD2, "L": 0xD3, "M": 0xD4, "N": 0xD5,
    "O": 0xD6, "P": 0xD7, "Q": 0xD8, "R": 0xD9,
    "S": 0xE2, "T": 0xE3, "U": 0xE4, "V": 0xE5, "W": 0xE6,
    "X": 0xE7, "Y": 0xE8, "Z": 0xE9,
    "a": 0x81, "b": 0x82, "c": 0x83, "d": 0x84, "e": 0x85,
    "f": 0x86, "g": 0x87, "h": 0x88, "i": 0x89,
    "j": 0x91, "k": 0x92, "l": 0x93, "m": 0x94, "n": 0x95,
    "o": 0x96, "p": 0x97, "q": 0x98, "r": 0x99,
    "s": 0xA2, "t": 0xA3, "u": 0xA4, "v": 0xA5, "w": 0xA6,
    "x": 0xA7, "y": 0xA8, "z": 0xA9,
    "0": 0xF0, "1": 0xF1, "2": 0xF2, "3": 0xF3, "4": 0xF4,
    "5": 0xF5, "6": 0xF6, "7": 0xF7, "8": 0xF8, "9": 0xF9,
    " ": 0x40, ",": 0x6B, ".": 0x4B, "-": 0x60,
    "(": 0x4D, ")": 0x5D, "$": 0x5B, "*": 0x5C, "/": 0x61,
}


def ebc(text: str, length: int) -> bytes:
    """编码定长文本字段，右侧补 EBCDIC 空格 0x40。"""
    out = bytes(E2A.get(ch, 0x40) for ch in text)
    if len(out) > length:
        out = out[:length]
    return out + bytes([0x40]) * (length - len(out))


def zoned(value: int, digits: int, signed: bool = False) -> bytes:
    """zoned decimal：每个数字一个字节，最后一字节高半字节放符号。

    ASCII 的 '0' 是 0x30，EBCDIC 的 '0' 是 0xF0 —— 这是最容易错的地方。
    """
    s = f"{abs(value):0{digits}d}"
    out = bytearray(E2A[d] for d in s)
    if signed:
        # 负数用 0xD，正数用 0xC
        sign = 0xD if value < 0 else 0xC
        out[-1] = (sign << 4) | (out[-1] & 0x0F)
    return bytes(out)


def comp3(value: int, digits: int, scale: int, signed: bool = True) -> bytes:
    """打包十进制 COMP-3：每字节两个半字节，最后低半字节是符号。

    值 1234567 且 scale=2 表示 12345.67，实际数字串是 "1234567"。
    字节数 = ceil((digits + 1) / 2)
    """
    total_digits = digits + scale
    s = f"{abs(value):0{total_digits}d}"
    # 转成半字节流
    nibbles = [int(ch) for ch in s]
    sign = 0xD if value < 0 else 0xC  # 0xF 表示无符号
    nibbles.append(sign)
    if len(nibbles) % 2:
        nibbles.insert(0, 0)
    out = bytearray()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    nbytes = -(-(total_digits + 1) // 2)
    return bytes(out[-nbytes:])


def comp(value: int, digits: int, signed: bool = True) -> bytes:
    """二进制 COMP：n<=4 -> 2 字节, n<=9 -> 4 字节, n<=18 -> 8 字节，大端。"""
    if digits <= 4:
        n = 2
    elif digits <= 9:
        n = 4
    else:
        n = 8
    return value.to_bytes(n, "big", signed=signed)


# ---------- customer.cpy ----------
# 01 CUSTOMER-RECORD
#    05 CUST-ID     PIC 9(8)          offset 0  len 8
#    05 CUST-NAME   PIC X(30)         offset 8  len 30
#    05 BALANCE     PIC S9(7)V99 COMP-3 offset 38 len 5
#    05 OPEN-DATE   PIC 9(8)          offset 43 len 8
#    05 FLAGS
#       10 ACTIVE   PIC X(1)          offset 51 len 1
#       10 TIER     PIC 9(2)          offset 52 len 2
# 总长 54


def customer_record(id_, name, balance_cents, open_date, active, tier):
    assert len(str(id_)) <= 8
    assert len(str(open_date)) == 8
    rec = bytearray()
    rec += zoned(id_, 8)                    # 8
    rec += ebc(name, 30)                    # 30 -> 38
    rec += comp3(balance_cents, 7, 2)       # 5  -> 43
    rec += zoned(int(open_date), 8)         # 8  -> 51
    rec += ebc(active, 1)                   # 1  -> 52
    rec += zoned(tier, 2)                   # 2  -> 54
    assert len(rec) == 54, len(rec)
    return bytes(rec)


def main():
    records = [
        # id,      name,           balance(cents), date,     active, tier
        (1001, "ADA LOVELACE", 123456789, 20240115, "Y", 3),
        (1002, "ALAN TURING", -9876543, 20230602, "Y", 1),
        (1003, "GRACE HOPPER", 500, 19920101, "N", 5),
        (1004, "K JOHNSON", 0, 20201231, "Y", 2),
        (1005, "J VON NEUMANN", -1, 19550608, "N", 4),
    ]
    data = b"".join(
        customer_record(*r) for r in records
    )
    with open("examples/customer.dat", "wb") as f:
        f.write(data)

    print(f"wrote examples/customer.dat: {len(data)} bytes, {len(records)} records,"
          f" record length {len(data) // len(records)}")
    for r in records:
        print(f"  id={r[0]} name={r[1]!r} bal_cents={r[2]} date={r[3]} "
              f"active={r[4]} tier={r[5]}")
    # 打印 hex 便于人工核对
    print("\nfirst record hex:")
    print("  " + data[:54].hex(" "))


if __name__ == "__main__":
    main()
