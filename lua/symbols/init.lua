local cfg = require("symbols.config")
local utils = require("symbols.utils")
local log = require("symbols.log")

local nvim = require("symbols.nvim")

local _symbol = require("symbols.symbol")
local Symbol_root = _symbol.Symbol_root
local Symbol_path = _symbol.Symbol_path
local Pos_from_point = _symbol.Pos_from_point

local providers = require("symbols.providers")

local M = {}

---@type table<string, boolean>
local cmds = {}

---@param name string
---@param cmd fun(t: table)
---@param opts table
local function create_user_command(name, cmd, opts)
    cmds[name] = true
    vim.api.nvim_create_user_command(name, cmd, opts)
end

local function remove_user_commands()
    local keys = vim.tbl_keys(cmds)
    for _, cmd in ipairs(keys) do
        vim.api.nvim_del_user_command(cmd)
        cmds[cmd] = nil
    end
end

local global_autocmd_group = vim.api.nvim_create_augroup("Symbols", { clear = true })

---@type table<integer, integer>
local _prev_flash_highlight_ns = {}

local function _clear_flash_highlights(buf, ns)
    if _prev_flash_highlight_ns[buf] == ns then
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
        _prev_flash_highlight_ns[buf] = nil
    end
end

---@param win integer
---@param duration_ms integer
local function flash_highlight_under_cursor(win, duration_ms, lines)
    local buf = vim.api.nvim_win_get_buf(win)

    local prev_ns = _prev_flash_highlight_ns[buf]
    if prev_ns ~= nil then _clear_flash_highlights(buf, prev_ns) end

    local ns = vim.api.nvim_create_namespace("")
    _prev_flash_highlight_ns[buf] = ns
    local line = vim.api.nvim_win_get_cursor(win)[1]
    for i = 1, lines do
        vim.api.nvim_buf_add_highlight(
            buf, ns, "Visual", line - 1 + i - 1, 0, -1
        )
    end
    vim.defer_fn(
        function() _clear_flash_highlights(buf, ns) end,
        duration_ms
    )
end

local SIDEBAR_EXT_NS = vim.api.nvim_create_namespace("SymbolsSidebarExt")

---@alias RefreshSymbolsFun fun(symbols: Symbol, provider_name: string, provider_config: table)
---@alias KindToHlGroupFun fun(kind: string): string
---@alias KindToDisplayFun fun(kind: string): string

---@class Preview
---@field sidebar Sidebar
---@field win integer
---@field locked boolean
---@field auto_show boolean
---@field keymaps_to_remove string[]
local Preview = {}
Preview.__index = Preview

---@return Preview
function Preview:new()
    return setmetatable({
        sidebar = nil,
        win = -1,
        locked = false,
        auto_show = cfg.default.sidebar.preview.show_always,
        keymaps_to_remove = {},
    }, self)
end

local sidebar_source_win_buf
local sidebar_close
local sidebar_current_symbol
local sidebar_current_symbols

function Preview:close()
    if vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
    end
    self.locked = false
    self.win = -1
    local source_buf = sidebar_source_win_buf(self.sidebar)
    for _, key in ipairs(self.keymaps_to_remove) do
        vim.keymap.del("n", key, { buffer = source_buf })
    end
    self.keymaps_to_remove = {}
end

function Preview:goto_symbol()
    local cursor = vim.api.nvim_win_get_cursor(self.win)
    vim.api.nvim_win_set_cursor(self.sidebar.source_win, cursor)
    vim.api.nvim_set_current_win(self.sidebar.source_win)
    vim.fn.win_execute(self.sidebar.source_win, "normal! zz")
    if self.sidebar.close_on_goto then
        sidebar_close(self.sidebar)
    end
end

---@type table<PreviewAction, fun(preview: Preview)>
local preview_actions = {
    ["close"] = Preview.close,
    ["goto-code"] = Preview.goto_symbol,
}
utils.assert_keys_are_enum(preview_actions, cfg.PreviewAction, "preview_actions")

function Preview:open()
    if vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_set_current_win(self.win)
        return
    end

    local config = self.sidebar.preview_config
    local source_buf = sidebar_source_win_buf(self.sidebar)
    local symbol = sidebar_current_symbol(self.sidebar)
    local range = symbol.range
    local selection_range = symbol.selectionRange
    local cursor = vim.api.nvim_win_get_cursor(self.sidebar.win)
    cursor[1] = cursor[1] - vim.fn.line("w0", self.sidebar.win) + 1

    local height = config.fixed_size_height
    if config.auto_size then
        height = config.auto_size_extra_lines + (range["end"].line - range.start.line) + 1
        height = math.max(config.min_window_height, height)
        height = math.min(config.max_window_height, height)
    end
    local max_height = vim.api.nvim_win_get_height(self.sidebar.source_win) - 3
    height = math.min(max_height, height)

    local max_width = vim.api.nvim_win_get_width(self.sidebar.source_win) - 2
    local width = config.window_width
    width = math.min(max_width, width)

    local opts = {
        height = height,
        width = width,
        border = "single",
        style = "minimal",
        zindex = 45, -- to allow other floating windows (like symbol peek) in front
    }
    if self.sidebar.win_dir == "right" then
        opts.relative = "win"
        opts.win = self.sidebar.win
        opts.anchor = "NE"
        opts.row = cursor[1] - 1
        opts.col = -1
    else
        opts.relative = "win"
        opts.win = self.sidebar.source_win
        opts.anchor = "NW"
        opts.row = cursor[1] - 1
        opts.col = 0
    end

    self.win = vim.api.nvim_open_win(source_buf, false, opts)
    if config.show_line_number then
        vim.wo[self.win].number = true
    end
    vim.api.nvim_win_set_cursor(
        self.win,
        { selection_range.start.line+1, selection_range.start.character }
    )
    vim.fn.win_execute(self.win, "normal! zt")
    vim.api.nvim_set_option_value("cursorline", true, { win = self.win })

    for keymap, action in pairs(config.keymaps) do
        local fn = function() preview_actions[action](self) end
        vim.keymap.set("n", keymap, fn, { buffer = source_buf })
        table.insert(self.keymaps_to_remove, keymap)
    end
end

function Preview:toggle_auto_show()
    if self.auto_show then self:close() else self:open() end
    self.auto_show = not self.auto_show
end

function Preview:on_cursor_move()
    -- After creating the preview the CursorMoved event is triggered once.
    -- We ignore it here.
    if self.locked then
        self.locked = false
    else
        self:close()
        if self.auto_show then self:open() end
    end
end

function Preview:on_win_enter()
    if (
        vim.api.nvim_win_is_valid(self.win) and
        vim.api.nvim_get_current_win() ~= self.win
    ) then
        self:close()
    end
end

---@param win integer
function Preview:on_win_close(win)
    if win == self.win then
        self:close()
    end
end

---@class DetailsWin
---@field sidebar Sidebar
---@field auto_show boolean
---@field win integer
---@field locked boolean
---@field prev_cursor [integer, integer] | nil
---@field show_debug_info boolean
local DetailsWin = {}
DetailsWin.__index = DetailsWin

---@return DetailsWin
function DetailsWin:new()
    return setmetatable({
        sidebar = nil,
        auto_show = false,
        win = -1,
        locked = false,
        prev_cursor = nil,
        show_debug_info = false
    }, self)
end

