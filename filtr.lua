-- filtr
-- midi transformation engine
-- norns + grid
-- + internal PolyPerc engine for standalone playback
--
-- ENC1: select transform / navigate chain
-- ENC2: select parameter
-- ENC3: adjust parameter value
-- KEY2: toggle selected transform on/off
-- KEY3: reset selected param to default
--
-- grid:
--   row 1: transform slots (cols 1-16, lit = active)
--   row 2: param 1 value bar
--   row 3: param 2 value bar
--   row 4: param 3 value bar
--   row 5: on/off toggle for transform (col 1)
--   rows 6-8: reserved / visual feedback
--
-- CHAIN MODE (K1+K2):
--   ENC1: navigate chain slots
--   ENC2: scroll through available transforms
--   K2: add transform to chain (at current slot)
--   K3: remove transform from current chain slot

engine.name = "PolyPerc"

local midi_in  = nil
local midi_out = nil
local g        = nil  -- grid

local function midi_to_hz(note)
  return 440 * 2^((note - 69) / 12)
end

-- ────────────────────────────────────────
-- SCREEN STATE (NEW)
-- ────────────────────────────────────────
local beat_phase = 0
local popup_param = nil
local popup_val = nil
local popup_time = 0
local midi_activity_time = 0

-- ────────────────────────────────────────
-- TRANSFORM DEFINITIONS
-- each transform has:
--   name, active, params[], process(msg, state)
-- ────────────────────────────────────────

local SCALES = {
  { name="chromatic",  intervals={0,1,2,3,4,5,6,7,8,9,10,11} },
  { name="major",      intervals={0,2,4,5,7,9,11} },
  { name="minor",      intervals={0,2,3,5,7,8,10} },
  { name="dorian",     intervals={0,2,3,5,7,9,10} },
  { name="phrygian",   intervals={0,1,3,5,7,8,10} },
  { name="lydian",     intervals={0,2,4,6,7,9,11} },
  { name="mixolydian", intervals={0,2,4,5,7,9,10} },
  { name="pentatonic", intervals={0,2,4,7,9} },
  { name="blues",      intervals={0,3,5,6,7,10} },
  { name="whole tone", intervals={0,2,4,6,8,10} },
}

-- quantize note to scale
local function quantize_to_scale(note, root, scale_idx)
  local scale = SCALES[scale_idx].intervals
  local octave = math.floor((note - root) / 12)
  local pc = (note - root) % 12
  -- find nearest scale degree
  local best, best_dist = scale[1], 12
  for _, deg in ipairs(scale) do
    local d = math.min(math.abs(deg - pc), 12 - math.abs(deg - pc))
    if d < best_dist then best = deg; best_dist = d end
  end
  return root + octave * 12 + best
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function clamp_note(n) return clamp(n, 0, 127) end

-- ── note delay buffer ───────────────────
local delay_buffer = {}  -- {note, ch, vel, time}
local held_notes   = {}  -- track for note-off delay

-- ── chord detection ─────────────────────
local chord_notes = {}   -- notes currently held, sorted

-- ── strum state ────────────────────────
local strum_jobs = {}

-- ────────────────────────────────────────
-- TRANSFORMS TABLE
-- ────────────────────────────────────────

