---@mod rustaceanvim.neotest
---
---@brief [[
---
---A |neotest| adapter for rust, powered by rustaceanvim.
---
---If you add this to neotest:
---
--->
---require('neotest').setup {
---    -- ...,
---    adapters = {
---      -- ...,
---      require('rustaceanvim.neotest')
---    },
---}
---<
---
---this plugin will configure itself to use |neotest|
---as a test executor, and |neotest| will use rust-analyzer
---for test discovery and command construction.
---
---Note: If you use this adapter, do not add the neotest-rust adapter
---(another plugin).
---
---@brief ]]

---@diagnostic disable: duplicate-set-field

local lib = require('neotest.lib')
local nio = require('nio')
local trans = require('rustaceanvim.neotest.trans')
local cargo = require('rustaceanvim.cargo')

---@package
---@type neotest.Adapter
local NeotestAdapter = { name = 'rustaceanvim' }

---@package
---@param file_name string
---@return string | nil
NeotestAdapter.root = function(file_name)
  return cargo.get_root_dir(file_name)
end

---@package
---@param rel_path string Path to directory, relative to root
---@return boolean
NeotestAdapter.filter_dir = function(_, rel_path, _)
  return rel_path ~= 'target'
end

---@package
---@param file_path string
---@return boolean
NeotestAdapter.is_test_file = function(file_path)
  return vim.endswith(file_path, '.rs')
end

---@package
---@class rustaceanvim.neotest.Position: neotest.Position
---@field runnable? RARunnable

