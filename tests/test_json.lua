-- Regression tests for What Is This Thing.lrplugin/JSON.lua
-- Run with: lua tests/test_json.lua

local function scriptDir()
    local source = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
    return source:match("(.*/)") or "./"
end

local JSON = dofile(scriptDir() .. "../What Is This Thing.lrplugin/JSON.lua")

local sample = [[
{
  "query": {"project": "all", "images": ["abc.jpg"]},
  "results": [
    {
      "score": 0.8834,
      "species": {
        "scientificNameWithoutAuthor": "Trifolium repens",
        "scientificNameAuthorship": "L.",
        "genus": {"scientificNameWithoutAuthor": "Trifolium"},
        "family": {"scientificNameWithoutAuthor": "Fabaceae"},
        "commonNames": ["White clover", "Dutch clover"]
      },
      "gbif": {"id": "2966853"},
      "images": []
    },
    {
      "score": 0.0523,
      "species": {
        "scientificNameWithoutAuthor": "Trifolium pratense",
        "commonNames": []
      }
    }
  ],
  "version": "2025-01-01 (7.3)",
  "remainingIdentificationRequests": 499,
  "language": "en",
  "preferedReferential": "k-world-flora",
  "bestMatch": "Trifolium repens L."
}
]]

local decoded = JSON.decode(sample)

assert(decoded.results[1].species.scientificNameWithoutAuthor == "Trifolium repens")
assert(math.abs(decoded.results[1].score - 0.8834) < 1e-9)
assert(decoded.results[1].species.commonNames[1] == "White clover")
assert(decoded.results[2].species.commonNames ~= nil and #decoded.results[2].species.commonNames == 0)
assert(decoded.remainingIdentificationRequests == 499)
assert(decoded.bestMatch == "Trifolium repens L.")

print("PlantNet-shaped response: OK")

-- extra coverage: booleans, null, empty object, escapes, exponent numbers
local extra = JSON.decode([[
{
  "a": true,
  "b": false,
  "c": null,
  "d": {},
  "e": [1, 2.5e2, -3],
  "f": "line1\nline2\ttab\\slash\"quote",
  "g": []
}
]])
assert(extra.a == true)
assert(extra.b == false)
assert(extra.c == nil)
assert(type(extra.d) == "table")
assert(extra.e[1] == 1 and extra.e[2] == 250 and extra.e[3] == -3)
assert(extra.f == "line1\nline2\ttab\\slash\"quote")
assert(type(extra.g) == "table" and #extra.g == 0)

print("Edge cases (bool/null/escapes/exponents): OK")
print("All JSON decoder tests passed")
