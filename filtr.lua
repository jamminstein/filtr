-- filtr
-- midi transformation engine
-- norns + grid
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

engine.name = "None"

local midi_in  = nil
local midi_out = nil
local g        = nil  -- grid

-- ──────────────────────────────────────────────
-- SCREEN STATE (NEW)
-- ──────────────────────────────────────────────
local beat_phase = 0
local popup_param = nil
local popup_val = nil
local popup_time = 0
local midi_activity_time = 0

-- ──────────────────────────────────────────────
-- TRANSFORM DEFINITIONS
-- each transform has:
--   name, active, params[], process(msg, state)
-- ──────────────────────────────────────────────

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

-- ── note delay buffer ──────────────────────────
local delay_buffer = {}  -- {note, ch, vel, time}
local held_notes   = {}  -- track for note-off delay

-- ── chord detection ───────────────────────────
local chord_notes = {}   -- notes currently held, sorted

-- ── strum state ──────────────────────────────
local strum_jobs = {}

-- ──────────────────────────────────────────────
-- TRANSFORMS TABLE
-- ──────────────────────────────────────────────

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

-- ──────────────────────────────────────────────
-- TRANSFORM CHAIN
-- ──────────────────────────────────────────────

local chain = {}  -- ordered list of transform indices
local max_chain_slots = 4  -- limited to 4 as per spec
local chain_mode = false
local chain_selected_slot = 1
local chain_probs = {}  -- probability (0-100) for each chain slot

-- ──────────────────────────────────────────────
-- STATE
-- ──────────────────────────────────────────────

local state = {
  selected_transform = 1,
  selected_param     = 1,
  midi_in_port       = 1,
  midi_out_port       = 2,
  input_channel      = 0,   -- 0 = all channels, 1-16 = specific
  output_channel     = 0,   -- 0 = same as input, 1-16 = fixed
}

-- ──────────────────────────────────────────────
-- MIDI SEND
-- ──────────────────────────────────────────────

function send_midi(msg)
  if not midi_out then return end
  if msg.type == "note_on" then
    midi_out:note_on(msg.note, msg.vel or 100, msg.ch or 1)
  elseif msg.type == "note_off" then
    midi_out:note_off(msg.note, msg.vel or 0, msg.ch or 1)
  elseif msg.type == "cc" then
    midi_out:cc(msg.cc, msg.val, msg.ch or 1)
  elseif msg.type == "pitchbend" then
    midi_out:pitchbend(msg.val, msg.ch or 1)
  elseif msg.type == "program_change" then
    midi_out:program_change(msg.val, msg.ch or 1)
  elseif msg.type == "aftertouch" then
    midi_out:aftertouch(msg.note, msg.val, msg.ch or 1)
  end
end

-- ──────────────────────────────────────────────
-- TRANSFORM PIPELINE (with chaining)
-- ──────────────────────────────────────────────

-- Process through chain in order, applying probability per slot
local function process_chain(original_msg)
  -- Check channel filtering
  if state.input_channel ~= 0 and original_msg.ch ~= state.input_channel then
    return  -- Skip this message if channel doesn't match
  end

  local msgs = {original_msg}
  for slot_idx, chain_idx in ipairs(chain) do
    if chain_idx then
      local t = transforms[chain_idx]
      if t then
        -- Check probability for this chain slot
        local prob = chain_probs[slot_idx] or 100
        if math.random(100) > prob then
          -- Probability check failed, skip this transform
          goto continue_chain
        end

        if t.active then
          local next_msgs = {}
          for _, m in ipairs(msgs) do
            -- deep copy
            local mc = {}
            for k,v in pairs(m) do mc[k]=v end
            local results = t.process(mc, t.params, t)
            for _, r in ipairs(results) do
              table.insert(next_msgs, r)
            end
          end
          msgs = next_msgs
        end
      end
    end
    ::continue_chain::
  end

  -- Apply output channel remapping
  for _, m in ipairs(msgs) do
    if state.output_channel ~= 0 then
      m.ch = state.output_channel
    end
    send_midi(m)
  end
  -- Track MIDI activity
  midi_activity_time = util.time()
