const std = @import("std");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", "1");
    @cInclude("Python.h");
});

/// Evaluates a Python program, passing it `input_bytes`.
///
/// Python can receive the byte array in two ways:
/// 1. As an argument to a function (`process(data: bytes)`, `main(data: bytes)`, or `run(data: bytes)`, or custom name).
/// 2. Via the global variable `data` or `input_bytes` directly in the script (e.g. `result = len(data)`).
///
/// Python returns a number:
/// - From the return value of the function, OR
/// - From the global variable `result` / `ret`.
///
/// Returns the number returned by Python as an i64.
pub fn runPythonWithBytes(
    python_code_z: [:0]const u8,
    input_bytes: []const u8,
    explicit_func_name: ?[:0]const u8,
) !i64 {
    // 1. Get the __main__ module and its dictionary
    const main_mod = c.PyImport_AddModule("__main__") orelse {
        c.PyErr_Print();
        return error.PythonModuleError;
    };
    const global_dict = c.PyModule_GetDict(main_mod) orelse {
        c.PyErr_Print();
        return error.PythonDictError;
    };

    // 2. Create the Python bytes object from Zig input_bytes
    const py_bytes = c.PyBytes_FromStringAndSize(
        if (input_bytes.len > 0) @ptrCast(input_bytes.ptr) else "",
        @intCast(input_bytes.len),
    ) orelse {
        c.PyErr_Print();
        return error.PythonBytesError;
    };
    defer c.Py_DECREF(py_bytes);

    // Provide the bytes object in globals under both "data" and "input_bytes"
    if (c.PyDict_SetItemString(global_dict, "data", py_bytes) < 0) {
        c.PyErr_Print();
        return error.PythonDictSetError;
    }
    if (c.PyDict_SetItemString(global_dict, "input_bytes", py_bytes) < 0) {
        c.PyErr_Print();
        return error.PythonDictSetError;
    }

    // 3. Execute the Python code in the __main__ dictionary
    const run_result = c.PyRun_String(
        python_code_z.ptr,
        c.Py_file_input,
        global_dict,
        global_dict,
    );
    if (run_result == null) {
        c.PyErr_Print();
        return error.PythonExecutionError;
    }
    c.Py_DECREF(run_result);

    // 4. Find the return value
    var py_return_val: ?*c.PyObject = null;
    var is_borrowed = false;
    defer {
        if (!is_borrowed) {
            if (py_return_val) |val| c.Py_DECREF(val);
        }
    }

    if (explicit_func_name) |func_name| {
        const func = c.PyDict_GetItemString(global_dict, func_name.ptr);
        if (func == null or c.PyCallable_Check(func) == 0) {
            std.debug.print("Error: specified function '{s}' not found or not callable\n", .{func_name});
            return error.PythonFunctionNotFound;
        }
        py_return_val = c.PyObject_CallOneArg(func, py_bytes);
        is_borrowed = false;
    } else {
        // Try common function names in order: "process", "main", "run"
        const candidates = [_][:0]const u8{ "process", "main", "run" };
        var found_func: ?*c.PyObject = null;
        for (candidates) |name| {
            if (c.PyDict_GetItemString(global_dict, name.ptr)) |obj| {
                if (c.PyCallable_Check(obj) != 0) {
                    found_func = obj;
                    break;
                }
            }
        }

        if (found_func) |func| {
            py_return_val = c.PyObject_CallOneArg(func, py_bytes);
            is_borrowed = false;
        } else {
            // Check if global variable `result` or `ret` is set
            const var_candidates = [_][:0]const u8{ "result", "ret", "output" };
            for (var_candidates) |vname| {
                if (c.PyDict_GetItemString(global_dict, vname.ptr)) |val| {
                    py_return_val = val;
                    is_borrowed = true; // PyDict_GetItemString returns borrowed reference
                    break;
                }
            }
        }
    }

    if (py_return_val == null) {
        if (c.PyErr_Occurred() != null) {
            c.PyErr_Print();
            return error.PythonExecutionError;
        }
        std.debug.print("Error: No callable function (process/main/run) or 'result' variable found in Python program\n", .{});
        return error.PythonNoResultFound;
    }

    const res_obj = py_return_val.?;

    // 5. Convert Python return value to integer
    if (c.PyLong_Check(res_obj) != 0) {
        var overflow: c_int = 0;
        const num = c.PyLong_AsLongLongAndOverflow(res_obj, &overflow);
        if (overflow != 0) {
            return error.PythonIntegerOverflow;
        }
        return num;
    } else if (c.PyFloat_Check(res_obj) != 0) {
        const f = c.PyFloat_AsDouble(res_obj);
        return @intFromFloat(f);
    } else if (c.PyBool_Check(res_obj) != 0) {
        return if (c.Py_IsTrue(res_obj) != 0) 1 else 0;
    } else {
        const type_name = if (res_obj.*.ob_type.*.tp_name) |name|
            std.mem.span(name)
        else
            "unknown";
        std.debug.print("Error: Python returned non-numeric object of type: {s}\n", .{type_name});
        return error.PythonReturnTypeNotNumber;
    }
}

