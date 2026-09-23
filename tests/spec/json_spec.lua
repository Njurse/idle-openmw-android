-- tests/spec/json_spec.lua
-- The JSON codec (scripts/idle/json.lua) behind the bridge (docs/bridge-api.md).
--
-- The codec is small but load-bearing: a host parses what it emits, so the wire format is a
-- contract. Deterministic key order is part of that contract, not a nicety -- without it a
-- host cannot diff two responses to see whether the world changed.
describe('idle.json', function()
  local json = require('scripts.idle.json')

  describe('encode', function()
    it('encodes the scalars', function()
      assert.equals('true', json.encode(true))
      assert.equals('false', json.encode(false))
      assert.equals('42', json.encode(42))
      assert.equals('"text"', json.encode('text'))
      assert.equals('null', json.encode(nil))
    end)

    it('encodes integers without a decimal point', function()
      assert.equals('7', json.encode(7))
      assert.equals('-3', json.encode(-3))
      assert.equals('0', json.encode(0))
    end)

    it('escapes the characters that would break the line protocol', function()
      -- a raw newline or quote would corrupt the line the host parses
      assert.equals('"a\\nb"', json.encode('a\nb'))
      assert.equals('"a\\"b"', json.encode('a"b'))
      assert.equals('"a\\\\b"', json.encode('a\\b'))
    end)

    it('encodes arrays in order', function()
      assert.equals('[1,2,3]', json.encode({ 1, 2, 3 }))
      assert.equals('{"a":1}', json.encode({ a = 1 }))
    end)

    it('encodes an EMPTY table as an object, because Lua tables are maps first', function()
      -- documented in json.lua: an empty table makes no claim to be a sequence
      assert.equals('{}', json.encode({}))
    end)

    it('encodes objects with SORTED keys, so output is stable', function()
      -- the same table must always produce the same bytes
      assert.equals('{"a":1,"b":2,"c":3}', json.encode({ c = 3, a = 1, b = 2 }))
      assert.equals(json.encode({ x = 1, y = 2 }), json.encode({ y = 2, x = 1 }))
    end)

    it('nests', function()
      assert.equals('{"list":[{"k":1}],"total":1}',
        json.encode({ total = 1, list = { { k = 1 } } }))
    end)

    it('turns NaN and infinities into null rather than emitting invalid JSON', function()
      assert.equals('null', json.encode(0 / 0))
      assert.equals('null', json.encode(1 / 0))
    end)

    it('renders engine objects (userdata) as a marker instead of failing', function()
      -- engine values are userdata in 0.51 and cannot be serialised
      local fake = newproxy and newproxy(false) or nil
      if fake then assert.equals('"<userdata>"', json.encode(fake)) end
    end)
  end)

  describe('decode', function()
    it('round-trips what encode produced', function()
      local value = { id = 7, method = 'cell.current', params = { radius = 512, deep = { 1, 2 } } }
      local decoded, err = json.decode(json.encode(value))
      assert.is_nil(err)
      assert.equals('cell.current', decoded.method)
      assert.equals(7, decoded.id)
      assert.equals(512, decoded.params.radius)
      assert.equals(2, decoded.params.deep[2])
    end)

    it('decodes the request shape a host sends', function()
      local request, err = json.decode('{"id":4,"method":"entities.nearby","params":{"radius":256}}')
      assert.is_nil(err)
      assert.equals(4, request.id)
      assert.equals('entities.nearby', request.method)
      assert.equals(256, request.params.radius)
    end)

    it('rejects malformed input with a reason', function()
      local value, err = json.decode('{oops')
      assert.is_nil(value)
      assert.is_not_nil(err)
    end)

    it('rejects trailing junk rather than silently ignoring it', function()
      local value = json.decode('{"a":1} trailing')
      assert.is_nil(value)
    end)

    it('reports empty input', function()
      local value, err = json.decode('   ')
      assert.is_nil(value)
      assert.equals('empty', err)
    end)

    it('handles escapes and booleans', function()
      local decoded = json.decode('{"a":"x\\ny","b":true,"c":null}')
      assert.equals('x\ny', decoded.a)
      assert.equals(true, decoded.b)
      assert.is_nil(decoded.c)
    end)
  end)
end)