local transforms = {

  -- 1. TRANSPOSE
  {
    name   = "transpose",
    active = false,
    params = {
      { name="semitones", val=0,  min=-24, max=24, default=0 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        msg.note = clamp_note(msg.note + p[1].val)
      end
      return {msg}
    end,
  },

  -- 2. SCALE QUANTIZE
  {
    name   = "scale quant",
    active = false,
    params = {
      { name="root",  val=0,  min=0,  max=11, default=0 },
      { name="scale", val=2,  min=1,  max=#SCALES, default=2 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        msg.note = quantize_to_scale(msg.note, p[1].val, p[2].val)
      end
      return {msg}
    end,
  },

  -- 3. HARMONIZE
  {
    name   = "harmonize",
    active = false,
    params = {
      { name="interval", val=7,  min=-24, max=24, default=7 },
      { name="velocity%", val=80, min=1, max=100, default=80 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        local copy = {type=msg.type, note=clamp_note(msg.note+p[1].val),
                      vel=math.floor(msg.vel*(p[2].val/100)), ch=msg.ch}
        return {msg, copy}
      end
      return {msg}
    end,
  },

  -- 4. INVERT
  {
    name   = "invert",
    active = false,
    params = {
      { name="axis note", val=60, min=0, max=127, default=60 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        msg.note = clamp_note(2*p[1].val - msg.note)
      end
      return {msg}
    end,
  },

  -- 5. OCTAVE FOLD
  {
    name   = "oct fold",
    active = false,
    params = {
      { name="low note",  val=36, min=0,  max=127, default=36 },
      { name="high note", val=84, min=0,  max=127, default=84 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        local lo, hi = p[1].val, p[2].val
        while msg.note < lo  do msg.note = msg.note + 12 end
        while msg.note > hi do msg.note = msg.note - 12 end
        msg.note = clamp_note(msg.note)
      end
      return {msg}
    end,
  },

  -- 6. NOTE RANGE FILTER
  {
    name   = "range filt",
    active = false,
    params = {
      { name="low note",  val=21,  min=0,  max=127, default=21 },
      { name="high note", val=108, min=0,  max=127, default=108 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        if msg.note < p[1].val or msg.note > p[2].val then return {} end
      end
      return {msg}
    end,
  },

  -- 7. VELOCITY SCALE
  {
    name   = "vel scale",
    active = false,
    params = {
      { name="scale%", val=100, min=1,  max=200, default=100 },
      { name="offset",  val=0,  min=-64, max=64,  default=0 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        msg.vel = clamp(math.floor(msg.vel * p[1].val / 100) + p[2].val, 0, 127)
      end
      return {msg}
    end,
  },

  -- 8. VELOCITY HUMANIZE
  {
    name   = "vel human",
    active = false,
    params = {
      { name="amount", val=10, min=0, max=64, default=10 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        local jitter = math.floor((math.random() * 2 - 1) * p[1].val)
        msg.vel = clamp(msg.vel + jitter, 1, 127)
      end
      return {msg}
    end,
  },

  -- 9. VELOCITY FIXED
  {
    name   = "vel fixed",
    active = false,
    params = {
      { name="velocity", val=80, min=1, max=127, default=80 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then msg.vel = p[1].val end
      return {msg}
    end,
  },

  -- 10. VELOCITY CURVE
  {
    name   = "vel curve",
    active = false,
    params = {
      -- curve: 1=log, 2=linear, 3=exp
      { name="curve", val=2, min=1, max=3, default=2 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        local v = msg.vel / 127
        if     p[1].val == 1 then v = math.log(v*9+1)/math.log(10) -- log (softer)
        elseif p[1].val == 3 then v = v^2                           -- exp (harder)
        end
        msg.vel = clamp(math.floor(v*127+0.5), 1, 127)
      end
      return {msg}
    end,
  },

  -- 11. TIMING HUMANIZE
  {
    name   = "time human",
    active = false,
    params = {
      { name="amount ms", val=20, min=0, max=200, default=20 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        local delay_ms = math.random(0, p[1].val)
        local original = {type=msg.type,note=msg.note,vel=msg.vel,ch=msg.ch}
        clock.run(function()
          clock.sleep(delay_ms/1000)
          send_midi(original)
        end)
        return {}  -- we handle sending ourselves
      end
      return {msg}
    end,
  },

  -- 12. NOTE DELAY / ECHO
  {
    name   = "echo",
    active = false,
    params = {
      { name="delay ms",  val=250, min=10, max=2000, default=250 },
      { name="repeats",   val=2,   min=1,  max=8,    default=2   },
      { name="vel decay%", val=70, min=10, max=100,  default=70  },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        for i=1, p[2].val do
          local v = math.floor(msg.vel * (p[3].val/100)^i)
          if v < 1 then break end
          local note = msg.note
          local ch   = msg.ch
          clock.run(function()
            clock.sleep(i * p[1].val / 1000)
            send_midi({type="note_on",  note=note, vel=v,  ch=ch})
            clock.sleep(0.1)
            send_midi({type="note_off", note=note, vel=0,  ch=ch})
          end)
        end
      end
      return {msg}
    end,
  },

  -- 13. NOTE LENGTH
  {
    name   = "note len",
    active = false,
    params = {
      { name="length ms", val=100, min=10, max=5000, default=100 },
      { name="mode",      val=1,   min=1,  max=2,    default=1   },
      -- mode 1=fixed, 2=scale existing
    },
    process = function(msg, p)
      -- For fixed mode: intercept note_on, schedule note_off ourselves
      -- For scale mode: track note_on time, adjust note_off
      if msg.type == "note_on" and p[2].val == 1 then
        local note = msg.note; local ch = msg.ch; local vel = msg.vel
        clock.run(function()
          send_midi({type="note_on",  note=note, vel=vel, ch=ch})
          clock.sleep(p[1].val/1000)
          send_midi({type="note_off", note=note, vel=0,   ch=ch})
        end)
        return {}
      end
      return {msg}
    end,
  },

  -- 14. STRUM
  {
    name   = "strum",
    active = false,
    params = {
      { name="delay ms", val=30, min=1,  max=500, default=30 },
      { name="direction", val=1, min=1,  max=2,   default=1  },
      -- 1=low→high, 2=high→low
    },
    _chord = {},
    _timer = nil,
    process = function(msg, p, self)
      -- collect simultaneous notes, strum after a short window
      if msg.type == "note_on" then
        table.insert(self._chord, {note=msg.note, vel=msg.vel, ch=msg.ch})
        if self._timer then clock.cancel(self._timer) end
        self._timer = clock.run(function()
          clock.sleep(0.015) -- 15ms collection window
          local chord = self._chord
          self._chord = {}
          table.sort(chord, function(a,b)
            if p[2].val == 1 then return a.note < b.note else return a.note > b.note end
          end)
          for i, n in ipairs(chord) do
            clock.run(function()
              clock.sleep((i-1) * p[1].val / 1000)
              send_midi({type="note_on", note=n.note, vel=n.vel, ch=n.ch})
            end)
          end
        end)
        return {}
      end
      return {msg}
    end,
  },

  -- 15. PROBABILITY
  {
    name   = "prob",
    active = false,
    params = {
      { name="pass%", val=100, min=0, max=100, default=100 },
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        if math.random(100) > p[1].val then return {} end
      end
      return {msg}
    end,
  },

  -- 16. OCTAVE SCATTER
  {
    name   = "oct scatter",
    active = false,
    params = {
      { name="range oct", val=1, min=0, max=4, default=1 },
      { name="prob%",     val=50, min=0, max=100, default=50 },
    },
    process = function(msg, p)
      if msg.type == "note_on" or msg.type == "note_off" then
        if math.random(100) <= p[2].val then
          local shift = math.floor((math.random() * 2 - 1) * p[1].val) * 12
          msg.note = clamp_note(msg.note + shift)
        end
      end
      return {msg}
    end,
  },

  -- 17. CHANNEL REROUTE
  {
    name   = "ch reroute",
    active = false,
    params = {
      { name="out ch", val=1, min=1, max=16, default=1 },
    },
    process = function(msg, p)
      msg.ch = p[1].val
      return {msg}
    end,
  },

  -- 18. CHORD STRIP (poly→mono)
  {
    name   = "chord strip",
    active = false,
    params = {
      -- mode: 1=lowest, 2=highest, 3=last
      { name="mode", val=1, min=1, max=3, default=1 },
    },
    _held = {},
    process = function(msg, p, self)
      if msg.type == "note_on" then
        self._held[msg.note] = true
        local notes = {}
        for n,_ in pairs(self._held) do table.insert(notes, n) end
        table.sort(notes)
        local pass_note
        if     p[1].val == 1 then pass_note = notes[1]
        elseif p[1].val == 2 then pass_note = notes[#notes]
        else                       pass_note = msg.note  -- last
        end
        if msg.note ~= pass_note then return {} end
      elseif msg.type == "note_off" then
        self._held[msg.note] = nil
      end
      return {msg}
    end,
  },

  -- 19. CC REMAP
  {
    name   = "cc remap",
    active = false,
    params = {
      { name="src CC",  val=1,   min=0,  max=127, default=1   },
      { name="dst CC",  val=11,  min=0,  max=127, default=11  },
      { name="scale%",  val=100, min=1,  max=200, default=100 },
    },
    process = function(msg, p)
      if msg.type == "cc" and msg.cc == p[1].val then
        msg.cc  = p[2].val
        msg.val = clamp(math.floor(msg.val * p[3].val / 100), 0, 127)
      end
      return {msg}
    end,
  },

  -- 20. PITCH SHIFT (in cents via pitch bend)
  {
    name   = "pb shift",
    active = false,
    params = {
      { name="semitones", val=0, min=-12, max=12, default=0 },
      -- maps to pitch bend range (assumes ±12 semitone PB range)
    },
    process = function(msg, p)
      if msg.type == "note_on" then
        -- send pitch bend before note
        local pb = math.floor((p[1].val / 12) * 8191 + 8192)
        pb = clamp(pb, 0, 16383)
        local lsb = pb & 0x7F
        local msb = (pb >> 7) & 0x7F
        return {
          {type="pitchbend", val=pb, ch=msg.ch},
          msg
        }
      end
      return {msg}
    end,
  },

}

-- ────────────────────────────────────────
-- TRANSFORM CHAIN
-- ────────────────────────────────────────

local chain = {}  -- ordered list of transform indices
local max_chain_slots = 4  -- limited to 4 as per spec
local chain_mode = false
local chain_selected_slot = 1
local chain_probs = {}  -- probability (0-100) for each chain slot

-- ────────────────────────────────────────
-- MIDI I/O
-- ────────────────────────────────────────

local function send_midi(msg)
  if midi_out then
    if msg.type == "note_on" then
      midi_out:note_on(msg.note, msg.vel, msg.ch)
    elseif msg.type == "note_off" then
      midi_out:note_off(msg.note, msg.vel, msg.ch)
    elseif msg.type == "cc" then
      midi_out:cc(msg.cc, msg.val, msg.ch)
    elseif msg.type == "pitchbend" then
      midi_out:pitchbend(msg.val, msg.ch)
    end
  end
end

local function process_chain(msg)
  local results = {msg}
  for _, t_idx in ipairs(chain) do
    local transform = transforms[t_idx]
    if transform.active then
      local next_results = {}
      for _, m in ipairs(results) do
        local out = transform.process(m, transform.params, transform)
        if out then
          for _, o in ipairs(out) do
            table.insert(next_results, o)
          end
        end
      end
      results = next_results
    end
  end
  return results
end

local function midi_event(data)
  local msg_type = data[1] >> 4
  local channel  = (data[1] & 0x0F) + 1
  
  if msg_type == 0x9 then  -- note on
    local note = data[2]
    local vel  = data[3]
    local msgs = process_chain({type="note_on", note=note, vel=vel, ch=channel})
    for _, m in ipairs(msgs) do
      send_midi(m)
    end
    midi_activity_time = util.time()
  elseif msg_type == 0x8 then  -- note off
    local note = data[2]
    local vel  = data[3]
    local msgs = process_chain({type="note_off", note=note, vel=vel, ch=channel})
    for _, m in ipairs(msgs) do
      send_midi(m)
    end
  elseif msg_type == 0xB then  -- CC
    local cc = data[2]
    local val = data[3]
    local msgs = process_chain({type="cc", cc=cc, val=val, ch=channel})
    for _, m in ipairs(msgs) do
      send_midi(m)
    end
  end
end

-- ────────────────────────────────────────
-- GRID STATE
-- ────────────────────────────────────────

local grid_transform_idx = 1  -- currently displayed transform
local grid_param_idx = 1       -- currently selected param for this transform

local function grid_redraw()
  g:all(0)
  
  -- Row 1: show active transforms
  for i=1, #transforms do
    if transforms[i].active then
      g:led(i, 1, 15)
    end
  end
  
  -- Rows 2-4: parameter value bars
  local t = transforms[grid_transform_idx]
  if t.params then
    for p_idx=1, math.min(3, #t.params) do
      local p = t.params[p_idx]
      local range = p.max - p.min
      local val_norm = (p.val - p.min) / range
      local cols = math.floor(val_norm * 15) + 1
      for col=1, cols do
        g:led(col, p_idx + 1, 8)
      end
    end
  end
  
  -- Row 5: on/off toggle
  if t.active then
    g:led(1, 5, 15)
  end
  
  g:refresh()
end

local function grid_key(x, y, z)
  if z == 0 then return end
  
  if y == 1 then
    -- Row 1: Select transform (1-16)
    if x <= #transforms then
      grid_transform_idx = x
      grid_param_idx = 1
      grid_redraw()
    end
  elseif y == 5 and x == 1 then
    -- Row 5, col 1: Toggle active
    local t = transforms[grid_transform_idx]
    t.active = not t.active
    grid_redraw()
  end
end

-- ────────────────────────────────────────
-- SCREEN RENDERING
-- ────────────────────────────────────────

local selected_transform = 1
local selected_param = 1

local function screen_redraw()
  screen.clear()
  screen.move(0, 8)
  screen.text("filtr")
  screen.move(0, 18)
  screen.text("Transforms: " .. #chain .. "/" .. max_chain_slots)
  
  local y = 28
  for i, t_idx in ipairs(chain) do
    local t = transforms[t_idx]
    local status = t.active and "[X]" or "[ ]"
    screen.move(0, y)
    screen.text(status .. " " .. t.name)
    y = y + 10
  end
  
  if chain_mode then
    screen.move(0, 50)
    screen.text("CHAIN MODE")
  end
  
  screen.update()
end

-- ────────────────────────────────────────
-- ENCODER / KEY HANDLERS
-- ────────────────────────────────────────

function enc(n, delta)
  if n == 1 then
    selected_transform = util.clamp(selected_transform + delta, 1, #transforms)
  elseif n == 2 then
    if transforms[selected_transform].params then
      selected_param = util.clamp(selected_transform + delta, 1, #transforms[selected_transform].params)
    end
  elseif n == 3 then
    local t = transforms[selected_transform]
    if t.params and selected_param <= #t.params then
      local p = t.params[selected_param]
      p.val = util.clamp(p.val + delta, p.min, p.max)
    end
  end
  screen_redraw()
end

function key(n, z)
  if z == 0 then return end
  
  if n == 2 then
    -- Toggle transform active
    transforms[selected_transform].active = not transforms[selected_transform].active
  elseif n == 3 then
    -- Reset param to default
    local t = transforms[selected_transform]
    if t.params and selected_param <= #t.params then
      t.params[selected_param].val = t.params[selected_param].default
    end
  end
  screen_redraw()
end

-- ────────────────────────────────────────
-- INIT
-- ────────────────────────────────────────

function init()
  -- MIDI connections
  midi_in = midi.connect(1)
  midi_in.event = midi_event
  
  midi_out = midi.connect(2)
  
  -- Grid connection
  if g then g:all(0); g:refresh() end
  g = grid.connect()
  if g then
    function g.key(x, y, z) grid_key(x, y, z) end
    grid_redraw()
  end
  
  -- Default chain: add a few transforms
  table.insert(chain, 1)  -- transpose
  table.insert(chain, 2)  -- scale quant
  
  screen_redraw()
end

-- ────────────────────────────────────────
-- CLEANUP (K1+K3)
-- ────────────────────────────────────────

function cleanup()
  for i=1, #chain do
    local t = transforms[chain[i]]
    if t._timer then
      clock.cancel(t._timer)
    end
  end
  
  -- Cancel all pending clock jobs
  clock.cancel()
  
  -- PolyPerc is fire-and-forget (no noteOff/noteKill commands)
end
