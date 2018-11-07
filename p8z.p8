pico-8 cartridge // http://www.pico-8.com
version 16
__lua__

function inflate(data_string, data_address, data_length)
  -- init stream reader
  local state = 0           -- 0: nothing in accumulator, 1: 2 chunks remaining, 2: 1 chunk remaining
  local bit_buffer = 0      -- bit buffer, starting from bit 0 (= 0x.0001)
  local available_bits = 0  -- number of bits in buffer
  local temp_buffer = 0     -- temp chunk buffer

  -- get rid of n first bits
  local function flush_bits(nbits)
    available_bits -= nbits
    bit_buffer = lshr(bit_buffer, nbits)
  end

  -- debug function to display hex numbers with minimal chars
  local function strx(nbits)                                  -- debug
    local s = sub(tostr(nbits, 1), 3, 6)                      -- debug
    while #s > 1 and sub(s, 1, 1) == "0" do s = sub(s, 2) end -- debug
    return "0x"..s                                            -- debug
  end                                                         -- debug

  -- handle error reporting
  local function error(s) -- debug
    printh(s)             -- debug
    abort()               -- debug
  end                     -- debug

  -- init lookup table for peek_bits()
  --  - indices 1 and 2 are the higher bits (>=32) of 59^7 and 59^8
  --    used to compute these powers
  --  - string indices are for char -> byte lookups; the order in the
  --    base string is not important but we exploit it to make our
  --    compressed code shorter
  local char_lut = { 9, 579 }
  for i = 1, 58 do char_lut[sub("y={9,570123468functio[lshrabdegjkmpqvwxz!#%()]}<>+/*:;.~_ ", i, i)] = i end

  -- peek n bits from the stream
  local function peek_bits(nbits)
    -- we need "while" instead of "do" because when reading
    -- from memory we may need more than one 8-bit run.
    while available_bits < nbits do
      -- not enough data in the stream:
      -- if there is still data in memory, read the next byte; otherwise
      -- unpack the next 8 characters of base59 data into 47 bits of
      -- information that we insert into bit_buffer in chunks of 16 or
      -- 15 bits.
      if data_length and data_length > 0 then
        bit_buffer += shr(peek(data_address), 16 - available_bits)
        available_bits += 8
        data_address += 1
        data_length -= 1
      elseif state == 0 then
        local e = 2^-16
        local data_address = 0 temp_buffer = 0
        for i = 1, 8 do
          local c = char_lut[sub(data_string, i, i)] or 0
          temp_buffer += e % 1 * c
          data_address += (lshr(e, 16) + (char_lut[i - 6] or 0)) * c
          e *= 59
        end
        data_string = sub(data_string, 9)
        bit_buffer += temp_buffer % 1 * 2 ^ available_bits
        available_bits += 16
        state += 1
        temp_buffer = data_address + shr(temp_buffer, 16)
      elseif state == 1 then
        bit_buffer += temp_buffer % 1 * 2 ^ available_bits
        available_bits += 16
        state += 1
      else
        bit_buffer += lshr(temp_buffer, 16) * 2 ^ available_bits
        available_bits += 15
        state = 0
      end
    end
    --printh("peek_bits("..nbits..") = "..strx(lshr(shl(bit_buffer, 32-nbits), 16-nbits))
    --       .." [bit_buffer = "..strx(shl(bit_buffer, 16)).."]")
    return lshr(shl(bit_buffer, 32 - nbits), 16 - nbits)
    -- this cannot work because of get_bits(16)
    -- maybe bring this back if we disable uncompressed blocks?
    --return band(shl(bit_buffer, 16), 2 ^ nbits - 1)
  end

  -- get a number of n bits from stream and flush them
  local function get_bits(nbits)
    return peek_bits(nbits), flush_bits(nbits)
  end

  -- get next variable value from stream, according to huffman table
  local function get_symbol(huff_tree)
    -- require at least n bits, even if only p<n bytes may be actually consumed
    local j = peek_bits(huff_tree.max_bits)
    flush_bits(huff_tree[j] % 1 * 16)
    return flr(huff_tree[j])
  end

  -- build a huffman table
  local function build_huff_tree(tree_desc)
    local tree = { max_bits = 1 }
    -- fill c with the bit length counts
    local c = {}
    for j = 1, 17 do
      c[j] = 0
    end
    for j = 1, #tree_desc do
      -- fixme: get rid of the local?
      local n = tree_desc[j]
      tree.max_bits = max(tree.max_bits, n)
      c[n+1] += 2 -- premultiply by 2
    end
    -- replace the contents of c with the next code lengths
    c[1] = 0
    for j = 2, tree.max_bits do
      c[j] += c[j-1]
      c[j] += c[j-1]
    end
    -- fill tree with the possible codes, pre-flipped so that we do not
    -- have to reverse every chunk we read.
    for j = 1, #tree_desc do
      local l = tree_desc[j]
      if l > 0 then
        -- flip the first l bits of c[l]
        local code = 0
        for j = 1, l do code += shl(band(shr(c[l], j - 1), 1), l - j) end
        -- store all possible n-bit values that end with flip(c[l])
        while code < 2 ^ tree.max_bits do
          tree[code] = j - 1 + l / 16
          code += 2 ^ l
        end
        -- point to next code of length l
        c[l] += 1
      end
    end
    return tree
  end

  -- init stream writer
  local output_buffer = {} -- output array (32-bit numbers)
  local output_pos = 1     -- output position, only used in write_byte() and do_block()

  -- write_byte 8 bits to the output, packed into a 32-bit number
  local function write_byte(byte)
    local d = (output_pos) % 1  -- the parentheses here help compressing the code!
    local p = flr(output_pos)
    output_buffer[p] = byte * 256 ^ (4 * d - 2) + (output_buffer[p] or 0)
    output_pos += 1 / 4
  end

  -- decompress a block using the two huffman tables
  local function do_block(lit_tree, len_tree)

    local function get_int(symbol, n)
      if symbol > n then
        local i = flr(symbol / n - 1)
        symbol = shl(symbol % n + n, i) + get_bits(i)
      end
      return symbol
    end

    local symbol = get_symbol(lit_tree)
    while symbol != 256 do
      if symbol < 256 then
        write_byte(symbol)
      else
        local size = symbol < 285 and get_int(symbol - 257, 4) or 255
        local distance = 1 + get_int(get_symbol(len_tree), 2)
        for i = -2, size do
          -- read back one byte and append it to the output
          local d = (output_pos - distance / 4) % 1
          local p = flr(output_pos - distance / 4)
          write_byte(band(output_buffer[p] / 256 ^ (4 * d - 2), 255))
        end
      end
      symbol = get_symbol(lit_tree)
    end
  end

  local methods = {}

  -- inflate dynamic block
  methods[2] = function()
    -- replaces: lit_count l len_count y count l desc_len k
    local lit_count = 257 + get_bits(5)
    local len_count = 1 + get_bits(5)
    -- fixme: maybe this can be removed when build_huff_tree accepts sparse tables
    local tree_desc = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
    -- the formula below differs from the original deflate
    for j = -3, get_bits(4) do tree_desc[j % 19 + 1] = get_bits(3) end
    local z = build_huff_tree(tree_desc)

    local function read_tree(count)
      local tree_desc = {}
      while #tree_desc < count do
        local v = get_symbol(z)
        if v >= 19 then                                                        -- debug
          error("wrong entry in depth table for literal/length alphabet: "..v) -- debug
        end                                                                    -- debug
            if v == 16 then for j = -2, get_bits(2)     do add(tree_desc, tree_desc[#tree_desc]) end
        elseif v == 17 then for j = -2, get_bits(3)     do add(tree_desc, 0) end
        elseif v == 18 then for j = -2, get_bits(7) + 8 do add(tree_desc, 0) end
        else add(tree_desc, v) end
      end
      return build_huff_tree(tree_desc)
    end

    do_block(read_tree(lit_count), read_tree(len_count))
  end

  -- inflate static block
  methods[1] = function()
    local lit_tree_desc = {}
    local len_tree_desc = {}
    for j = 1, 288 do lit_tree_desc[j] = 8 end
    for j = 145, 280 do lit_tree_desc[j] += sgn(256 - j) end
    for j = 1, 32 do len_tree_desc[j] = 5 end
    do_block(build_huff_tree(lit_tree_desc),
             build_huff_tree(len_tree_desc))
  end

  -- inflate uncompressed byte array
  methods[0] = function()
    -- we do not align the input buffer to a byte boundary, because there
    -- is no concept of byte boundary in a stream we read in 47-bit chunks.
    -- also, we do not store the bit complement of the length value, it is
    -- not really important with such small data.
    for i = 1, get_bits(16) do
      write_byte(get_bits(8))
    end
  end

  -- block type 3 does not exist
  methods[3] = function()           -- debug
    error("unsupported block type") -- debug
  end                               -- debug

  while get_bits(1) > 0 do
    methods[get_bits(2)]()
  end
  flush_bits(available_bits % 8)  -- debug (no need to flush!)

  return output_buffer
end

-- strategy for minifying (renaming variables):
--
--   replaces: data_string s data_address p data_length l
--
-- rename functions, in order of appearance:
--   replaces: flush_bits f
--   replaces: peek_bits h
--   replaces: get_bits x
--   replaces: get_symbol u
--   replaces: write_byte w
--   replaces: build_huff_tree h  (no conflict with peek_bits)
--   replaces: do_block b         (todo)
--
-- rename local variables in functions to the same name
-- as their containing functions:
--   replaces: tree h (in build_huff_tree)
-- or not:
--   replaces: symbol l len_code l  (local variables in do_block)
--
-- first, we rename some internal variables:
--   replaces: char_lut y methods y  (no conflict)
--   replaces: state x               (valid because always used before get_bits)
--   replaces: bit_buffer w          (valid because always used before write_byte)
--   replaces: temp_buffer v
--   replaces: available_bits u      (valid because always used before get_symbol)
--   replaces: output_pos g
--
-- "i" is typically used for function arguments, sometimes "q":
--   replaces: nbits i          (first argument of get_bits/peek_bits/flush_bits)
--   replaces: byte i           (first argument of write_byte)
--   replaces: huff_tree i      (first arg of get_symbol)
--   replaces: tree_desc i      (first arg of build_huff_tree)
--   replaces: lit_tree_desc i  (only appears after tree_desc is no longer used)
--   replaces: len_tree_desc q
--   replaces: lit_tree o       (first arg of do_block)
--   replaces: len_tree i       (second arg of do_block)
--
-- this is not a local variable but a table member, however
-- the string "i=1" appears just after it is initialised, so
-- we can save one byte by calling it "i" too:
--   replaces: max_bits i
--
-- we can also rename this because "j" is only used as
-- a local variable in functions that do not use output_buffer:
--   replaces: output_buffer j
--
-- not cleaned yet:
--   replaces: read_tree r get_int q
--   replaces: distance q size r
--   replaces: code o c1 m
--
-- free: l z