function DetailsWin:open()
    if vim.api.nvim_win_is_valid(self.win) then return end

    local sidebar_win = self.sidebar.win
    local symbols = sidebar_current_symbols(self.sidebar)
    local symbol, symbol_state = sidebar_current_symbol(self.sidebar)

    local details_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "delete", { buf = details_buf })

    local text = {}

    if self.show_debug_info then
        ---@param range Range
        ---@return string
        local function range_string(range)
            return (
                "("
                .. "(" .. range.start.line .. ", " .. range.start.character .. "), "
                .. "(" .. range["end"].line .. ", " .. range["end"].character .. ")"
                .. ")"
            )
        end
        -- debug info
        table.insert(text, " [SYMBOL DEBUG INFO]")
        table.insert(text, "   name: " .. symbol.name)
        table.insert(text, "   kind: " .. (symbol.kind or ""))
        table.insert(text, "   level: " .. tostring(symbol.level))
        table.insert(text, "   range: " .. range_string(symbol.range))
        table.insert(text, "   selectionRange: " .. range_string(symbol.selectionRange))
        table.insert(text, "   folded: " .. tostring(symbol_state.folded))
        table.insert(text, "   visible: " .. tostring(symbol_state.visible))
        table.insert(text, "")
    end

    local ft = vim.api.nvim_get_option_value("ft", { buf = sidebar_source_win_buf(self.sidebar) })
    local kinds_cfg = cfg.get_config_by_filetype(symbols.provider_config.kinds, ft)
    local highlights_cfg = cfg.get_config_by_filetype(symbols.provider_config.highlights, ft)

    ---@type Highlight[]
    local highlights = {}

    local display_kind = cfg.kind_for_symbol(kinds_cfg, symbol)
    if display_kind ~= "" then
        local highlight = nvim.Highlight:new({
            group = highlights_cfg[symbol.kind],
            line = #text + 1,
            col_start = 1,
            col_end = 1 + #display_kind,
        })
        table.insert(highlights, highlight)
        display_kind = display_kind .. " "
    end
    table.insert(text, " " .. display_kind .. table.concat(Symbol_path(symbol), "."))

    if symbol.detail ~= "" then
        local detail_first_line = #text + 1
        for detail_line, line in ipairs(vim.split(symbol.detail, "\n")) do
            table.insert(text, "   " .. line)
            table.insert(highlights, nvim.Highlight:new({
                group = "Comment",
                line = detail_first_line + detail_line - 1,
                col_start = 0,
                col_end = 3 + #line,
            }))
        end
    end

    local longest_line = 0
    for _, line in ipairs(text) do
        longest_line = math.max(longest_line, #line)
    end

    nvim.buf_set_content(details_buf, text)

    for _, highlight in ipairs(highlights) do
        highlight:apply(details_buf)
    end

    local line_count = vim.api.nvim_buf_line_count(details_buf)

    local sidebar_width = vim.api.nvim_win_get_width(sidebar_win)
    local width = math.max(sidebar_width - 2, longest_line + 1)
    local height = line_count

    local cursor = vim.api.nvim_win_get_cursor(sidebar_win)
    cursor[1] = cursor[1] - vim.fn.line("w0", sidebar_win) + 1

    local row = cursor[1] - 3 - height
    if row < 0 then row = cursor[1] end

    local col = 0
    if self.sidebar.win_dir == "right" and width + 2 > sidebar_width then
        col = col - (width + 2 - sidebar_width)
    end

    local opts = {
        relative = "win",
        win = self.sidebar.win,
        anchor = "NW",
        row = row,
        col = col,
        width = width,
        height = height,
        border = "single",
        style = "minimal",
    }
    self.win = vim.api.nvim_open_win(details_buf, false, opts)
end

function DetailsWin:on_cursor_move()
    if self.locked then
        if self.prev_cursor ~= nil then
            vim.api.nvim_win_set_cursor(self.sidebar.win, self.prev_cursor)
            self.prev_cursor = nil
        end
        self.locked = false
    else
        if vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_close(self.win, true)
            self.win = -1
        end
        if self.auto_show then
            self:open()
        end
    end
end

function DetailsWin:close()
    if vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
    end
    self.win = -1
    self.locked = false
end

function DetailsWin:toggle_auto_show()
    if self.auto_show then self:close() else self:open() end
    self.auto_show = not self.auto_show
end

function DetailsWin:on_win_enter()
    if vim.api.nvim_win_is_valid(self.win) then
        local curr_win = vim.api.nvim_get_current_win()
        if curr_win == self.sidebar.win then
            if self.auto_show then
                self:open()
            end
        else
            self:close()
        end
    end
end

---@class CursorState
---@field hide boolean
---@field hidden boolean
---@field original string

---@class GlobalSettings
---@field open_direction OpenDirection
---@field on_open_make_windows_equal boolean

---@class GlobalState
---@field cursor CursorState
---@field settings GlobalSettings

---@return GlobalState
local function GlobalState_new()
    ---@type GlobalState
    local obj = {
        cursor = {
            hide = false,
            hidden = false,
            original = vim.o.guicursor,
        },
        settings = {
            open_direction = cfg.default.sidebar.open_direction,
            on_open_make_windows_equal = cfg.default.sidebar.on_open_make_windows_equal,
        },
    }
    return obj
end

---@class SymbolState
---@field folded boolean
---@field visible boolean
---@field visible_children integer

---@return SymbolState
local function SymbolState_new()
    return {
        folded = true,
        visible = true,
        visible_children = 0,
    }
end

---@alias SymbolStates table<Symbol, SymbolState>

---@param root Symbol
---@return Symbols
local function SymbolStates_build(root)
    local states = {}

    local function traverse(symbol)
        states[symbol] = SymbolState_new()
        for _, child in ipairs(symbol.children) do
            traverse(child)
        end
    end

    traverse(root)
    return states
end

---@alias SymbolFilter fun(ft: string, symbol: Symbol): boolean

---@class Symbols
---@field provider string
---@field provider_config table
---@field buf integer
---@field root Symbol
---@field states SymbolStates
---@field any_nesting boolean

---@return Symbols
local function Symbols_new()
    local root = Symbol_root()
    local symbols = {
        provider = "",
        buf = -1,
        root = root,
        states = {
            [root] = SymbolState_new()
        },
        any_nesting = false,
    }
    symbols.states[root].folded = false
    return symbols
end

---@param symbols Symbols
---@param symbol_filter SymbolFilter
local function Symbols_apply_filter(symbols, symbol_filter)
    local ft = vim.api.nvim_get_option_value("filetype", { buf = symbols.buf })
    symbols.any_nesting = false

    ---@param symbol Symbol
    local function apply(symbol)
        local state = symbols.states[symbol]
        if symbol.level == 0 then
            state.visible = true
        else
            state.visible = symbol_filter(ft, symbol)
        end
        state.visible_children = 0
        for _, child in ipairs(symbol.children) do
            apply(child)
            if symbols.states[child].visible then
                state.visible_children = state.visible_children + 1
            end
        end

        if state.visible_children > 0 and symbol.level == 1 then
            symbols.any_nesting = true
        end

    end

    apply(symbols.root)
end

---@class SymbolsCacheEntry
---@field root Symbol
---@field fresh boolean
---@field update_in_progress boolean
---@field post_update_callbacks RefreshSymbolsFun[]
---@field updated osdate
---@field provider_name string

---@return SymbolsCacheEntry
local function SymbolsCacheEntry_new()
    return {
        root = Symbol_root(),
        fresh = false,
        update_in_progress = false,
        post_update_callbacks = {},
        updated = nil,
        provider_name = ""
    }
end

---@alias SymbolsCache table<integer, SymbolsCacheEntry>

---@return SymbolsCache
local function SymbolsCache_new()
    return vim.defaulttable(SymbolsCacheEntry_new)
end

---@class SymbolsRetriever
---@field providers [string, any][] type(Provider)[]
---@field providers_config ProvidersConfig
---@field cache SymbolsCache

---@param providers Provider[]
---@param providers_config ProvidersConfig
---@return SymbolsRetriever
local function SymbolsRetriever_new(providers, providers_config)
    return {
        providers = providers,
        providers_config = providers_config,
        cache = SymbolsCache_new()
    }
end

---@param retriever SymbolsRetriever
---@param buf integer
---@param on_retrieve fun(symbol: Symbol, provider_name: string, provider_config: table)
---@param on_fail fun(provider_name: string)
---@param on_timeout fun(provider_name: string)
---@return boolean
local function SymbolsRetriever_retrieve(retriever, buf, on_retrieve, on_fail, on_timeout)
    local function cleanup_on_fail()
        local entry = retriever.cache[buf]
        entry.update_in_progress = false
        entry.post_update_callbacks = {}
    end

    ---@param provider_name string
    local function _on_fail(provider_name)
        return function()
            cleanup_on_fail()
            log.warn(provider_name .. " failed")
            on_fail(provider_name)
        end
    end

    ---@param provider_name string
    local function _on_timeout(provider_name)
        return function()
            cleanup_on_fail()
            log.warn(provider_name .. " timed out")
            on_timeout(provider_name)
        end
    end

    ---@param provider_name string
    ---@param cached boolean
    ---@return fun(root: Symbol)
    local _on_retrieve = function(provider_name, cached)
        ---@param root Symbol
        return function(root)
            local entry = retriever.cache[buf]
            entry.root = root
            entry.fresh = true
            if not cached then
                local date = os.date("*t")
                assert(type(date) ~= "string")
                entry.updated = date
            end
            entry.provider_name = provider_name

            for _, callback in ipairs(entry.post_update_callbacks) do
                callback(root, provider_name, retriever.providers_config[provider_name])
            end

            entry.update_in_progress = false
            entry.post_update_callbacks = {}
        end
    end

    local entry = retriever.cache[buf]

    if entry.fresh then
        log.trace("entry fresh, running _on_retrieve and quiting")
        table.insert(entry.post_update_callbacks, on_retrieve)
        _on_retrieve(entry.provider_name, true)(entry.root)
        return true
    end

    if entry.update_in_progress then
        log.trace("update in progress, adding callback and quiting")
        -- TODO: do not add multiple callbacks for the same sidebar
        table.insert(entry.post_update_callbacks, on_retrieve)
        return true
    end

    log.trace("attempting to retrieve symbols")
    for _, _provider in ipairs(retriever.providers) do
        local provider_name = _provider[1]
        local config = retriever.providers_config[provider_name]
        ---@type Provider
        local provider = _provider[2]:new(config)
        if provider:supports(buf) then
            log.trace("using provider: " .. provider_name)
            table.insert(entry.post_update_callbacks, on_retrieve)
            entry.update_in_progress = true
            if provider.async_get_symbols ~= nil then
                provider:async_get_symbols(
                    buf,
                    _on_retrieve(provider_name, false),
                    _on_fail(provider_name),
                    _on_timeout(provider_name)
                )
            else
                local ok, symbol = provider:get_symbols(buf)
                if not ok then
                    _on_fail(provider_name)()
                else
                    assert(symbol ~= nil)
                    _on_retrieve(provider_name, false)(symbol)
                end
            end
            return true
        end
    end
    return false
end

---@class WinSettings
---@field number boolean | nil
---@field relativenumber boolean | nil
---@field signcolumn string | nil
---@field cursorline boolean | nil
---@field winfixwidth boolean | nil
---@field wrap boolean | nil

---@return WinSettings
local function WinSettings_new()
    return {
        number = nil,
        relativenumber = nil,
        signcolumn = nil,
        cursorline = nil,
        winfixwidth = nil,
        wrap = nil,
    }
end

---@param win integer
---@return WinSettings
local function WinSettings_get(win)
    ---@param opt string
    local function get_opt(opt)
        return vim.api.nvim_get_option_value(opt, { win = win })
    end
    ---@type WinSettings
    local settings = {
        number = get_opt("number"),
        relativenumber = get_opt("relativenumber"),
        signcolumn = get_opt("signcolumn"),
        cursorline = get_opt("cursorline"),
        winfixwidth = get_opt("winfixwidth"),
        wrap = get_opt("wrap")
    }
    return settings
end

---@param win integer
---@param settings WinSettings
local function WinSettings_apply(win, settings)
    ---@param name string
    ---@param value any
    local function set_opt(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win })
    end
    for opt_name, opt_value in pairs(settings) do
        if opt_value ~= nil then
            set_opt(opt_name, opt_value)
        end
    end
end

---@param cursor CursorState
local function activate_cursorline(cursor)
    if not cursor.hidden then
        local cur = vim.o.guicursor:match("n.-:(.-)[-,]")
        vim.opt.guicursor:append("n:" .. cur .. "-Cursorline")
        cursor.hidden = true
    end
end

---@param sidebar Sidebar
local function hide_cursor(sidebar)
    local pos = vim.api.nvim_win_get_cursor(sidebar.win)
    local any_nesting = sidebar_current_symbols(sidebar).any_nesting
    local col = (any_nesting and 1) or 0
    if col ~= pos[2] then
        vim.api.nvim_win_set_cursor(sidebar.win, { pos[1], col })
    end
end

---@param cursor CursorState
local function reset_cursor(cursor)
    vim.o.guicursor = cursor.original
    cursor.hidden = false
end

local sidebar_change_view

---@class (exact) SearchView
---@field sidebar Sidebar
---@field buf integer
---@field prompt_buf integer
---@field prompt_win integer
---@field search_results SearchSymbol[]
---@field flat_symbols Symbol[]
---@field history string[]
---@field history_idx integer
local SearchView = {}
---@diagnostic disable-next-line
SearchView.__index = SearchView

---@return SearchView
function SearchView:new()
    return setmetatable({
        sidebar = nil,
        buf = -1,
        prompt_buf = -1,
        prompt_win = -1,
        search_results = {},
        flat_symbols = {},
        history = {},
        history_idx = -1
    }, self)
end

function SearchView:init(sidebar)
    self.sidebar = sidebar
    self:init_buf()
    self:init_prompt_buf()
end

