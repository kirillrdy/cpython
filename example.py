def process(data: bytes) -> int:
    print(f"[example.py] Processing {len(data)} bytes of data...")
    checksum = 0
    for b in data:
        checksum = (checksum * 31 + b) & 0xFFFFFFFF
    return checksum