---@package
---@param file_path string
---@return neotest.Tree
NeotestAdapter.discover_positions = function(file_path)
  ---@type rustaceanvim.neotest.Position[]
  local positions = {}
  local rust_analyzer = require('rustaceanvim.rust_analyzer')
  local future = nio.control.future()
  rust_analyzer.file_request(file_path, 'experimental/runnables', nil, function(err, runnables)
    if err then
      future.set_error(err)
    else
      future.set(runnables)
    end
  end)
  local ok, runnables = pcall(future.wait)
  if not ok or type(runnables) ~= 'table' or #runnables == 0 then
    ---@diagnostic disable-next-line: missing-parameter
    return lib.positions.parse_tree(positions)
  end

  local max_end_row = 0
  for _, runnable in pairs(runnables) do
    local pos = trans.runnable_to_position(file_path, runnable)
    if pos then
      max_end_row = math.max(max_end_row, pos.range[3])
      if pos.type ~= 'dir' then
        table.insert(positions, pos)
      end
    end
  end
  ---@diagnostic disable-next-line: cast-type-mismatch
  ---@cast runnables RARunnable[]

  ---@type { [string]: neotest.Position }
  local tests_by_name = {}
  ---@type rustaceanvim.neotest.Position[]
  local namespaces = {}
  for _, pos in pairs(positions) do
    if pos.type == 'test' then
      tests_by_name[pos.name] = pos
    elseif pos.type == 'namespace' then
      table.insert(namespaces, pos)
    end
  end

  -- sort namespaces by name from longest to shortest
  table.sort(namespaces, function(a, b)
    return #a.name > #b.name
  end)

  ---@type { [string]: rustaceanvim.neotest.Position[] }
  local positions_by_namespace = {}
  -- group tests by their longest matching namespace
  for _, namespace in ipairs(namespaces) do
    if namespace.name ~= '' then
      ---@type string[]
      local child_keys = vim.tbl_filter(function(name)
        return vim.startswith(name, namespace.name .. '::')
      end, vim.tbl_keys(tests_by_name))
      local children = { namespace }
      for _, key in ipairs(child_keys) do
        local child_pos = tests_by_name[key]
        tests_by_name[key] = nil
        --- strip the namespace and "::" from the name
        child_pos.name = child_pos.name:sub(#namespace.name + 3, #child_pos.name)
        table.insert(children, child_pos)
      end
      positions_by_namespace[namespace.name] = children
    end
  end

  -- nest child namespaces in their parent namespace
  for i, namespace in ipairs(namespaces) do
    ---@type rustaceanvim.neotest.Position?
    local parent = nil
    -- search remaning namespaces for the longest matching parent namespace
    for _, other_namespace in ipairs { unpack(namespaces, i + 1) } do
      if vim.startswith(namespace.name, other_namespace.name .. '::') then
        parent = other_namespace
        break
      end
    end
    if parent ~= nil then
      local namespace_name = namespace.name
      local children = positions_by_namespace[namespace_name]
      -- strip parent namespace + "::"
      children[1].name = children[1].name:sub(#parent.name + 3, #namespace_name)
      table.insert(positions_by_namespace[parent.name], children)
      positions_by_namespace[namespace_name] = nil
    end
  end

  local sorted_positions = {}
  for _, namespace_positions in pairs(positions_by_namespace) do
    table.insert(sorted_positions, namespace_positions)
  end
  -- any remaning tests had no parent namespace
  vim.list_extend(sorted_positions, vim.tbl_values(tests_by_name))

  -- sort positions by their start range
  local function sort_positions(to_sort)
    for _, item in ipairs(to_sort) do
      if vim.tbl_islist(item) then
        sort_positions(item)
      end
    end

    -- pop header from the list before sorting since it's used to sort in its parent's context
    local header = table.remove(to_sort, 1)
    table.sort(to_sort, function(a, b)
      local a_item = vim.tbl_islist(a) and a[1] or a
      local b_item = vim.tbl_islist(b) and b[1] or b
      if a_item.range[1] == b_item.range[1] then
        return a_item.name < b_item.name
      else
        return a_item.range[1] < b_item.range[1]
      end
    end)
    table.insert(to_sort, 1, header)
  end
  sort_positions(sorted_positions)

  if #namespaces > 0 then
    local file_pos = {
      id = file_path,
      name = vim.fn.fnamemodify(file_path, ':t'),
      type = 'file',
      path = file_path,
      range = { 0, 0, max_end_row, 0 },
      -- use the shortest namespace for the file runnable
      runnable = namespaces[#namespaces].runnable,
    }
    table.insert(sorted_positions, 1, file_pos)
  end

  return require('neotest.types.tree').from_list(sorted_positions, function(x)
    return x.name
  end)
end

---@package
---@class rustaceanvim.neotest.RunSpec: neotest.RunSpec
---@field context rustaceanvim.neotest.RunContext

---@package
---@class rustaceanvim.neotest.RunContext
---@field file string
---@field pos_id string
---@field type neotest.PositionType
---@field tree neotest.Tree

---@package
---@param run_args neotest.RunArgs
---@return neotest.RunSpec|nil
---@private
function NeotestAdapter.build_spec(run_args)
  local supported_types = { 'test', 'namespace', 'file', 'dir' }
  local tree = run_args and run_args.tree
  if not tree then
    return
  end
  local pos = tree:data()
  ---@cast pos rustaceanvim.neotest.Position
  if not vim.tbl_contains(supported_types, pos.type) then
    return
  end
  local runnable = pos.runnable
  if not runnable then
    return
  end
  local context = {
    file = pos.path,
    pos_id = pos.id,
    type = pos.type,
    tree = tree,
  }
  local exe, args, cwd = require('rustaceanvim.runnables').get_command(runnable)
  if run_args.strategy == 'dap' then
    local dap = require('rustaceanvim.dap')
    local overrides = require('rustaceanvim.overrides')
    overrides.sanitize_command_for_debugging(runnable.args.cargoArgs)
    local future = nio.control.future()
    dap.start(runnable.args, false, function(strategy)
      future.set(strategy)
    end, function(err)
      future.set_error(err)
    end)
    local ok, strategy = pcall(future.wait)
    if not ok then
      ---@cast strategy string
      lib.notify(strategy, vim.log.levels.ERROR)
    end
    ---@cast strategy DapClientConfig
    ---@type rustaceanvim.neotest.RunSpec
    local run_spec = {
      cwd = cwd,
      context = context,
      strategy = strategy,
    }
    return run_spec
  end
  ---@type rustaceanvim.neotest.RunSpec
  ---@diagnostic disable-next-line: missing-fields
  local run_spec = {
    command = vim.list_extend({ exe }, args),
    cwd = cwd,
    context = context,
  }
  return run_spec
end

---@package
---Get the file root from a test tree.
---@param tree neotest.Tree The test tree.
---@return neotest.Tree file_root The file root position.
local function get_file_root(tree)
  for _, node in tree:iter_parents() do
    local data = node and node:data()
    if data and not vim.tbl_contains({ 'test', 'namespace' }, data.type) then
      return node
    end
  end
  return tree
end

---@package
---@param spec neotest.RunSpec
---@param strategy_result neotest.StrategyResult
---@return table<string, neotest.Result> results
function NeotestAdapter.results(spec, strategy_result)
  ---@type table<string, neotest.Result>
  local results = {}
  ---@type rustaceanvim.neotest.RunContext
  local context = spec.context
  local ctx_pos_id = context.pos_id
  ---@type string
  local output_content = lib.files.read(strategy_result.output)
  if strategy_result.code == 0 then
    results[ctx_pos_id] = {
      status = 'passed',
      output = strategy_result.output,
    }
    return results
  end
  ---@type table<string,neotest.Error[]>
  local errors_by_test_id = {}
  output_content = output_content:gsub('\r\n', '\n')
  local diagostics = require('rustaceanvim.test').parse_diagnostics(context.file, output_content)
  for _, diagnostic in pairs(diagostics) do
    ---@type neotest.Error
    local err = {
      line = diagnostic.lnum,
      message = diagnostic.message,
    }
    errors_by_test_id[diagnostic.test_id] = errors_by_test_id[diagnostic.test_id] or {}
    table.insert(errors_by_test_id[diagnostic.test_id], err)
  end
  if not vim.tbl_contains({ 'file', 'test', 'namespace' }, context.type) then
    return results
  end
  results[ctx_pos_id] = {
    status = 'failed',
    output = strategy_result.output,
  }
  for _, node in get_file_root(context.tree):iter_nodes() do
    local data = node:data()
    for test_id, errors in pairs(errors_by_test_id) do
      if vim.endswith(data.id, test_id) then
        results[data.id] = {
          status = 'failed',
          errors = errors,
          short = output_content,
        }
      end
    end
  end
  return results
end

setmetatable(NeotestAdapter, {
  __call = function()
    return NeotestAdapter
  end,
})

return NeotestAdapter