function SearchView:init_buf()
    if vim.api.nvim_buf_is_valid(self.buf) then return end

    self.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(self.buf, "symbols.nvim [" .. tostring(self.sidebar.num) .. "]" .. " (search)")
    nvim.buf_set_modifiable(self.buf, false)

    vim.api.nvim_create_autocmd(
        { "WinResized" },
        {
            group = global_autocmd_group,
            callback = function()
                if self.prompt_win == -1 then return end
                local win = self.sidebar.win
                local win_h = vim.api.nvim_win_get_height(win)
                local win_w = vim.api.nvim_win_get_width(win)
                local opts = {
                    relative = "win",
                    win = self.sidebar.win,
                    height = 1,
                    width = win_w - 1,
                    row = win_h - 2,
                    col = 0,
                }
                vim.api.nvim_win_set_config(self.prompt_win, opts)
            end,
        }
    )

    vim.keymap.set(
        "n", "q",
        function() sidebar_close(self.sidebar) end,
        { buffer = self.buf }
    )
    vim.keymap.set(
        "n", "o",
        function()
            self:save_history()
            self:jump_to_current_symbol()
            vim.api.nvim_set_current_win(self.sidebar.win)
        end,
        { buffer = self.buf }
    )
end

function SearchView:init_prompt_buf()
    if vim.api.nvim_buf_is_valid(self.prompt_buf) then return end
    self.prompt_buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_create_autocmd(
        { "TextChangedI" },
        {
            group = global_autocmd_group,
            buffer = self.prompt_buf,
            callback = function() self:search() end,
        }
    )
    --- TODO remove this autocommand when no longer needed
    vim.api.nvim_create_autocmd(
        { "WinEnter" },
        {
            group = global_autocmd_group,
            callback = function()
                local win = vim.api.nvim_get_current_win()
                if win == self.prompt_win then
                    vim.cmd("startinsert!")
                end
            end
        }
    )
    vim.api.nvim_create_autocmd(
        { "WinLeave" },
        {
            group = global_autocmd_group,
            callback = function()
                local win = vim.api.nvim_get_current_win()
                if win == self.prompt_win then
                    vim.cmd("stopinsert")
                end
            end
        }
    )
    vim.api.nvim_create_autocmd(
        { "BufHidden" },
        {
            group = global_autocmd_group,
            buffer = self.prompt_buf,
            callback = function() self:hide() end
        }
    )

    vim.keymap.set(
        "i", "<Esc>",
        function()
            vim.api.nvim_set_current_win(self.sidebar.win)
        end,
        { buffer = self.prompt_buf }
    )
    vim.keymap.set(
        "i", "<S-Tab>",
        function()
            local cursor = vim.api.nvim_win_get_cursor(self.sidebar.win)
            local new_cursor = { cursor[1] - 1, 0 }
            if new_cursor[1] == 0 then
                local lines = vim.api.nvim_buf_line_count(self.buf)
                new_cursor[1] = lines
            end
            vim.api.nvim_win_set_cursor(self.sidebar.win, new_cursor)
        end,
        { buffer = self.prompt_buf }
    )
    vim.keymap.set(
        "i", "<Tab>",
        function()
            local cursor = vim.api.nvim_win_get_cursor(self.sidebar.win)
            local new_cursor = { cursor[1] + 1, 0 }
            local lines = vim.api.nvim_buf_line_count(self.buf)
            if new_cursor[1] > lines then new_cursor[1] = 1 end
            vim.api.nvim_win_set_cursor(self.sidebar.win, new_cursor)
        end,
        { buffer = self.prompt_buf }
    )
    vim.keymap.set(
        "i", "<Cr>",
        function()
            self:save_history()
            self:jump_to_current_symbol()
            if self.sidebar.close_on_goto then
                sidebar_close(self.sidebar)
            else
                sidebar_change_view(self.sidebar, "symbols")
            end
        end,
        { buffer = self.prompt_buf }
    )
    vim.keymap.set(
        "i", "<C-j>",
        function()
            local text = self:next_item_from_history()
            self:set_prompt_buf(text)
            vim.print(self.history_idx)
        end,
        { buffer = self.prompt_buf }
    )
    vim.keymap.set(
        "i", "<C-k>",
        function()
            local text = self:prev_item_from_history()
            self:set_prompt_buf(text)
            vim.print(self.history_idx)
        end,
        { buffer = self.prompt_buf }
    )
end

