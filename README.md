# Embedding Python in Zig

A standalone Zig program that embeds CPython, passes a byte array to Python, and receives a number back in Zig.

## Build

```bash
zig build
```

Outputs:
- `./zig-out/bin/embed_python`
- `./zig-out/bin/python`

## Run

### Built-in Demo
```bash
./zig-out/bin/embed_python
```

### Inline Python (`-c`)
```bash
# Via function:
./zig-out/bin/embed_python -c "def process(data: bytes): return sum(data)" "hello"

# Via global variable:
./zig-out/bin/embed_python -c "result = len(data)" "payload"
```

### Script File
```bash
./zig-out/bin/embed_python example.py "Hello, Zig!"
```

## Options

```text
embed_python [options] [SCRIPT_FILE | -c "CODE"] [BYTES]

Options:
  -c "CODE"         Inline Python code string
  -b, --bytes DATA  Byte array payload (or 2nd positional argument)
  -f, --func NAME   Function to call (default: process, main, run, or 'result' variable)
  -h, --help        Show help
```

Python can receive the byte array via:
- Function: `def process(data: bytes) -> int` (or `main`, `run`, or `--func`)
- Global variable: `result = len(data)`
