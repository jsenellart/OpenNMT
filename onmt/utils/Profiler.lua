--[[ Profile is a class used for generating profiling of a training
--]]
local Profiler = torch.class('Profiler')

function Profiler.declareOpts(cmd)
  cmd:option('-profiler', false, [[Generate profiling logs]])
end

--[[ Profiler object

To avoid concurrency problem for parallel processing, each thread should have its own Profiler.
Profiles can be embedded.

Parameters:
  * `opt` - access to program parameter

Example:
    -- global profiler initialization
    globalProfiler = onmt.utils.Profiler.new(opt)

    -- thread-specific profiler
      _G.profiler = onmt.utils.Profiler.new(opt)

      _G.profiler:reset()

      _G.profiler:start("encoder")
      [...]
      _G.profiler:stop("encoder"):start("decoder")
      [...]
      _G.profiler:stop("decoder")

      local profile = _G.profiler.dump()

    -- adds up thread profile
    globalProfiler:add(profile)

    Logger:info(globalProfiler:log())

]]
function Profiler:__init(doProfile)
  if not doProfile then
    self.disable = true
  end
  self:reset()
end

-- Reset Profiler.
function Profiler:reset()
  self.profiles = {}
  self.timers = {}
  self.stack = {}
end

-- Start recording a section.
function Profiler:start(name)
  if self.disable then return self end
  -- if section is multiple, decompose
  local pos = name:find("%.")
  if pos then
    self:start(name:sub(1, pos-1))
    self:start(name:sub(pos+1))
  else
    if not self.timers[name] then self.timers[name] = {} end
    table.insert(self.timers[name], torch.Timer())
    table.insert(self.stack, name)
  end
  return self
end

-- Stop recording a section.
function Profiler:stop(name)
  if self.disable then return self end
  -- if section is multiple, decompose
  local pos = name:find("%.")
  if pos then
    self:stop(name:sub(pos+1))
    self:stop(name:sub(1, pos-1))
  else
    assert(self.stack[#self.stack] == name, 'Invalid profiler stop action: '..name)
    local path = table.concat(self.stack, ".")
    if not self.profiles[path] then self.profiles[path] = 0 end
    local timer = table.remove(self.timers[name])
    self.profiles[path] = self.profiles[path] + timer:time().real
    table.remove(self.stack)
  end
  return self
end

-- Dump profile.
function Profiler:dump()
  if self.disable then return end
  return self.profiles
end

-- Aggregage profiles with a previous dump in the current namespace
function Profiler:add(profile)
  if self.disable then return end
  local prefix = table.concat(self.stack, '.')
  if #prefix > 0 then prefix = prefix .. '.' end
  for name,v in pairs(profile) do
    if not self.profiles[prefix..name] then self.profiles[prefix..name] = 0 end
    self.profiles[prefix..name] = self.profiles[prefix..name] + v
  end
end

-- Returns text string with log structured by sub level.
-- e.g. train:[23, encoder_fwd:10, encoder_bwd:14]
function Profiler:log(prefix)
  prefix = prefix or ''
  local t = {}
  for name,v in pairs(self.profiles) do
    v = string.format("%g", v)
    if name:sub(1,#prefix) == prefix then
      local pos = #prefix + 1
      if not name:sub(pos):find("%.") then
        local subtree = self:log(name..'.')
        if #subtree > 0 then
          v='['..v..', '..subtree..']'
        end
        table.insert(t, name:sub(pos)..':'..v)
      end
    end
  end
  return table.concat(t, ", ")
end

return Profiler