---@param value string
function SearchView:set_prompt_buf(value)
    value = " " .. value
    vim.api.nvim_buf_set_lines(self.prompt_buf, 0, -1, false, { value })
    if vim.api.nvim_win_is_valid(self.prompt_win) then
        vim.api.nvim_win_set_cursor(self.prompt_win, { 1, #value })
    end
end

function SearchView:clear_prompt_buf()
    self:set_prompt_buf("")
    self.history_idx = -1
end

function SearchView:show_prompt_win()
    self:clear_prompt_buf()

    local win = self.sidebar.win
    local win_h = vim.api.nvim_win_get_height(win)
    local win_w = vim.api.nvim_win_get_width(win)
    local opts = {
        height = 1,
        width = win_w - 1,
        border = { "", "", "", "", "", "", "", ">" },
        style = "minimal",
        relative = "win",
        win = win,
        anchor = "NW",
        row = win_h - 2,
        col = 0,
    }
    self.prompt_win = vim.api.nvim_open_win(self.prompt_buf, false, opts)
end

---@return string
function SearchView:get_prompt_text()
    local text = vim.api.nvim_buf_get_lines(self.prompt_buf, 0, 1, false)[1]
    return vim.trim(text)
end

function SearchView:save_history()
    local text = self:get_prompt_text()
    if self.history[#self.history] ~= text then
        table.insert(self.history, text)
    end
end

---@return string
function SearchView:prev_item_from_history()
    assert(self.history_idx < #self.history, "SearchView.history_idx too large")
    if #self.history == 0 then return "" end
    if self.history_idx + 1 == #self.history then
        return self.history[1]
    end
    self.history_idx = self.history_idx + 1
    return self.history[#self.history - self.history_idx]
end

---@return string
function SearchView:next_item_from_history()
    if self.history_idx <= 0 then
        self.history_idx = -1
        return ""
    end
    self.history_idx = self.history_idx - 1
    return self.history[#self.history - self.history_idx]
end

---@class (exact) SearchSymbol
---@field s string
---@field i integer

---@return SearchSymbol[], Symbol[]
local function _prepare_symbols_for_search(symbols, ft)
    local search_symbols = {}
    local flat_symbols = {}
    local kinds = cfg.get_config_by_filetype(symbols.provider_config.kinds, ft)
    local function _prepare(symbol)
        if not symbols.states[symbol].visible then return end
        if symbol.level > 0 then
            local kind = cfg.kind_for_symbol(kinds, symbol)
            local search_str = " " .. kind .. " " .. symbol.name
            ---@type SearchSymbol
            local search_symbol = { s = search_str, i = #flat_symbols+1 }
            table.insert(search_symbols, search_symbol)
            table.insert(flat_symbols, symbol)
        end
        for _, child in ipairs(symbol.children) do
            _prepare(child)
        end
    end
    _prepare(symbols.root)
    return search_symbols, flat_symbols
end

---@param symbols SearchSymbol[]
---@return string[]
local function _search_symbols_to_lines(symbols)
    local buf_lines = {}
    for _, symbol in ipairs(symbols) do
        table.insert(buf_lines, symbol.s)
    end
    return buf_lines
end

---@param search_symbols SearchSymbol[]
---@param flat_symbols Symbol[]
---@return Highlight[]
function SearchView:_search_symbols_highlights(search_symbols, flat_symbols)
    local highlights = {} ---@type Highlight[]
    local symbols = sidebar_current_symbols(self.sidebar)
    local ft = vim.api.nvim_get_option_value("filetype", { buf = symbols.buf })
    local highlights_config = cfg.get_config_by_filetype(symbols.provider_config.highlights, ft)
    local kinds_display_config = cfg.get_config_by_filetype(symbols.provider_config.kinds, ft)
    local kinds_default_config = symbols.provider_config.kinds.default
    for line_nr, search_symbol in ipairs(search_symbols) do
        local symbol = flat_symbols[search_symbol.i]
        local kind_display = cfg.kind_for_symbol(kinds_display_config, symbol, kinds_default_config)
        local highlight = nvim.Highlight:new({
            group = highlights_config[symbol.kind],
            line = line_nr,
            col_start = 1,
            col_end = #kind_display + 1,
        })
        table.insert(highlights, highlight)
    end
    return highlights
end

function SearchView:search()
    local text = self:get_prompt_text()
    local symbols = sidebar_current_symbols(self.sidebar)
    local source_buf = sidebar_source_win_buf(self.sidebar)
    local ft = vim.api.nvim_get_option_value("filetype", { buf = source_buf })
    local search_symbols
    search_symbols, self.flat_symbols = _prepare_symbols_for_search(symbols, ft)
    local buf_lines = {}
    local highlights = {}
    if #text == 0 then
        buf_lines = _search_symbols_to_lines(search_symbols)
        highlights = self:_search_symbols_highlights(search_symbols, self.flat_symbols)
    else
        self.search_results = vim.fn.matchfuzzy(search_symbols, text, { key = "s" })
        buf_lines = _search_symbols_to_lines(self.search_results)
        highlights = self:_search_symbols_highlights(self.search_results, self.flat_symbols)
    end
    if #buf_lines == 0 then table.insert(buf_lines, "") end
    nvim.buf_set_content(self.buf, buf_lines)
    for _, highlight in ipairs(highlights) do highlight:apply(self.buf) end
    vim.api.nvim_win_set_cursor(self.sidebar.win, { 1, 0 })
end

function SearchView:hide()
    if vim.api.nvim_win_is_valid(self.prompt_win) then
        vim.cmd("stopinsert")
        vim.api.nvim_win_close(self.prompt_win, true)
        self.prompt_win = -1
    end
end

function SearchView:jump_to_current_symbol()
    local cursor = vim.api.nvim_win_get_cursor(self.sidebar.win)
    local search_symbol = self.search_results[cursor[1]]
    local symbol = self.flat_symbols[search_symbol.i]
    vim.api.nvim_win_set_cursor(
        self.sidebar.source_win,
        { symbol.range.start.line + 1, symbol.range.start.character }
    )
    vim.api.nvim_set_current_win(self.sidebar.source_win)
    vim.fn.win_execute(self.sidebar.source_win, "normal! zz")
    flash_highlight_under_cursor(self.sidebar.source_win, 400, 1)
end

function SearchView:show_prompt()
    self:show_prompt_win()

    vim.keymap.set(
        "n", "s",
        function()
            vim.api.nvim_set_current_win(self.prompt_win)
        end,
        { buffer = self.buf }
    )
    vim.keymap.set(
        "n", "<Esc>",
        function()
            sidebar_change_view(self.sidebar, "symbols")
        end,
        { buffer = self.buf }
    )
    vim.keymap.set(
        "n", "<Cr>",
        function()
            self:save_history()
            self:jump_to_current_symbol()
            if self.sidebar.close_on_goto then
                sidebar_close(self.sidebar)
            else
                sidebar_change_view(self.sidebar, "symbols")
            end
        end,
        { buffer = self.buf }
    )

    vim.api.nvim_set_current_win(self.prompt_win)
    vim.cmd("startinsert!")
end

function SearchView:show()
    vim.api.nvim_win_set_buf(self.sidebar.win, self.buf)
    self:show_prompt()
end

function SearchView:destroy()
    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
        self.buf = -1
    end
    if vim.api.nvim_buf_is_valid(self.prompt_buf) then
        vim.api.nvim_buf_delete(self.prompt_buf, { force = true })
        self.prompt_buf = -1
    end
end

---@alias SidebarView "symbols" | "search"

---@class Sidebar
---@field num integer Ordering number, used for naming buffers.
---@field gs GlobalState
---@field deleted boolean
---@field win integer
---@field win_dir "left" | "right"
---@field win_settings WinSettings
---@field current_view SidebarView
---@field search_view SearchView
---@field buf integer
---@field source_win integer
---@field visible boolean
---@field symbols_retriever SymbolsRetriever
---@field buf_symbols table<integer, Symbols>
---@field lines table<Symbol, integer>
---@field symbol_display_config table<string, SymbolDisplayConfig>
---@field preview_config PreviewConfig
---@field preview Preview
---@field details DetailsWin
---@field char_config CharConfig
---@field show_inline_details boolean
---@field show_guide_lines boolean
---@field wrap boolean
---@field auto_resize AutoResizeConfig
---@field fixed_width integer
---@field keymaps KeymapsConfig
---@field symbol_filters_enabled boolean
---@field symbol_filter SymbolFilter
---@field cursor_follow boolean
---@field auto_peek boolean
---@field close_on_goto boolean

---@return Sidebar
local function sidebar_new_obj()
    local config = cfg.default.sidebar
    local sidebar = {
        gs = GlobalState_new(),
        deleted = false,
        win = -1,
        win_dir = "right",
        win_settings = WinSettings_new(),
        current_view = "symbols",
        search_view = SearchView:new(),
        buf = -1,
        source_win = -1,
        visible = false,
        symbols_cache = SymbolsCache_new(),
        buf_symbols = vim.defaulttable(Symbols_new),
        lines = {},
        symbol_display_config = {},
        preview = Preview:new(),
        details = DetailsWin:new(),
        char_config = config.chars,
        show_inline_details = false,
        show_guide_lines = false,
        wrap = false,
        auto_resize = vim.deepcopy(config.auto_resize, true),
        fixed_width = config.fixed_width,
        keymaps = config.keymaps,
        symbol_state = {},
        symbol_filters_enabled = true,
        symbol_filter = config.symbol_filter,
        cursor_follow = config.cursor_follow,
        auto_peek = config.auto_peek,
    }
    return sidebar
end

---@param sidebar Sidebar
local function sidebar_visible(sidebar)
    return sidebar.win ~= -1
end

---@param sidebar Sidebar
---@return integer
sidebar_source_win_buf = function(sidebar)
    if vim.api.nvim_win_is_valid(sidebar.source_win) then
        return vim.api.nvim_win_get_buf(sidebar.source_win)
    end
    return -1
end

local sidebar_refresh_view

---@param sidebar Sidebar
---@param new_view SidebarView
sidebar_change_view = function(sidebar, new_view)
    if sidebar.current_view == "symbols" then
    elseif sidebar.current_view == "search" then
        sidebar.search_view:hide()
    else
        assert(false, "Unknown view: " .. tostring(sidebar.current_view))
    end

    if new_view == "symbols" then
        vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)
        sidebar_refresh_view(sidebar)
    elseif new_view == "search" then
        sidebar.search_view:show()
    else
        assert(false, "Unknown view: " .. tostring(new_view))
    end

    sidebar.current_view = new_view
end

---@param root Symbol
---@param pos Pos
---@return Symbol
local function symbol_at_pos(root, pos)

    ---@param range Range
    ---@param _pos Pos
    ---@return boolean
    local function in_range_line(range, _pos)
        return range.start.line <= _pos.line and _pos.line <= range["end"].line
    end

    ---@param range Range
    ---@param _pos Pos
    ---@return boolean
    local function in_range_character(range, _pos)
        return range.start.character <= _pos.character and _pos.character <= range["end"].character
    end

    ---@param range Range
    ---@param _pos Pos
    ---@return boolean
    local function range_before_pos(range, _pos)
        return (
            range["end"].line < _pos.line
            or (
                range["end"].line == _pos.line
                and range["end"].character < _pos.line
            )
        )
    end

    local current = root
    local partial_match = true
    while #current.children > 0 and partial_match do
        partial_match = false
        local prev = current
        for _, symbol in ipairs(current.children) do
            if range_before_pos(symbol.range, pos) then
                prev = symbol
            end
            if not partial_match and in_range_line(symbol.range, pos) then
                current = symbol
                partial_match = true
            end
            if partial_match then
                if in_range_line(symbol.range, pos) then
                    if in_range_character(symbol.range, pos) then
                        current = symbol
                        break
                    end
                else
                    break
                end
            end
        end
        if not partial_match then current = prev end
    end
    return current
end

---@param sidebar Sidebar
---@return Symbols
sidebar_current_symbols = function(sidebar)
    local source_buf = sidebar_source_win_buf(sidebar)
    assert(source_buf ~= -1)
    local symbols = sidebar.buf_symbols[source_buf]
    symbols.buf = source_buf
    return symbols
end

---@parm sidebar Sidebar
---@param symbols Symbols
local function sidebar_replace_current_symbols(sidebar, symbols)
    assert(symbols.buf ~= -1, "symbols.buf has to be set")
    sidebar.buf_symbols[symbols.buf] = symbols
end

---@return string
local function sidebar_str(sidebar)
    local tab = -1
    if vim.api.nvim_win_is_valid(sidebar.win) then
        tab = vim.api.nvim_win_get_tabpage(sidebar.win)
    end

    local buf_name = ""
    if vim.api.nvim_buf_is_valid(sidebar.buf) then
        buf_name = " (" .. vim.api.nvim_buf_get_name(sidebar.buf) .. ")"
    end

    local source_win_buf = -1
    local source_win_buf_name = ""
    if vim.api.nvim_win_is_valid(sidebar.source_win) then
        source_win_buf = vim.api.nvim_win_get_buf(sidebar.source_win)
        source_win_buf_name = vim.api.nvim_buf_get_name(source_win_buf)
        if source_win_buf_name == "" then
            source_win_buf_name = " <scratch buffer>"
        else
            source_win_buf_name = " (" .. source_win_buf_name .. ")"
        end
    end


    local lines = {
        "Sidebar(",
        "  deleted: " .. tostring(sidebar.deleted),
        "  visible: " .. tostring(sidebar_visible(sidebar)),
        "  tab: " .. tostring(tab),
        "  win: " .. tostring(sidebar.win),
        "  buf: " .. tostring(sidebar.buf) .. buf_name,
        "  source_win: " .. tostring(sidebar.source_win),
        "  source_win_buf: " .. tostring(source_win_buf) .. source_win_buf_name,
        "  buf_symbols: {",
    }

    for buf, root_symbol in pairs(sidebar.buf_symbols) do
        local _buf_name = vim.api.nvim_buf_get_name(buf)

        local symbols_count_string = " (no symbols)"
        local symbols_count = #root_symbol.children
        if symbols_count > 0 then
            symbols_count_string = " (" .. tostring(symbols_count) .. "+ symbols)"
        end

        local line = "    \"" .. buf .. "\" (" .. _buf_name .. ") " .. symbols_count_string
        table.insert(lines, line)
    end

    table.insert(lines, "  }")
    table.insert(lines, ")")
    return table.concat(lines, "\n")
end

---@param sidebar Sidebar
---@param vert_size integer
local function sidebar_change_size(sidebar, vert_size)
    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(sidebar.win)
    vim.cmd("vertical resize " .. tostring(vert_size))
    vim.api.nvim_set_current_win(original_win)
end

---@param sidebar Sidebar
---@param buf_lines string[] | nil
local function sidebar_refresh_size(sidebar, buf_lines)
    if not sidebar_visible(sidebar) or not sidebar.auto_resize.enabled then return end
    local vert_resize = sidebar.fixed_width
    if buf_lines == nil then
        buf_lines = vim.api.nvim_buf_get_lines(sidebar.buf, 0, -1, false)
    end
    local max_line_len = 0
    for _, line in ipairs(buf_lines) do
        max_line_len = math.max(max_line_len, #line)
    end
    vert_resize = max_line_len + 1
    vert_resize = math.max(sidebar.auto_resize.min_width, vert_resize)
    vert_resize = math.min(sidebar.auto_resize.max_width, vert_resize)
    sidebar_change_size(sidebar, vert_resize)
end

---@param dir OpenDirection
---@return "left" | "right"
local function find_split_direction(dir)
    if dir == "left" or dir == "right" then
        ---@diagnostic disable-next-line
        return dir
    end

    -- TODO: ignore floating windows?
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local curr_win = vim.api.nvim_get_current_win()
    if dir == "try-left" then
        return (wins[1] == curr_win and "left") or "right"
    elseif dir == "try-right" then
        return (wins[#wins] == curr_win and "right") or "left"
    end

    ---@diagnostic disable-next-line
    assert(false, "invalid dir")
end

---@param sidebar Sidebar
---@return integer, "left" | "right"
local function sidebar_open_bare_win(sidebar)
    local dir = find_split_direction(sidebar.gs.settings.open_direction)
    local width = sidebar.fixed_width
    local dir_cmd = (dir == "left" and "leftabove") or "rightbelow"
    vim.cmd("vertical " .. dir_cmd .. " " .. tostring(width) .. "split")
    return vim.api.nvim_get_current_win(), dir
end

local function sidebar_open(sidebar)
    if sidebar_visible(sidebar) then return end

    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(sidebar.source_win)
    sidebar.win, sidebar.win_dir = sidebar_open_bare_win(sidebar)
    vim.api.nvim_set_current_win(original_win)
    vim.api.nvim_win_set_buf(sidebar.win, sidebar.buf)

    sidebar.win_settings = WinSettings_get(sidebar.win)
    WinSettings_apply(
        sidebar.win,
        {
            number = false,
            relativenumber = false,
            signcolumn = "no",
            cursorline = true,
            winfixwidth = true,
            wrap = sidebar.wrap,
        }
    )

    sidebar_change_size(sidebar, sidebar.fixed_width)
    sidebar_refresh_size(sidebar, nil)
    if sidebar.gs.settings.on_open_make_windows_equal then
        vim.cmd("wincmd =")
    end
end

local function symbols_view_close(sidebar)
    sidebar.preview:close()
    sidebar.details:close()
end

--- Restore window state to default. Useful when opening a file in the sidebar window.
---@param sidebar Sidebar
local function sidebar_win_restore(sidebar)
    symbols_view_close(sidebar)
    sidebar.search_view:hide()
    WinSettings_apply(sidebar.win, sidebar.win_settings)
    reset_cursor(sidebar.gs.cursor)
    sidebar.win = -1
    vim.cmd("wincmd =")
end

sidebar_close = function(sidebar)
    if not sidebar_visible(sidebar) then return end
    symbols_view_close(sidebar)
    sidebar.search_view:hide()
    if vim.api.nvim_win_is_valid(sidebar.win) then
        vim.api.nvim_win_close(sidebar.win, true)
    end
    sidebar.win = -1
end

---@param sidebar Sidebar
local function sidebar_destroy(sidebar)
    sidebar_close(sidebar)
    if vim.api.nvim_buf_is_valid(sidebar.buf) then
        vim.api.nvim_buf_delete(sidebar.buf, { force = true })
        sidebar.buf = -1
    end
    sidebar.search_view:destroy()
    sidebar.source_win = -1
    sidebar.deleted = true
end

---@param sidebar Sidebar
---@return Symbol, SymbolState
sidebar_current_symbol = function(sidebar)
    assert(vim.api.nvim_win_is_valid(sidebar.win))

    local symbols = sidebar_current_symbols(sidebar)

    ---@param symbol Symbol
    ---@param num integer
    ---@return Symbol, integer
    local function _find_symbol(symbol, num)
        if num == 0 then return symbol, 0 end
        if symbols.states[symbol].folded then
            return symbol, num
        end
        for _, sym in ipairs(symbol.children) do
            if symbols.states[sym].visible then
                local s
                s, num = _find_symbol(sym, num - 1)
                if num <= 0 then return s, 0 end
            end
        end
        return symbol, num
    end

    local line = vim.api.nvim_win_get_cursor(sidebar.win)[1]
    local s, _ = _find_symbol(symbols.root, line)
    return s, symbols.states[s]
end

---@param symbols Symbols
---@return table<Symbol, integer>
local function get_line_for_each_symbol(symbols)
    local lines = {}

    ---@param symbol Symbol
    ---@param line integer
    local function get_lines(symbol, line)
        if symbols.states[symbol].folded then return line end
        for _, child in ipairs(symbol.children) do
            if symbols.states[child].visible then
                lines[child] = line
                line = get_lines(child, line + 1)
            end
        end
        return line
    end

    get_lines(symbols.root, 1)

    return lines
end

---@param symbols Symbols
---@param chars CharConfig
---@param show_guide_lines boolean
---@return string[], Highlight[]
local function sidebar_get_buf_lines_and_highlights(symbols, chars, show_guide_lines)
    ---@return boolean
    local function check_if_any_folded()
        for _, symbol in ipairs(symbols.root.children) do
            if symbols.states[symbol].visible_children > 0 then
                return true
            end
        end
        return false
    end
    local any_folded = check_if_any_folded()

    local buf_lines = {}
    local highlights = {}

    local ft = vim.api.nvim_get_option_value("filetype", { buf = symbols.buf })
    local kinds_display_config = cfg.get_config_by_filetype(symbols.provider_config.kinds, ft)
    local kinds_default_config = symbols.provider_config.kinds.default
    local highlights_config = cfg.get_config_by_filetype(symbols.provider_config.highlights, ft)

    ---@param symbol Symbol
    ---@param indent string
    ---@param line_nr integer
    ---@return integer
    local function get_buf_lines_and_highlights(symbol, indent, line_nr)
        if symbols.states[symbol].folded then return line_nr end
        for sym_i, sym in ipairs(symbol.children) do
            local state = symbols.states[sym]
            if state.visible then
                local prefix
                if state.visible_children == 0 then
                    if show_guide_lines and sym.level > 1 then
                        if sym_i == #symbol.children then
                            prefix = chars.guide_last_item .. " "
                        else
                            prefix = chars.guide_middle_item .. " "
                        end
                    else
                        if any_folded then
                            prefix = "  "
                        else
                            prefix = " "
                        end
                    end
                elseif state.folded then
                    prefix = chars.folded .. " "
                else
                    prefix = chars.unfolded .. " "
                end
                local kind_display = cfg.kind_for_symbol(kinds_display_config, sym, kinds_default_config)
                local line = indent .. prefix .. (kind_display ~= "" and (kind_display .. " ") or "") .. sym.name
                table.insert(buf_lines, line)
                local highlight = nvim.Highlight:new({
                    group = highlights_config[sym.kind],
                    line = line_nr,
                    col_start = #indent + #prefix,
                    col_end = #indent + #prefix + #kind_display
                })
                table.insert(highlights, highlight)
                local new_indent
                if show_guide_lines and sym.level > 1 and sym_i ~= #symbol.children then
                    new_indent = indent .. chars.guide_vert .. " "
                else
                    new_indent = indent .. "  "
                end
                line_nr = get_buf_lines_and_highlights(sym, new_indent, line_nr + 1)
            end
        end
        return line_nr
    end

    get_buf_lines_and_highlights(symbols.root, "", 1)
    return buf_lines, highlights
end

---@param sidebar Sidebar
---@param symbol Symbol
local function move_cursor_to_symbol(sidebar, symbol)
    assert(vim.api.nvim_win_is_valid(sidebar.win))
    local line = sidebar.lines[symbol]
    vim.api.nvim_win_set_cursor(sidebar.win, { line, 0 })
end

---@param symbols Symbols
---@return string[]
local function sidebar_get_inline_details(symbols)
    local details = {}
    local ft = vim.bo[symbols.buf].filetype
    local details_fun = symbols.provider_config.details[ft]
    if details_fun == nil then
        details_fun = function(symbol, _) return symbol.detail end
    end

    ---@param symbol Symbol
    local function get_details(symbol)
        if symbols.states[symbol].folded then return end
        for _, child in ipairs(symbol.children) do
            if symbols.states[child].visible then
                local detail = details_fun(child, { symbol_states = symbols.states })
                table.insert(details, detail)
                get_details(child)
            end
        end
    end

    get_details(symbols.root)
    return details
end

---@param buf integer
---@param details string[]
local function sidebar_add_inline_details(buf, details)
    for line, detail in ipairs(details) do
        vim.api.nvim_buf_set_extmark(
            buf, SIDEBAR_EXT_NS, line-1, -1,
            {
                virt_text = { { detail, "Comment" } },
                virt_text_pos = "eol",
                hl_mode = "combine",
            }
        )
    end
end

---@param sidebar Sidebar
sidebar_refresh_view = function(sidebar)
    local symbols = sidebar_current_symbols(sidebar)

    local buf_lines, highlights = sidebar_get_buf_lines_and_highlights(
        symbols, sidebar.char_config, sidebar.show_guide_lines
    )

    sidebar.lines = get_line_for_each_symbol(symbols)

    nvim.buf_set_content(sidebar.buf, buf_lines)

    for _, highlight in ipairs(highlights) do
        highlight:apply(sidebar.buf)
    end

    if sidebar.show_inline_details then
        local details = sidebar_get_inline_details(symbols)
        sidebar_add_inline_details(sidebar.buf, details)
    end

    sidebar_refresh_size(sidebar, buf_lines)
end

---@param sidebar Sidebar
local function sidebar_refresh_symbols(sidebar)
    if not sidebar_visible(sidebar) then
        log.trace("Skipping")
        return
    else
        log.trace("Refreshing")
    end

    ---@return Symbol?
    local function _find_symbol_with_name(symbol, name)
        for _, sym in ipairs(symbol.children) do
            if sym.name == name then return sym end
        end
        return nil
    end

    ---@param old_symbols Symbols
    ---@param new_symbols Symbols
    local function preserve_folds(old_symbols, new_symbols)
        ---@param old Symbol
        ---@param new Symbol
        local function _preserve_folds(old, new)
            if old.level > 0 and old_symbols.states[old].folded then return end
            for _, new_sym in ipairs(new.children) do
                local old_sym = _find_symbol_with_name(old, new_sym.name)
                if old_sym ~= nil then
                    new_symbols.states[new_sym].folded = old_symbols.states[old_sym].folded
                    _preserve_folds(old_sym, new_sym)
                end
            end
        end

        _preserve_folds(old_symbols.root, new_symbols.root)
        new_symbols.states[new_symbols.root].folded = false
    end

    ---@param new_root Symbol
    ---@param provider string
    ---@param provider_config table
    local function _refresh_sidebar(new_root, provider, provider_config)
        local current_symbols = sidebar_current_symbols(sidebar)
        local new_symbols = Symbols_new()
        new_symbols.provider = provider
        new_symbols.provider_config = provider_config
        new_symbols.buf = sidebar_source_win_buf(sidebar)
        new_symbols.root = new_root
        new_symbols.states = SymbolStates_build(new_root)
        preserve_folds(current_symbols, new_symbols)
        local symbols_filter = (sidebar.symbol_filters_enabled and sidebar.symbol_filter)
            or function(_, _) return true end
        Symbols_apply_filter(new_symbols, symbols_filter)
        sidebar_replace_current_symbols(sidebar, new_symbols)
        sidebar_refresh_view(sidebar)
    end

    ---@param provider_name string
    local function on_fail(provider_name)
        local lines = { "", " [symbols.nvim]", "", " " .. provider_name .. " provider failed" }
        nvim.buf_set_content(sidebar.buf, lines)
        sidebar_refresh_size(sidebar, lines)
    end

    ---@param provider_name string
    local function on_timeout(provider_name)
        local lines = {
            "", " [symbols.nvim]", "", " " .. provider_name .. " provider timed out",
            "", " Try again or increase", " timeout in config."
        }
        nvim.buf_set_content(sidebar.buf, lines)
        sidebar_refresh_size(sidebar, lines)
    end

    local buf = sidebar_source_win_buf(sidebar)
    local ok = SymbolsRetriever_retrieve(
        sidebar.symbols_retriever, buf, _refresh_sidebar, on_fail, on_timeout
    )
    if not ok then
        local ft = vim.bo[sidebar_source_win_buf(sidebar)].ft
        local lines
        if ft == "" then
            lines = { "", " [symbols.nvim]", "", " no filetype detected" }
        else
            lines = { "", " [symbols.nvim]", "", " no provider supporting", " " .. ft .. " found" }
        end
        nvim.buf_set_content(sidebar.buf, lines)
        sidebar_refresh_size(sidebar, lines)
    end
end

---@param symbols Symbols
---@param start_symbol Symbol
---@param value boolean
---@param depth_limit integer
---@return integer
local function symbol_change_folded_rec(symbols, start_symbol, value, depth_limit)

    ---@param symbol Symbol
    ---@param dl integer
    ---@return integer
    local function _change_folded_rec(symbol, dl)
        if dl <= 0 then return 0 end
        local symbol_state = symbols.states[symbol]
        local changes = (symbol_state.folded ~= value and #symbol.children > 0 and 1) or 0
        symbol_state.folded = value
        for _, sym in ipairs(symbol.children) do
            changes = changes + _change_folded_rec(sym, dl-1)
        end
        return changes
    end

    return _change_folded_rec(start_symbol, depth_limit)
end

---@param sidebar Sidebar
---@param target Symbol
---@param unfold boolean
local function sidebar_set_cursor_at_symbol(sidebar, target, unfold)
    local symbols = sidebar_current_symbols(sidebar)

    ---@param outer_range Range
    ---@param inner_range Range
    ---@return boolean
    local function range_contains(outer_range, inner_range)
        return (
            (
                outer_range.start.line < inner_range.start.line
                or (
                    outer_range.start.line == inner_range.start.line
                    and outer_range.start.character <= inner_range.start.character
                )
            ) and (
                inner_range["end"].line < outer_range["end"].line
                or (
                    outer_range["end"].line == inner_range["end"].line
                    and inner_range["end"].character <= outer_range["end"].character
                )
            )
        )
    end

    ---@param symbol Symbol
    ---@return integer
    local function count_lines(symbol)
        if not symbols.states[symbol].visible then return 0 end
        local lines = 1
        if not symbols.states[symbol].folded then
            for _, child in ipairs(symbol.children) do
                lines = lines + count_lines(child)
            end
        end
        return lines
    end

    local lines = 0
    local current = symbols.root
    while current ~= target do
        if not symbols.states[current].visible then break end
        if unfold then
            symbols.states[current].folded = false
        else
            if symbols.states[current].folded then break end
        end
        local found = false
        for _, child in ipairs(current.children) do
            if range_contains(child.range, target.range) then
                if symbols.states[child].visible then
                    lines = lines + 1
                end
                current = child
                found = true
                break
            else
                lines = lines + count_lines(child)
            end
        end
        if not found then break end
    end

    if lines == 0 then lines = 1 end
    if unfold then sidebar_refresh_view(sidebar) end
    vim.api.nvim_win_set_cursor(sidebar.win, { lines, 0 })
end

---@param win integer
---@param setting string
---@param value any
local function sidebar_show_toggle_notification(win, setting, value)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "delete", { buf = buf })

    if type(value) == "boolean" then
        value = (value and "on") or "off"
    end

    local text =  " " .. setting .. ": " .. tostring(value)
    local lines = { text }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local win_h = vim.api.nvim_win_get_height(win)
    local win_w = vim.api.nvim_win_get_width(win)
    local opts = {
        height = 1,
        width = win_w,
        border = "none",
        style = "minimal",
        relative = "win",
        win = win,
        anchor = "NW",
        row = win_h-2,
        col = 0,
    }
    local fw = vim.api.nvim_open_win(buf, false, opts)
    vim.defer_fn(
        function() vim.api.nvim_win_close(fw, true) end,
        1500
    )
end

---@param sidebar Sidebar
local function _sidebar_goto_symbol(sidebar)
    local symbol = sidebar_current_symbol(sidebar)
    vim.api.nvim_set_current_win(sidebar.source_win)
    vim.api.nvim_win_set_cursor(
        sidebar.source_win,
        { symbol.selectionRange.start.line + 1, symbol.selectionRange.start.character }
    )
    vim.fn.win_execute(sidebar.source_win, "normal! zz")
    flash_highlight_under_cursor(sidebar.source_win, 400, 1)
end

---@param sidebar Sidebar
local function sidebar_goto_symbol(sidebar)
    _sidebar_goto_symbol(sidebar)
    if sidebar.close_on_goto then sidebar_close(sidebar) end
end

---@param sidebar Sidebar
local function sidebar_preview_open(sidebar)
    sidebar.preview:open()
end

---@param sidebar Sidebar
local function sidebar_peek(sidebar)
    local reopen_details = sidebar.details.win ~= -1
    if reopen_details then sidebar.details:close() end
    local reopen_preview = sidebar.preview.win ~= -1
    if reopen_preview then sidebar.preview:close() end
    _sidebar_goto_symbol(sidebar)
    vim.api.nvim_set_current_win(sidebar.win)
    if reopen_details then sidebar.details:open() end
    if reopen_preview then sidebar_preview_open(sidebar) end
end

---@param sidebar Sidebar
local function sidebar_show_symbol_under_cursor(sidebar)
    local symbols = sidebar_current_symbols(sidebar)
    local pos = Pos_from_point(vim.api.nvim_win_get_cursor(sidebar.source_win))
    local symbol = symbol_at_pos(symbols.root, pos)
    sidebar_set_cursor_at_symbol(sidebar, symbol, true)
end

---@param sidebar Sidebar
local function sidebar_toggle_show_details(sidebar)
    if vim.api.nvim_win_is_valid(sidebar.details.win) then
        sidebar.details:close()
    else
        sidebar.details:open()
    end
end

---@param sidebar Sidebar
local function sidebar_goto_parent(sidebar)
    local symbol, _ = sidebar_current_symbol(sidebar)
    local count = math.max(vim.v.count, 1)
    while count > 0 and symbol.level > 1 do
        symbol = symbol.parent
        assert(symbol ~= nil)
        count = count - 1
    end
    sidebar_set_cursor_at_symbol(sidebar, symbol, false)
end

---@param list Symbol[]
---@param symbol Symbol
---@return integer
local function find_symbol_in_list(list, symbol)
    local i = -1
    for child_i, child in ipairs(list) do
        i = child_i
        if child == symbol then break end
    end
    return i
end

---@param sidebar Sidebar
local function sidebar_prev_symbol_at_level(sidebar)
    local symbol, _ = sidebar_current_symbol(sidebar)
    local symbol_idx = find_symbol_in_list(symbol.parent.children, symbol)
    assert(symbol_idx ~= -1, "symbol not found")
    local count = math.max(vim.v.count, 1)
    local new_idx = math.max(symbol_idx - count, 1)
    sidebar_set_cursor_at_symbol(sidebar, symbol.parent.children[new_idx], false)
end

---@param sidebar Sidebar
local function sidebar_next_symbol_at_level(sidebar)
    local symbol, _ = sidebar_current_symbol(sidebar)
    local symbol_idx = find_symbol_in_list(symbol.parent.children, symbol)
    assert(symbol_idx ~= -1, "symbol not found")
    local count = math.max(vim.v.count, 1)
    local new_idx = math.min(symbol_idx + count, #symbol.parent.children)
    sidebar_set_cursor_at_symbol(sidebar, symbol.parent.children[new_idx], false)
end

---@param sidebar Sidebar
local function sidebar_unfold(sidebar)
    local _, state = sidebar_current_symbol(sidebar)
    state.folded = false
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_fold(sidebar)
    local symbol, state = sidebar_current_symbol(sidebar)
    if symbol.level > 1 and (state.folded or #symbol.children == 0) then
        symbol = symbol.parent
        assert(symbol ~= nil)
    end
    state.folded = true
    sidebar_refresh_view(sidebar)
    move_cursor_to_symbol(sidebar, symbol)
end

---@param sidebar Sidebar
local function sidebar_unfold_recursively(sidebar)
    local symbols = sidebar_current_symbols(sidebar)
    local symbol, _ = sidebar_current_symbol(sidebar)
    symbol_change_folded_rec(symbols, symbol, false, utils.MAX_INT)
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_fold_recursively(sidebar)
    local symbols = sidebar_current_symbols(sidebar)
    local symbol = sidebar_current_symbol(sidebar)
    local changes = symbol_change_folded_rec(symbols, symbol, true, utils.MAX_INT)
    if changes == 0 then
        while(symbol.level > 1) do
            symbol = symbol.parent
            assert(symbol ~= nil)
        end
        symbol_change_folded_rec(symbols, symbol, true, utils.MAX_INT)
    end
    sidebar_refresh_view(sidebar)
    move_cursor_to_symbol(sidebar, symbol)
end

---@param sidebar Sidebar
local function sidebar_unfold_one_level(sidebar)

    local symbols = sidebar_current_symbols(sidebar)

    ---@param symbol Symbol
    ---@return integer
    local function find_level_to_unfold(symbol)
        if symbol.level ~= 0 and symbols.states[symbol].folded then
            return symbol.level
        end

        local min_level = utils.MAX_INT
        for _, sym in ipairs(symbol.children) do
            min_level = math.min(min_level, find_level_to_unfold(sym))
        end

        return min_level
    end

    local level = find_level_to_unfold(symbols.root)
    local count = math.max(vim.v.count, 1)
    symbol_change_folded_rec(symbols, symbols.root, false, level + count)
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_fold_one_level(sidebar)
    local symbols = sidebar_current_symbols(sidebar)

    ---@param symbol Symbol
    ---@return integer
    local function find_level_to_fold(symbol)
        local max_level = (symbols.states[symbol].folded and 1) or symbol.level
        for _, sym in ipairs(symbol.children) do
            if #sym.children > 0 then
                max_level = math.max(max_level, find_level_to_fold(sym))
            end
        end
        return max_level
    end

    ---@param _symbols Symbols
    ---@param level integer
    ---@param value boolean
    local function _change_fold_at_level(_symbols, level, value)
        local function change_fold(symbol)
            local state = symbols.states[symbol]
            if symbol.level == level then state.folded = value end
            if symbol.level >= level then return end
            for _, sym in ipairs(symbol.children) do
                change_fold(sym)
            end
        end

        change_fold(_symbols.root)
    end

    local level = find_level_to_fold(symbols.root)
    local count = math.max(vim.v.count, 1)
    for i=1,math.min(level, count) do
        _change_fold_at_level(symbols, level - i + 1, true)
    end
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_unfold_all(sidebar)
    local symbols = sidebar_current_symbols(sidebar)
    symbol_change_folded_rec(symbols, symbols.root, false, utils.MAX_INT)
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_fold_all(sidebar)
    local symbols = sidebar_current_symbols(sidebar)
    symbol_change_folded_rec(symbols, symbols.root, true, utils.MAX_INT)
    symbols.states[symbols.root].folded = false
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_search(sidebar)
    sidebar_change_view(sidebar, "search")
end

---@param sidebar Sidebar
local function sidebar_toggle_fold(sidebar)
    local symbol, state = sidebar_current_symbol(sidebar)
    if #symbol.children == 0 then return end
    state.folded = not state.folded
    sidebar_refresh_view(sidebar)
end

---@param sidebar Sidebar
local function sidebar_toggle_details(sidebar)
    sidebar.show_inline_details = not sidebar.show_inline_details
    sidebar_refresh_view(sidebar)
    sidebar_show_toggle_notification(sidebar.win, "inline details", sidebar.show_inline_details)
end

local function sidebar_toggle_auto_details(sidebar)
    sidebar.details:toggle_auto_show()
    sidebar_show_toggle_notification(sidebar.win, "auto details win", sidebar.details.auto_show)
end

---@param sidebar Sidebar
local function sidebar_toggle_auto_preview(sidebar)
    sidebar.preview:toggle_auto_show()
    sidebar_show_toggle_notification(sidebar.win, "auto preview win", sidebar.preview.auto_show)
end

---@param sidebar Sidebar
local function sidebar_toggle_cursor_hiding(sidebar)
    local cursor = sidebar.gs.cursor
    if cursor.hide then
        reset_cursor(cursor)
    else
        activate_cursorline(cursor)
    end
    cursor.hide = not cursor.hide
    sidebar_show_toggle_notification(sidebar.win, "cursor hiding", cursor.hide)
end

---@param sidebar Sidebar
local function sidebar_toggle_cursor_follow(sidebar)
    sidebar.cursor_follow = not sidebar.cursor_follow
    sidebar_show_toggle_notification(sidebar.win, "cursor follow", sidebar.cursor_follow)
end

---@param sidebar Sidebar
local function sidebar_toggle_filters(sidebar)
    sidebar.symbol_filters_enabled = not sidebar.symbol_filters_enabled
    sidebar_refresh_symbols(sidebar)
    sidebar_show_toggle_notification(sidebar.win, "symbol filters", sidebar.symbol_filters_enabled)
end

---@param sidebar Sidebar
local function sidebar_toggle_auto_peek(sidebar)
    sidebar.auto_peek = not sidebar.auto_peek
    sidebar_show_toggle_notification(sidebar.win, "auto peek", sidebar.auto_peek)
end

---@param sidebar Sidebar
local function sidebar_toggle_close_on_goto(sidebar)
    sidebar.close_on_goto = not sidebar.close_on_goto
    sidebar_show_toggle_notification(sidebar.win, "close on goto", sidebar.close_on_goto)
end

---@param sidebar Sidebar
local function sidebar_toggle_auto_resize(sidebar)
    sidebar.auto_resize.enabled = not sidebar.auto_resize.enabled
    sidebar_show_toggle_notification(sidebar.win, "auto resize", sidebar.auto_resize.enabled)
end

---@param sidebar Sidebar
local function sidebar_decrease_max_width(sidebar)
    local count = 5 * ((vim.v.count == 0 and 1) or vim.v.count)
    vim.cmd("vert resize -" .. tostring(count))
    sidebar.auto_resize.max_width = sidebar.auto_resize.max_width - count
    sidebar_refresh_size(sidebar, nil)
end

---@param sidebar Sidebar
local function sidebar_increase_max_width(sidebar)
    local count = 5 * ((vim.v.count == 0 and 1) or vim.v.count)
    vim.cmd("vert resize " .. tostring(count))
    sidebar.auto_resize.max_width = sidebar.auto_resize.max_width + count
    sidebar_refresh_size(sidebar, nil)
end

---@type SidebarAction[]
local help_options_order = {
    "goto-symbol",
    "peek-symbol",
    "open-preview",
    "open-details-window",
    "show-symbol-under-cursor",
    "goto-parent",
    "prev-symbol-at-level",
    "next-symbol-at-level",
    "toggle-fold",
    "unfold",
    "fold",
    "unfold-recursively",
    "fold-recursively",
    "unfold-one-level",
    "fold-one-level",
    "unfold-all",
    "fold-all",
    "search",
    "toggle-inline-details",
    "toggle-auto-details-window",
    "toggle-auto-preview",
    "toggle-cursor-hiding",
    "toggle-cursor-follow",
    "toggle-filters",
    "toggle-auto-peek",
    "toggle-close-on-goto",
    "toggle-auto-resize",
    "decrease-max-width",
    "increase-max-width",
    "help",
    "close",
}
utils.assert_list_is_enum(help_options_order, cfg.SidebarAction, "help_options_order")

---@type table<integer, SidebarAction>
local action_order = {}
for num, action in ipairs(help_options_order) do
    action_order[action] = num
end

---@param sidebar Sidebar
local function sidebar_help(sidebar)
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "delete", { buf = help_buf })
    vim.api.nvim_buf_set_option(sidebar.buf, "filetype", "SymbolsHelp")

    local keymaps = {}
    for i=1,#help_options_order do keymaps[i] = {} end

    for key, action in pairs(sidebar.keymaps) do
        local ord = action_order[action]
        table.insert(keymaps[ord], key)
    end

    local keys_str = {}
    local max_key_len = 0
    for ord, keys in ipairs(keymaps) do
        keys_str[ord] = vim.iter(keys):join(" / ")
        max_key_len = math.max(max_key_len, #keys_str[ord])
    end

    local lines = {"", "Keymaps", ""}

    for num=1,#help_options_order do
        local padding = string.rep(" ", max_key_len - #keys_str[num] + 2)
        table.insert(lines, "  " .. keys_str[num] .. padding .. help_options_order[num])
    end

    local max_width = 0
    for line_no=1,#lines do
        lines[line_no] = " " .. lines[line_no]
        max_width = math.max(max_width, #lines[line_no])
    end

    nvim.buf_set_content(help_buf, lines)
    nvim.buf_set_modifiable(help_buf, false)

    local width = max_width + 1
    local height = #lines + 1

    local ui = vim.api.nvim_list_uis()[1]
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

    local opts = {
        title = "Symbols Help",
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        border = "single",
        style = "minimal",
    }
    local help_win = vim.api.nvim_open_win(help_buf, false, opts)
    nvim.win_set_option(help_win, "cursorline", true)
    vim.api.nvim_set_current_win(help_win)
    vim.api.nvim_win_set_cursor(help_win, { 2, 0 })

    vim.keymap.set(
        "n", "q",
        function() vim.api.nvim_win_close(help_win, true) end,
        { buffer = help_buf }
    )

    vim.api.nvim_create_autocmd(
        "BufLeave",
        {
            callback = function() vim.api.nvim_win_close(help_win, true) end,
            buffer = help_buf,
        }
    )
end

---@type table<SidebarAction, fun(sidebar: Sidebar)>
local sidebar_actions = {
    ["goto-symbol"] = sidebar_goto_symbol,
    ["peek-symbol"] = sidebar_peek,

    ["open-preview"] = sidebar_preview_open,
    ["open-details-window"] = sidebar_toggle_show_details,
    ["show-symbol-under-cursor"] = sidebar_show_symbol_under_cursor,

    ["goto-parent"] = sidebar_goto_parent,
    ["prev-symbol-at-level"] = sidebar_prev_symbol_at_level,
    ["next-symbol-at-level"] = sidebar_next_symbol_at_level,

    ["unfold"] = sidebar_unfold,
    ["unfold-recursively"] = sidebar_unfold_recursively,
    ["unfold-one-level"] = sidebar_unfold_one_level,
    ["unfold-all"] = sidebar_unfold_all,

    ["fold"] = sidebar_fold,
    ["fold-recursively"] = sidebar_fold_recursively,
    ["fold-one-level"] = sidebar_fold_one_level,
    ["fold-all"] = sidebar_fold_all,

    ["search"] = sidebar_search,

    ["toggle-fold"] = sidebar_toggle_fold,
    ["toggle-inline-details"] = sidebar_toggle_details,
    ["toggle-auto-details-window"] = sidebar_toggle_auto_details,
    ["toggle-auto-preview"] = sidebar_toggle_auto_preview,
    ["toggle-cursor-hiding"] = sidebar_toggle_cursor_hiding,
    ["toggle-cursor-follow"] = sidebar_toggle_cursor_follow,
    ["toggle-filters"] = sidebar_toggle_filters,
    ["toggle-auto-peek"] = sidebar_toggle_auto_peek,
    ["toggle-close-on-goto"] = sidebar_toggle_close_on_goto,
    ["toggle-auto-resize"] = sidebar_toggle_auto_resize,
    ["decrease-max-width"] = sidebar_decrease_max_width,
    ["increase-max-width"] = sidebar_increase_max_width,

    ["help"] = sidebar_help,
    ["close"] = sidebar_close,
}

utils.assert_keys_are_enum(sidebar_actions, cfg.SidebarAction, "sidebar_actions")

---@param sidebar Sidebar
local function sidebar_on_cursor_move(sidebar)
    sidebar.preview:on_cursor_move()
    sidebar.details:on_cursor_move()
    if sidebar.auto_peek then sidebar_peek(sidebar) end
end

---@param sidebar Sidebar
local function sidebar_on_scroll(sidebar)
    -- this function is used only with "symbols" view
    if sidebar.details.win ~= -1 then
        sidebar.details:close()
        sidebar.details:open()
    end
    if sidebar.preview.win ~= -1 then
        sidebar.preview:close()
        sidebar.preview:open()
    end
end

---@param sidebar Sidebar
---@param symbols_retriever SymbolsRetriever
---@param num integer
---@param config SidebarConfig
---@param gs GlobalState
---@param debug boolean
local function sidebar_new(sidebar, symbols_retriever, num, config, gs, debug)
    sidebar.deleted = false
    sidebar.source_win = vim.api.nvim_get_current_win()
    sidebar.symbols_retriever = symbols_retriever

    sidebar.num = num
    sidebar.gs = gs

    sidebar.preview_config = config.preview
    sidebar.preview.sidebar = sidebar
    sidebar.preview.auto_show = config.preview.show_always

    sidebar.details.sidebar = sidebar
    sidebar.details.show_debug_info = debug

    sidebar.search_view:init(sidebar)

    sidebar.show_inline_details = config.show_inline_details
    sidebar.details.auto_show = config.show_details_pop_up
    sidebar.show_guide_lines = config.show_guide_lines
    sidebar.char_config = config.chars
    sidebar.keymaps = config.keymaps
    sidebar.wrap = config.wrap
    sidebar.auto_resize = vim.deepcopy(config.auto_resize, true)
    sidebar.fixed_width = config.fixed_width
    sidebar.symbol_filters_enabled = true
    sidebar.symbol_filter = config.symbol_filter
    sidebar.cursor_follow = config.cursor_follow
    sidebar.auto_peek = config.auto_peek
    sidebar.close_on_goto = config.close_on_goto

    sidebar.buf = vim.api.nvim_create_buf(false, true)
    nvim.buf_set_modifiable(sidebar.buf, false)
    vim.api.nvim_buf_set_name(sidebar.buf, "symbols.nvim [" .. tostring(num) .. "]")
    vim.api.nvim_buf_set_option(sidebar.buf, "filetype", "SymbolsSidebar")

    for key, action in pairs(config.keymaps) do
        vim.keymap.set(
            "n", key,
            function() sidebar_actions[action](sidebar) end,
            { buffer = sidebar.buf }
        )
    end

    vim.api.nvim_create_autocmd(
        { "CursorMoved" },
        {
            group = global_autocmd_group,
            buffer = sidebar.buf,
            callback = function() sidebar_on_cursor_move(sidebar) end,
            nested = true,
        }
    )

    vim.api.nvim_create_autocmd(
        { "CursorMoved" },
        {
            group = global_autocmd_group,
            callback = function()
                if (
                    not sidebar.cursor_follow or
                    not sidebar_visible(sidebar) or
                    sidebar.current_view ~= "symbols"
                ) then return end
                local win = vim.api.nvim_get_current_win()
                if win ~= sidebar.source_win then return end
                local symbols = sidebar_current_symbols(sidebar)
                local pos = Pos_from_point(vim.api.nvim_win_get_cursor(sidebar.source_win))
                local symbol = symbol_at_pos(symbols.root, pos)
                sidebar_set_cursor_at_symbol(sidebar, symbol, false)
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "WinScrolled" },
        {
            group = global_autocmd_group,
            buffer = sidebar.buf,
            callback = function() sidebar_on_scroll(sidebar) end,
        }
    )

    vim.api.nvim_create_autocmd(
        { "WinEnter" },
        {
            group = global_autocmd_group,
            callback = function()
                sidebar.preview:on_win_enter()
                sidebar.details:on_win_enter()
                if vim.api.nvim_get_current_win() == sidebar.win and sidebar.gs.cursor.hide then
                    hide_cursor(sidebar)
                end
            end,
        }
    )

    vim.api.nvim_create_autocmd(
        { "WinClosed" },
        {
            group = global_autocmd_group,
            callback = function(e)
                local win = tonumber(e.match, 10)
                sidebar.preview:on_win_close(win)
            end,
        }
    )
end

local function show_debug_in_current_window(sidebars)
    local buf = vim.api.nvim_create_buf(false, true)

    local lines = {}
    for _, sidebar in ipairs(sidebars) do
        local new_lines = vim.split(sidebar_str(sidebar), "\n") vim.list_extend(lines, new_lines) end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    nvim.buf_set_modifiable(buf, false)
end

---@param sidebars Sidebar[]
---@param win integer
---@return Sidebar?
local function find_sidebar_for_win(sidebars, win)
    for _, sidebar in ipairs(sidebars) do
        if sidebar.source_win == win or sidebar.win == win then
            return sidebar
        end
    end
    return nil
end

---@param sidebars Sidebar[]
---@return Sidebar?, integer
local function find_sidebar_for_reuse(sidebars)
    for num, sidebar in ipairs(sidebars) do
        if sidebar.deleted then
            return sidebar, num
        end
    end
    return nil, -1
end


---@param gs GlobalState
---@param sidebars Sidebar[]
---@param config Config
local function setup_dev(gs, sidebars, config)
    LOG_LEVEL = config.dev.log_level

    ---@param pkg string
    local function unload_package(pkg)
        local esc_pkg = pkg:gsub("([^%w])", "%%%1")
        for module_name, _ in pairs(package.loaded) do
            if string.find(module_name, esc_pkg) then
                package.loaded[module_name] = nil
            end
        end
    end

    local function reload()
        remove_user_commands()
        if not pcall(function() vim.api.nvim_del_augroup_by_id(global_autocmd_group) end) then
            log.warn("Failed to remove autocmd group.")
        end

        for _, sidebar in ipairs(sidebars) do
            sidebar_destroy(sidebar)
        end

        reset_cursor(gs.cursor)

        unload_package("symbols")
        require("symbols").setup(config)

        vim.cmd("SymbolsLogLevel " .. log.LOG_LEVEL_CMD_STRING[LOG_LEVEL])

        log.info("symbols.nvim reloaded")
    end

    local function debug()
        show_debug_in_current_window(sidebars)
    end

    local function show_config()
        local buf = vim.api.nvim_create_buf(false, true)
        local text = vim.inspect(config)
        local lines = vim.split(text, "\n")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        nvim.buf_set_modifiable(buf, false)
    end

    ---@type table<DevAction, fun()>
    local dev_action_to_fun = {
        ["reload"] = reload,
        ["debug"] = debug,
        ["show-config"] = show_config,
    }
    utils.assert_keys_are_enum(dev_action_to_fun, cfg.DevAction, "dev_action_to_fun")

    for key, action in pairs(config.dev.keymaps) do
        vim.keymap.set("n", key, dev_action_to_fun[action])
    end

end

---@param gs GlobalState
---@param sidebars Sidebar[]
---@param symbols_retriever SymbolsRetriever
---@param config Config
local function setup_user_commands(gs, sidebars, symbols_retriever, config)

    ---@return Sidebar
    local function _sidebar_new()
        local sidebar, num = find_sidebar_for_reuse(sidebars)
        if sidebar == nil then
            sidebar = sidebar_new_obj()
            table.insert(sidebars, sidebar)
            num = #sidebars
        end
        sidebar_new(sidebar, symbols_retriever, num, config.sidebar, gs, config.dev.enabled)
        return sidebar
    end

    create_user_command(
        "Symbols",
        function(e)
            local jump_to_sidebar = not e.bang

            local win = vim.api.nvim_get_current_win()
            for _, sidebar in ipairs(sidebars) do
                if not sidebar.deleted and sidebar.win == win then
                    vim.api.nvim_set_current_win(sidebar.source_win)
                    return
                end
            end

            local sidebar = find_sidebar_for_win(sidebars, win) or _sidebar_new()
            if sidebar_visible(sidebar) then
                vim.api.nvim_set_current_win(sidebar.win)
                sidebar_refresh_symbols(sidebar)
            else
                sidebar_open(sidebar)
                sidebar_refresh_symbols(sidebar)
                if jump_to_sidebar then vim.api.nvim_set_current_win(sidebar.win) end
            end
        end,
        {
            bang = true,
            desc = "Open the Symbols sidebar or jump to source code",
        }
    )

    create_user_command(
        "SymbolsOpen",
        function(e)
            local jump_to_sidebar = not e.bang
            local win = vim.api.nvim_get_current_win()
            local sidebar = find_sidebar_for_win(sidebars, win) or _sidebar_new()
            if not sidebar_visible(sidebar) then
                sidebar_open(sidebar)
                sidebar_refresh_symbols(sidebar)
                if jump_to_sidebar then vim.api.nvim_set_current_win(sidebar.win) end
            end
        end,
        {
            bang = true,
            desc = "Opens the Symbols sidebar"
        }
    )

    create_user_command(
        "SymbolsClose",
        function()
            local win = vim.api.nvim_get_current_win()
            local sidebar = find_sidebar_for_win(sidebars, win)
            if sidebar ~= nil then
                sidebar_close(sidebar)
            end
        end,
        { desc = "Close the Symbols sidebar" }
    )

    create_user_command(
        "SymbolsToggle",
        function(e)
            local jump_to_sidebar = not e.bang
            local win = vim.api.nvim_get_current_win()
            local sidebar = find_sidebar_for_win(sidebars, win) or _sidebar_new()
            if sidebar_visible(sidebar) then
                sidebar_close(sidebar)
            else
                sidebar_open(sidebar)
                sidebar_refresh_symbols(sidebar)
                if jump_to_sidebar then vim.api.nvim_set_current_win(sidebar.win) end
            end
        end,
        {
            bang = true,
            desc = "Open or close the Symbols sidebar"
        }
    )

    -- create_user_command(
    --     "SymbolsCurrent",
    --     function()
    --         local win = vim.api.nvim_get_current_win()
    --         local sidebar = find_sidebar_for_win(sidebars, win)
    --         if sidebar ~= nil then
    --             local symbols = sidebar_current_symbols(sidebar)
    --             local pos = Pos_from_point(vim.api.nvim_win_get_cursor(sidebar.source_win))
    --             local symbol = symbol_at_pos(symbols.root, pos)
    --             sidebar_set_cursor_at_symbol(sidebar, symbol, true)
    --         end
    --     end,
    --     {}
    -- )

    create_user_command(
        "SymbolsDebugToggle",
        function()
            config.dev.enabled = not config.dev.enabled
            for _, sidebar in ipairs(sidebars) do
                sidebar.details.show_debug_info = config.dev.enabled
            end
            LOG_LEVEL = (config.dev.enabled and config.dev.log_level) or log.DEFAULT_LOG_LEVEL
        end,
        {}
    )

    log.create_change_log_level_user_command(
        "SymbolsLogLevel",
        "Change the Symbols debug level",
        create_user_command
    )
end

---@param gs GlobalState
---@param sidebars Sidebar[]
---@param symbols_retriever SymbolsRetriever
local function setup_autocommands(gs, sidebars, symbols_retriever)
    vim.api.nvim_create_autocmd(
        { "WinEnter" },
        {
            group = global_autocmd_group,
            callback = function()
                if gs.cursor.hide then
                    local win = vim.api.nvim_get_current_win()
                    for _, sidebar in ipairs(sidebars) do
                        if sidebar.win == win then
                            activate_cursorline(gs.cursor)
                            return
                        end
                    end
                end
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "WinLeave" },
        {
            group = global_autocmd_group,
            callback = function()
                if gs.cursor.hide or gs.cursor.hidden then
                    reset_cursor(gs.cursor)
                end
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "WinClosed" },
        {
            group = global_autocmd_group,
            callback = function(t)
                local win = tonumber(t.match, 10)
                for _, sidebar in ipairs(sidebars) do
                    if sidebar.source_win == win then
                        sidebar_destroy(sidebar)
                    elseif sidebar.win == win then
                        sidebar_close(sidebar)
                    end
                end
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "BufWritePost", "FileChangedShellPost" },
        {
            group = global_autocmd_group,
            callback = function(t)
                local source_buf = t.buf
                symbols_retriever.cache[source_buf].fresh = false
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "LspAttach", "BufWinEnter", "BufWritePost", "FileChangedShellPost" },
        {
            group = global_autocmd_group,
            callback = function(t)
                local source_buf = t.buf
                for _, sidebar in ipairs(sidebars) do
                    if sidebar_source_win_buf(sidebar) == source_buf then
                        sidebar_refresh_symbols(sidebar)
                    end
                end
            end
        }
    )

    vim.api.nvim_create_autocmd(
        { "BufEnter" },
        {
            group = global_autocmd_group,
            callback = function(t) -- TODO fix
                local win = vim.api.nvim_get_current_win()
                local buf = tonumber(t.buf)
                for _, sidebar in ipairs(sidebars) do
                    if (
                        sidebar.win == win
                        and sidebar.buf ~= buf
                        and sidebar.search_view.buf ~= buf
                    ) then
                        sidebar_win_restore(sidebar)
                        return
                    end
                end
            end
        }
    )
end

function M.setup(...)
    local config = cfg.prepare_config(...)

    ---@type GlobalState
    local gs = GlobalState_new()
    gs.cursor.hide = config.sidebar.hide_cursor
    gs.settings.open_direction = config.sidebar.open_direction
    gs.settings.on_open_make_windows_equal = config.sidebar.on_open_make_windows_equal

    ---@type [string, Provider][]
    local providers = {
        { "lsp", providers.LspProvider },
        { "treesitter", providers.TSProvider },
    }
    local symbols_retriever = SymbolsRetriever_new(providers, config.providers)

    ---@type Sidebar[]
    local sidebars = {}

    if config.dev.enabled then setup_dev(gs, sidebars, config) end
    setup_user_commands(gs, sidebars, symbols_retriever, config)
    setup_autocommands(gs, sidebars, symbols_retriever)
end

return M
