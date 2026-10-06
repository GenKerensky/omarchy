#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command lua
require_command node

# Execute the real Lua config with a recording o.window, then evaluate its
# captured regex selectors in Node. Lua patterns are not Hyprland regexes.
rules=$(lua <<'LUA'
local function json(value)
  if type(value) == "string" then
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  elseif type(value) == "boolean" or type(value) == "number" then
    return tostring(value)
  elseif type(value) == "table" then
    local parts = {}
    if #value > 0 then
      for _, item in ipairs(value) do
        table.insert(parts, json(item))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
      table.insert(parts, json(key) .. ":" .. json(item))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("unsupported captured value: " .. type(value))
end

o = {
  window = function(match, effects)
    if type(match) == "string" then
      match = { class = match }
    end
    print(json({ match = match, effects = effects }))
  end,
}
dofile(os.getenv("ROOT") .. "/default/hypr/apps/system.lua")
LUA
)

NAUTILUS_WINDOW_RULES="$rules" run_node_test <<'JS'
const rules = process.env.NAUTILUS_WINDOW_RULES.trim().split('\n').map(JSON.parse)

// Hyprland uses full regex matches. These selectors use the common JS/RE2
// subset; this tests rule behavior, not compositor matching or modal detection.
function matches(selector, window) {
  return Object.entries(selector).every(([key, expected]) => {
    if (typeof expected === 'boolean') return window[key] === expected
    if (key === 'tag') return window.tags.has(expected)
    if (!['class', 'title'].includes(key)) fail('supported captured selector', key)
    return new RegExp(`^(?:${expected})$`).test(window[key] || '')
  })
}

function treatment(className, title, modal = false) {
  const window = { class: className, title, modal, tags: new Set() }
  // Resolve tag additions before the shared tag-based float/center/size rules.
  for (const { match, effects } of rules) {
    if (effects.tag === '+floating-window' && matches(match, window)) {
      window.tags.add('floating-window')
    }
  }
  const result = { tagged: window.tags.has('floating-window') }
  for (const { match, effects } of rules) {
    if (matches(match, window)) {
      for (const key of ['float', 'center', 'size']) {
        if (key in effects) result[key] = effects[key]
      }
    }
  }
  return result
}

const chooser = { tagged: true, float: true, center: true, size: [875, 600] }
assertDeepEqual(treatment('org.gnome.Nautilus', 'File Upload'), chooser,
  'Nautilus File Upload receives shared floating treatment without modal state')
assertDeepEqual(treatment('org.gnome.Nautilus', 'Select a document', true), chooser,
  'modal Nautilus chooser floats regardless of caller title')
assertDeepEqual(treatment('org.gnome.Nautilus', 'Datei auswählen', true), chooser,
  'modal Nautilus chooser floats with a localized title')
for (const title of ['Home', 'Documents', 'Downloads', 'Pictures', 'Select a document', 'File Uploads', 'My File Upload']) {
  assertDeepEqual(treatment('org.gnome.Nautilus', title), { tagged: false },
    `ordinary nonmodal Nautilus folder stays tiled: ${title}`)
}
assertDeepEqual(treatment('org.gnome.NautilusOther', 'File Upload', true), { tagged: false },
  'new chooser rules do not match other application classes')
assertDeepEqual(treatment('firefox', 'File Upload', true), { tagged: false },
  'new chooser rules do not float Firefox itself')
for (const [className, title] of [
  ['org.gnome.Nautilus', 'Open File'],
  ['sublime_text', 'Save As'],
  ['DesktopEditors', 'Choose File'],
  ['xdg-desktop-portal-gtk', 'Select a document'],
]) {
  assertDeepEqual(treatment(className, title), chooser,
    `existing floating chooser treatment remains effective: ${className} / ${title}`)
}
JS