end

-- ──────────────────────────────────────────────
-- MIDI IN
-- ──────────────────────────────────────────────

local function connect_midi()
  midi_in  = midi.connect(state.midi_in_port)
  midi_out = midi.connect(state.midi_out_port)
  if midi_in then
    midi_in.event = function(data)
      local msg = midi.to_msg(data)
      process_chain(msg)
    end
  end
end

-- ──────────────────────────────────────────────
-- GRID
-- ──────────────────────────────────────────────

local function grid_redraw()
  if not g then return end
  g:all(0)

  local t = transforms
  local sel = state.selected_transform

  if chain_mode then
    -- Chain display mode
    -- Row 1: chain slots (shows which transforms are in the chain)
    for slot = 1, max_chain_slots do
      local transform_idx = chain[slot]
      local bright = 0
      if slot == chain_selected_slot then
        bright = 15
      elseif transform_idx then
        bright = 8
      else
        bright = 2
      end
      g:led(slot, 1, bright)
    end

    -- Row 2: probability sliders for each chain slot (4 columns)
    for slot = 1, max_chain_slots do
      local prob = chain_probs[slot] or 100
      local frac = prob / 100
      local cols = math.floor(frac * 4 + 0.5)
      for c = 1, 4 do
        local bright = 0
        if c <= cols then
          bright = (slot == chain_selected_slot) and 12 or 6
        else
          bright = 2
        end
        g:led((slot - 1) * 4 + c, 2, bright)
      end
    end
  else
    -- Transform selector mode (original behavior)
    -- Row 1: transform on/off (cols 1-16 = transforms 1-16)
    for i = 1, math.min(16, #t) do
      local bright = 0
      if i == sel then bright = 15
      elseif t[i].active then bright = 8
      else bright = 2
      end
      g:led(i, 1, bright)
    end

    -- Row 2: transforms 17-20 in cols 1-4 (if > 16 transforms)
    for i = 17, math.min(20, #t) do
      local col = i - 16
      local bright = 0
      if i == sel then bright = 15
      elseif t[i].active then bright = 8
      else bright = 2
      end
      g:led(col, 2, bright)
    end

    -- Rows 3-5: param bars for selected transform
    local tr = t[sel]
    if tr then
      for p_idx = 1, math.min(3, #tr.params) do
        local par = tr.params[p_idx]
        local row = p_idx + 2  -- rows 3,4,5
        local range = par.max - par.min
        local frac  = (par.val - par.min) / range
        local cols  = math.floor(frac * 16 + 0.5)
        for c = 1, 16 do
          local bright = 0
          if c <= cols then
            bright = (p_idx == state.selected_param) and 12 or 6
          end
          g:led(c, row, bright)
        end
      end
    end

    -- Row 8: on/off indicator for selected transform
    if tr then
      g:led(1, 8, tr.active and 15 or 3)
      -- label col indicator: flash selected param
      for p_idx = 1, math.min(3, #(tr.params or {})) do
        g:led(p_idx + 2, 8, p_idx == state.selected_param and 12 or 4)
      end
    end
  end

  g:refresh()
end

local function grid_key(x, y, z)
  if z == 0 then return end  -- only on press

  if chain_mode then
    -- Chain mode controls
    if y == 1 then
      -- Select chain slot
      if x >= 1 and x <= max_chain_slots then
        chain_selected_slot = x
      end
    elseif y == 2 then
      -- Probability slider for selected chain slot (4 columns per slot)
      local slot = chain_selected_slot
      local col_in_slot = ((x - 1) % 4) + 1
      local prob = math.floor((col_in_slot - 1) / 4 * 100 + 0.5) * 25
      chain_probs[slot] = prob
    end
  else
    -- Normal mode controls

    -- Row 1: select/toggle transforms 1-16
    if y == 1 then
      local i = x
      if i >= 1 and i <= #transforms then
        if i == state.selected_transform then
          transforms[i].active = not transforms[i].active
        else
          state.selected_transform = i
          state.selected_param = 1
        end
      end
    end

    -- Row 2: transforms 17+
    if y == 2 then
      local i = x + 16
      if i >= 17 and i <= #transforms then
        if i == state.selected_transform then
          transforms[i].active = not transforms[i].active
        else
          state.selected_transform = i
          state.selected_param = 1
        end
      end
    end

    -- Rows 3-5: set param value by clicking bar
    if y >= 3 and y <= 5 then
      local p_idx = y - 2
      local tr = transforms[state.selected_transform]
      if tr and tr.params[p_idx] then
        state.selected_param = p_idx
        local par = tr.params[p_idx]
        local frac = (x - 1) / 15
        par.val = math.floor(par.min + frac * (par.max - par.min) + 0.5)
      end
    end

    -- Row 8 col 1: toggle active
    if y == 8 and x == 1 then
      local tr = transforms[state.selected_transform]
      if tr then tr.active = not tr.active end
    end

    -- Row 8 cols 3-5: select param
    if y == 8 and x >= 3 and x <= 5 then
      local tr = transforms[state.selected_transform]
      local p_idx = x - 2
      if tr and tr.params[p_idx] then
        state.selected_param = p_idx
      end
    end
  end

  grid_redraw()
  redraw()
end

-- ──────────────────────────────────────────────
-- NORNS SCREEN (REDESIGNED)
-- ──────────────────────────────────────────────

local CURVE_NAMES = {"log","linear","exp"}
local STRIP_NAMES = {"lowest","highest","last"}
local DIRECTION_NAMES = {"low→hi","hi→low"}

local function param_display(tr, p_idx)
  if not tr or not tr.params[p_idx] then return "" end
  local par = tr.params[p_idx]
  local v = par.val
  -- special display for certain transforms
  if tr.name == "scale quant" and par.name == "root" then
    local notes={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
    return notes[v+1]
  elseif tr.name == "scale quant" and par.name == "scale" then
    return SCALES[v].name
  elseif tr.name == "vel curve" then
    return CURVE_NAMES[v]
  elseif tr.name == "chord strip" then
    return STRIP_NAMES[v]
  elseif tr.name == "strum" and par.name == "direction" then
    return DIRECTION_NAMES[v]
  end
  return tostring(v)
end

-- Helper: get abbreviation for transform (max 3 chars)
local function transform_abbrev(name)
  if name == "transpose" then return "TRP"
  elseif name == "scale quant" then return "QNT"
  elseif name == "harmonize" then return "HRM"
  elseif name == "invert" then return "INV"
  elseif name == "oct fold" then return "OCT"
  elseif name == "range filt" then return "RNG"
  elseif name == "vel scale" then return "VEL"
  elseif name == "vel human" then return "VHU"
  elseif name == "vel fixed" then return "VFX"
  elseif name == "vel curve" then return "CRV"
  elseif name == "time human" then return "THU"
  elseif name == "echo" then return "ECH"
  elseif name == "note len" then return "LEN"
  elseif name == "strum" then return "STR"
  elseif name == "prob" then return "PRB"
  elseif name == "oct scatter" then return "SCT"
  elseif name == "ch reroute" then return "CH"
  elseif name == "chord strip" then return "CHD"
  elseif name == "cc remap" then return "CC"
  elseif name == "pb shift" then return "PB"
  else return name:sub(1,3):upper() end
end

function redraw()
  screen.clear()
  screen.font_face(0)
  screen.font_size(8)
  
  local now = util.time()
  local midi_active = (now - midi_activity_time) < 0.2
  
  if chain_mode then
    -- Chain mode display
    screen.level(15)
    screen.move(0, 8)
    screen.text("filtr CHAIN")

    screen.level(8)
    screen.move(0, 20)
    screen.text("Chain order:")

    local chain_str = ""
    for i, idx in ipairs(chain) do
      if idx then
        local name = transforms[idx].name:sub(1, 6)
        if i > 1 then chain_str = chain_str .. " > " end
        chain_str = chain_str .. name
      end
    end

    if #chain == 0 then chain_str = "(empty)" end
    screen.level(12)
    screen.move(0, 32)
    if #chain_str > 40 then
      screen.text(chain_str:sub(1, 40) .. "…")
    else
      screen.text(chain_str)
    end

    -- Show probabilities for each slot
    screen.level(7)
    screen.move(0, 44)
    screen.font_size(7)
    local prob_str = "Probs: "
    for slot = 1, max_chain_slots do
      local prob = chain_probs[slot] or 100
      prob_str = prob_str .. prob .. "% "
    end
    screen.text(prob_str)

    screen.level(4)
    screen.move(0, 54)
    screen.font_size(7)
    screen.text("ENC1: slot  ENC2: prob  K2: save  K3: load")
    screen.move(0, 62)
    screen.text("K1: exit chain mode")
  else
    -- ════════════════════════════════════════════════════════════
    -- STATUS STRIP (y 0-8)
    -- ════════════════════════════════════════════════════════════
    screen.level(4)
    screen.move(0, 8)
    screen.text("FILTR")
    
    -- Chain size indicator
    local active_count = 0
    for _, idx in ipairs(chain) do
      if idx and transforms[idx].active then
        active_count = active_count + 1
      end
    end
    screen.level(6)
    screen.move(48, 8)
    screen.text(string.format("CHAIN: %d", #chain))
    
    -- Beat pulse dot at x=124 (level 4)
    beat_phase = (beat_phase + 0.1) % 1.0
    local pulse = math.sin(beat_phase * math.pi * 2) * 0.5 + 0.5
    screen.level(math.floor(3 + pulse * 3))
    screen.move(124, 6)
    screen.text(".")
    
    -- ════════════════════════════════════════════════════════════
    -- LIVE ZONE (y 9-52): Transform chain pipeline
    -- ════════════════════════════════════════════════════════════
    
    screen.level(8)
    screen.move(0, 18)
    screen.text("Transform Pipeline:")
    
    -- Draw horizontal chain pipeline
    local pipe_y = 26
    local block_width = 14
    local spacing = 20
    local start_x = 2
    
    for slot = 1, max_chain_slots do
      local x = start_x + (slot - 1) * spacing
      local transform_idx = chain[slot]
      
      if transform_idx then
        local t = transforms[transform_idx]
        local is_selected = (state.selected_transform == transform_idx)
        local is_active = t.active
        
        if is_selected then
          screen.level(15)  -- Selected block bright
        else
          screen.level(8)   -- Non-selected chain blocks
        end
        
        -- Draw block with abbreviation
        screen.rect(x, pipe_y - 6, block_width, 7)
        screen.stroke()
        
        local abbrev = transform_abbrev(t.name)
        screen.move(x + 1, pipe_y - 1)
        screen.font_size(6)
        screen.text(abbrev:sub(1, 3))
        screen.font_size(8)
      else
        -- Empty slot shown as dashed outline
        screen.level(3)
        screen.move(x + 2, pipe_y - 4)
        screen.text("- -")
      end
      
      -- Draw arrow between blocks
      if slot < max_chain_slots and chain[slot] then
        screen.level(4)
        screen.move(x + block_width + 2, pipe_y - 2)
        screen.text(">")
      end
    end
    
    -- ════════════════════════════════════════════════════════════
    -- SELECTED TRANSFORM PARAMETERS
    -- ════════════════════════════════════════════════════════════
    
    local tr = transforms[state.selected_transform]
    if tr then
      screen.level(15)
      screen.move(2, 42)
      screen.font_size(8)
      screen.text(tr.name)
      
      -- Show parameters with hierarchy
      if tr.params then
        for i, par in ipairs(tr.params) do
          local y = 50 + (i-1)*8
          
          if i == state.selected_param then
            screen.level(15)  -- Active param bright
          else
            screen.level(7)   -- Other params darker
          end
          
          screen.move(2, y)
          screen.font_size(7)
          screen.text(par.name)
          screen.move(56, y)
          screen.text(param_display(tr, i))
        end
      end
    end
    
    -- ════════════════════════════════════════════════════════════
    -- MIDI ACTIVITY INDICATOR
    -- ════════════════════════════════════════════════════════════
    if midi_active then
      screen.level(12)
    else
      screen.level(3)
    end
    screen.move(113, 28)
    screen.text("●")
    
    -- ════════════════════════════════════════════════════════════
    -- CONTEXT BAR (y 53-58)
    -- ════════════════════════════════════════════════════════════
    
    screen.level(5)
    screen.move(0, 62)
    screen.font_size(7)
    screen.text(string.format("IN:%d  OUT:%d  %s",
      state.midi_in_port,
      state.midi_out_port,
      midi_active and "ACTIVE" or "-"
    ))
    
    -- ════════════════════════════════════════════════════════════
    -- POPUP (enc() triggered, 0.8s duration)
    -- ════════════════════════════════════════════════════════════
    
    if popup_param and (now - popup_time) < 0.8 then
      screen.level(15)
      screen.font_size(8)
      local text = popup_param .. ": " .. popup_val
      local text_w = string.len(text) * 6
      local x = math.max(2, 64 - text_w/2)
      screen.rect(x - 2, 36, text_w + 4, 10)
      screen.fill()
      screen.level(0)
      screen.move(x, 44)
      screen.text(text)
    end
  end

  screen.update()
end

-- ──────────────────────────────────────────────
-- ENCODERS & KEYS
-- ──────────────────────────────────────────────

function enc(n, d)
  if chain_mode then
    if n == 1 then
      chain_selected_slot = clamp(chain_selected_slot + d, 1, max_chain_slots)
    elseif n == 2 then
      -- Adjust probability for selected chain slot
      local current = chain_probs[chain_selected_slot] or 100
      chain_probs[chain_selected_slot] = clamp(current + (d * 5), 0, 100)
      popup_param = "Chain " .. chain_selected_slot .. " Prob"
      popup_val = chain_probs[chain_selected_slot] .. "%"
      popup_time = util.time()
    elseif n == 3 then
      -- unused in chain mode
    end
  else
    if n == 1 then
      state.selected_transform = clamp(state.selected_transform + d, 1, #transforms)
      state.selected_param = 1
    elseif n == 2 then
      local tr = transforms[state.selected_transform]
      if tr then
        state.selected_param = clamp(state.selected_param + d, 1, #tr.params)
      end
    elseif n == 3 then
      local tr = transforms[state.selected_transform]
      if tr and tr.params[state.selected_param] then
        local par = tr.params[state.selected_param]
        par.val = clamp(par.val + d, par.min, par.max)
        -- Trigger popup
        popup_param = par.name
        popup_val = param_display(tr, state.selected_param)
        popup_time = util.time()
      end
    end
  end
  grid_redraw()
  redraw()
end

local key_hold_time = {}  -- Track hold time per key for long-press detection

function key(n, z)
  if z == 1 then
    -- Key pressed: start tracking
    key_hold_time[n] = util.time()
  elseif z == 0 then
    -- Key released: check if long-press (> 0.5s)
    local held_time = util.time() - (key_hold_time[n] or 0)
    local is_long_press = held_time > 0.5

    if n == 1 then
      if not is_long_press then
        -- Toggle chain mode
        chain_mode = not chain_mode
      end
    elseif n == 2 then
      if is_long_press then
        -- Long press: save preset
        save_preset()
      else
        -- Short press
        if chain_mode then
          -- Remove transform from chain slot
          chain[chain_selected_slot] = nil
        else
          -- Toggle active
          local tr = transforms[state.selected_transform]
          if tr then tr.active = not tr.active end
        end
      end
    elseif n == 3 then
      if is_long_press then
        -- Long press: load preset
        load_preset()
      else
        -- Short press
        if chain_mode then
          -- Exit chain mode
          chain_mode = false
        else
          -- Reset param to default
          local tr = transforms[state.selected_transform]
          if tr and tr.params[state.selected_param] then
            tr.params[state.selected_param].val = tr.params[state.selected_param].default
          end
        end
      end
    end
    key_hold_time[n] = nil
  end
  grid_redraw()
  redraw()
end

-- ──────────────────────────────────────────────
-- PRESET SAVE/LOAD
-- ──────────────────────────────────────────────

local function ensure_preset_dir()
  local dir = _path.data .. "filtr/"
  os.execute("mkdir -p " .. dir)
end

local function save_preset()
  ensure_preset_dir()
  local preset = {
    chain = chain,
    chain_probs = chain_probs,
    input_channel = state.input_channel,
    output_channel = state.output_channel,
  }
  local filepath = _path.data .. "filtr/preset.lua"
  tab.save(preset, filepath)
  popup_param = "PRESET"
  popup_val = "Saved!"
  popup_time = util.time()
end

local function load_preset()
  ensure_preset_dir()
  local filepath = _path.data .. "filtr/preset.lua"
  local preset = tab.load(filepath)
  if preset then
    chain = preset.chain or {}
    chain_probs = preset.chain_probs or {}
    state.input_channel = preset.input_channel or 0
    state.output_channel = preset.output_channel or 0
    popup_param = "PRESET"
    popup_val = "Loaded!"
  else
    popup_param = "PRESET"
    popup_val = "Not found"
  end
  popup_time = util.time()
end

-- ──────────────────────────────────────────────
-- PARAMS (norns params system for MIDI ports)
-- ──────────────────────────────────────────────

local function setup_params()
  params:add_separator("filtr")
  params:add{
    type="number", id="midi_in_port",  name="MIDI in port",
    min=1, max=4, default=1,
    action=function(v)
      state.midi_in_port = v
      connect_midi()
    end
  }
  params:add{
    type="number", id="midi_out_port", name="MIDI out port",
    min=1, max=4, default=2,
    action=function(v)
      state.midi_out_port = v
      connect_midi()
    end
  }

  -- Channel routing
  params:add{
    type="option", id="input_channel", name="Input channel",
    options={"all", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16"},
    default=1,
    action=function(v)
      state.input_channel = v == 1 and 0 or (v - 1)
    end
  }
  params:add{
    type="option", id="output_channel", name="Output channel",
    options={"same", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16"},
    default=1,
    action=function(v)
      state.output_channel = v == 1 and 0 or (v - 1)
    end
  }

  -- Chain slot probabilities (4 slots)
  for slot = 1, max_chain_slots do
    params:add{
      type="number", id="chain_prob_" .. slot, name="Chain " .. slot .. " prob %",
      min=0, max=100, default=100,
      action=function(v)
        chain_probs[slot] = v
      end
    }
  end
end

-- ──────────────────────────────────────────────
-- INIT
-- ──────────────────────────────────────────────

function init()
  math.randomseed(os.time())
  setup_params()
  params:read()
  params:bang()

  -- Connect grid
  g = grid.connect()
  if g then
    g.key = grid_key
  end

  connect_midi()
  redraw()
  grid_redraw()

  -- Redraw loop at ~10fps for beat pulse and MIDI activity
  clock.run(function()
    while true do
      clock.sleep(1/10)
      grid_redraw()
      redraw()
    end
  end)
end

function cleanup()
  clock.cancel_all()
  if g then g:all(0); g:refresh() end
  if midi_in then midi_in.event = nil end
  if midi_out then
    for ch = 1, 16 do
      midi_out:cc(123, 0, ch)
      midi_out:cc(120, 0, ch)
    end
  end
end
