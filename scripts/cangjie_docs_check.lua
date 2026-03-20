local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local text = fd:read("*a")
    fd:close()
    return text
end

local function script_args()
    local argv = {}
    for index = 1, #(_G.arg or {}) do
        local value = _G.arg[index]
        if value and value ~= "--" then
            table.insert(argv, value)
        end
    end
    return argv
end

local function parse_args(argv)
    local opts = {
        limit = nil,
        cases = nil,
        failures_only = false,
        json = false,
        index = nil,
    }

    local i = 1
    while i <= #argv do
        local arg = argv[i]
        if arg == "--limit" then
            i = i + 1
            opts.limit = tonumber(argv[i])
        elseif arg == "--cases" then
            i = i + 1
            opts.cases = argv[i]
        elseif arg == "--index" then
            i = i + 1
            opts.index = argv[i]
        elseif arg == "--failures-only" then
            opts.failures_only = true
        elseif arg == "--json" then
            opts.json = true
        elseif arg == "--help" or arg == "-h" then
            print([[
Usage:
  nvim --headless -u NONE -l scripts/cangjie_docs_check.lua [options]

Options:
  --index PATH          Override docs-index path
  --cases PATH          Compare custom cases from JSON
  --limit N             Limit synthetic cases
  --failures-only       Only print failed cases
  --json                Print full JSON report
]])
            vim.cmd("qa")
            return nil
        end
        i = i + 1
    end

    return opts
end

local function load_cases(path)
    local text = read_file(path)
    assert(text, "failed to read cases file: " .. path)
    local ok, decoded = pcall(vim.json.decode, text)
    assert(ok and type(decoded) == "table", "failed to decode cases JSON: " .. path)
    return decoded.cases or decoded
end

local function print_text_report(report)
    print(("total=%d passed=%d failed=%d"):format(report.total, report.passed, report.failed))
    for _, result in ipairs(report.results or {}) do
        if result.ok then
            print(("[OK] %s -> %s"):format(result.name or "?", result.actual or "nil"))
        else
            print(("[FAIL] %s"):format(result.name or "?"))
            print(("  expected: %s"):format(result.expected or "nil"))
            print(("  actual:   %s"):format(result.actual or "nil"))
            print(
                ("  parsed:   module=%s container=%s member=%s kind=%s"):format(
                    result.debug and result.debug.module_name or "nil",
                    result.debug and result.debug.container_name or "nil",
                    result.debug and result.debug.member_name or "nil",
                    result.debug and result.debug.member_kind or "nil"
                )
            )
            for _, line in ipairs(result.lines or {}) do
                print(("  hover:    %s"):format(line))
            end
        end
    end
end

local opts = parse_args(script_args())
if not opts then
    return
end

if opts.index and opts.index ~= "" then
    vim.g.cangjie_doc_index = opts.index
end

local docs = assert(dofile(vim.fn.stdpath("config") .. "/lua/cangjie_docs_index.lua"))
docs.reload()

local cases
if opts.cases then
    cases = load_cases(opts.cases)
else
    cases = docs.synthetic_hover_cases({
        limit = opts.limit,
    })
end

local report = docs.compare_hover_cases(cases, {
    failures_only = opts.failures_only,
})

if opts.json then
    print(vim.json.encode(report))
else
    print_text_report(report)
end

vim.cmd("qa")
