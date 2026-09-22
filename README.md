# Embedding Python in Zig

A Zig application that embeds the CPython interpreter directly into a standalone binary. The Zig program passes an arbitrary byte array payload to a Python program, executes it, and retrieves a numeric return value back in Zig.

There are no external system dependencies or pre-installed Python required; everything is built and linked using only [Zig](https://ziglang.org/).

---

## Features

- **Embedded CPython 3.12 Runtime**: Fully self-contained Python interpreter embedded into a native Zig executable.
- **Byte Array Interop**: Passes raw Zig byte slices directly into Python as `bytes` objects.
- **Multiple Calling Conventions**:
  - Automatically invokes functions named `process(data: bytes)`, `main(data: bytes)`, or `run(data: bytes)`.
  - Supports custom function names via `-f` / `--func`.
  - Supports top-level script evaluation where results are assigned to a global `result` or `ret` variable (e.g. `result = sum(data)`).
- **Type-Safe Return Value**: Validates and converts the Python numeric return value (`int`, `float`, or `bool`) into a native Zig `i64` integer.
- **Automatic Runtime Path Resolution**: Resolves the bundled Python standard library (`lib/python3.12`) relative to the executable path via the PEP 587 `PyConfig` initialization API.
- **Error Handling**: Captures and prints Python tracebacks directly if exceptions occur, propagating clean error codes to Zig.

---

## Building

Build the project using Zig:

```bash
zig build
```

This compiles:
- `zig-out/bin/embed_python`: The Zig program embedding Python.
- `zig-out/bin/python`: The standard CPython interpreter.
- `zig-out/lib/python3.12/`: The Python standard library.

---

## Usage

### 1. Default Built-in Demo
Running without arguments runs a built-in demo script that calculates the sum of a sample byte array:

```bash
./zig-out/bin/embed_python
```

Output:
```text
=== No Python script provided: running default demo ===
[Zig] Passing byte array: { 10, 20, 30, 40, 50, 60, 70 } (len=7)
[Python] Received 7 bytes: b'\n\x14\x1e(2<F'
[Python] Sum of byte values = 280
[Zig] Python returned number: 280
```

### 2. Inline Python Code (`-c`)

Pass inline Python code and an input byte string:

```bash
./zig-out/bin/embed_python -c "def process(data: bytes): return sum(data)" "hello"
```

Output:
```text
[Zig] Passing 5 bytes to Python...
[Zig] Python returned number: 532
```

Using top-level script evaluation with the global `data` variable:

```bash
./zig-out/bin/embed_python -c "result = len(data) * 10" "payload"
```

Output:
```text
[Zig] Passing 7 bytes to Python...
[Zig] Python returned number: 70
```

### 3. Running a Python Script File

Create a Python script (such as [`example.py`](example.py)):

```python
def process(data: bytes) -> int:
    print(f"[example.py] Processing {len(data)} bytes of data...")
    checksum = 0
    for b in data:
        checksum = (checksum * 31 + b) & 0xFFFFFFFF
    return checksum
```

Execute the script with an input byte payload:

```bash
./zig-out/bin/embed_python example.py "Hello, Zig!"
```

Or run directly through the Zig build system:

```bash
zig build run-embed -- example.py "Hello, Zig!"
```

Output:
```text
[Zig] Passing 11 bytes to Python...
[example.py] Processing 11 bytes of data...
[Zig] Python returned number: 3724543695
```

---

## Command-Line Options

```text
Usage: embed_python [options] [SCRIPT_FILE | -c "CODE"] [BYTES]

Options:
  -c "CODE"         Inline Python code string
  -b, --bytes DATA  Byte array payload (can also be passed as 2nd positional arg)
  -f, --func NAME   Name of function to call (default: process, main, run, or 'result' var)
  -h, --help        Show this help message
```

---

## Project Structure

- [`embed_python.zig`](embed_python.zig): Main Zig application that initializes CPython, passes byte arrays, executes the code, and extracts the returned number.
- [`example.py`](example.py): Example Python script demonstrating processing input bytes and returning an integer checksum.
- [`build.zig`](build.zig): Zig build script configuring CPython C source compilation, stdlib packaging, and executable linking.