/// Helper to initialize Python runtime with appropriate home/path configuration.
fn initPython(arena: std.mem.Allocator, argv0: [:0]const u8) !void {
    var config: c.PyConfig = undefined;
    c.PyConfig_InitPythonConfig(&config);

    _ = c.PyConfig_SetBytesString(&config, &config.program_name, argv0.ptr);

    // If PYTHONHOME is not already set in the environment, try to locate it relative to the binary or cwd
    if (c.getenv("PYTHONHOME") == null) {
        const candidates = [_][]const u8{
            "zig-out",
            "../",
            ".",
        };

        // Also check relative to executable directory if argv0 contains a path
        if (std.fs.path.dirname(argv0)) |dir| {
            const exe_parent = std.fs.path.dirname(dir) orelse dir;
            const check_lib = try std.fmt.allocPrint(arena, "{s}/lib/python3.12", .{exe_parent});
            if (dirExists(arena, check_lib)) {
                const home_z = try arena.dupeZ(u8, exe_parent);
                _ = c.PyConfig_SetBytesString(&config, &config.home, home_z.ptr);
            }
        }

        if (config.home == null) {
            for (candidates) |cand| {
                const check_lib = try std.fmt.allocPrint(arena, "{s}/lib/python3.12", .{cand});
                if (dirExists(arena, check_lib)) {
                    const home_z = try arena.dupeZ(u8, cand);
                    _ = c.PyConfig_SetBytesString(&config, &config.home, home_z.ptr);
                    break;
                }
            }
        }
    }

    const status = c.Py_InitializeFromConfig(&config);
    c.PyConfig_Clear(&config);
    if (c.PyStatus_Exception(status) != 0) {
        return error.PythonInitFailed;
    }
}

fn dirExists(arena: std.mem.Allocator, path: []const u8) bool {
    const path_z = arena.dupeZ(u8, path) catch return false;
    return c.access(path_z.ptr, 0) == 0;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    const argv0 = if (all_args.len > 0)
        try arena.dupeZ(u8, all_args[0])
    else
        try arena.dupeZ(u8, "embed_python");

    try initPython(arena, argv0);
    defer _ = c.Py_FinalizeEx();

    var python_code_z: ?[:0]const u8 = null;
    var input_bytes: []const u8 = "Default Zig byte array payload: 42 100 200";
    var explicit_func_name: ?[:0]const u8 = null;

    var i: usize = 1;
    while (i < all_args.len) : (i += 1) {
        const arg = all_args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= all_args.len) {
                std.debug.print("Error: -c requires a code argument\n", .{});
                return error.InvalidArguments;
            }
            python_code_z = try arena.dupeZ(u8, all_args[i]);
        } else if (std.mem.eql(u8, arg, "--func") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= all_args.len) {
                std.debug.print("Error: --func requires a function name\n", .{});
                return error.InvalidArguments;
            }
            explicit_func_name = try arena.dupeZ(u8, all_args[i]);
        } else if (std.mem.eql(u8, arg, "--bytes") or std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i >= all_args.len) {
                std.debug.print("Error: --bytes requires a byte argument\n", .{});
                return error.InvalidArguments;
            }
            input_bytes = all_args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (python_code_z == null) {
            // First positional argument: could be a file path or code string
            const file_content = std.Io.Dir.cwd().readFileAlloc(io, arg, arena, .unlimited) catch null;
            if (file_content) |content| {
                python_code_z = try arena.dupeZ(u8, content);
            } else {
                python_code_z = try arena.dupeZ(u8, arg);
            }
        } else {
            // Second positional argument: input byte array
            input_bytes = arg;
        }
    }

    // Default demonstration if no python code was provided
    if (python_code_z == null) {
        std.debug.print("=== No Python script provided: running default demo ===\n", .{});
        printUsage();

        const demo_script =
            \\# Python demo script
            \\def process(data: bytes) -> int:
            \\    print(f"[Python] Received {len(data)} bytes: {data!r}")
            \\    # Calculate a checksum/sum of bytes as the returned number
            \\    total = sum(data)
            \\    print(f"[Python] Sum of byte values = {total}")
            \\    return total
        ;
        const demo_bytes = &[_]u8{ 10, 20, 30, 40, 50, 60, 70 };
        std.debug.print("\n[Zig] Passing byte array: {any} (len={d})\n", .{ demo_bytes, demo_bytes.len });

        const result = try runPythonWithBytes(demo_script, demo_bytes, null);
        std.debug.print("[Zig] Python returned number: {d}\n\n", .{result});
        return;
    }

    std.debug.print("[Zig] Passing {d} bytes to Python...\n", .{input_bytes.len});
    const result = try runPythonWithBytes(python_code_z.?, input_bytes, explicit_func_name);
    std.debug.print("[Zig] Python returned number: {d}\n", .{result});
}

fn printUsage() void {
    std.debug.print(
        \\Usage: embed_python [options] [SCRIPT_FILE | -c "CODE"] [BYTES]
        \\
        \\Options:
        \\  -c "CODE"         Inline Python code string
        \\  -b, --bytes DATA  Byte array payload (can also be passed as 2nd positional arg)
        \\  -f, --func NAME   Name of function to call (default: process, main, run, or 'result' var)
        \\  -h, --help        Show this help message
        \\
        \\Examples:
        \\  embed_python -c "def process(data: bytes): return sum(data)" "hello"
        \\  embed_python -c "result = len(data)" "test string"
        \\  embed_python my_script.py "input payload"
        \\
    , .{});
}
