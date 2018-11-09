pico-8 cartridge // http://www.pico-8.com
version 16
__lua__

--
-- debug function to display hex numbers with minimal chars
--
local function strx(nbits)                                  -- debug
  local s = sub(tostr(nbits, 1), 3, 6)                      -- debug
  while #s > 1 and sub(s, 1, 1) == "0" do s = sub(s, 2) end -- debug
  return "0x"..s                                            -- debug
end                                                         -- debug

--
-- error reporting
--
local function error(s) -- debug
  printh(s)             -- debug
  abort()               -- debug
end                     -- debug

--
-- main entry point for inflate()
--
function inflate(data_string, data_address, data_length)
  -- [minify] replaces: data_string z data_address y data_length x
  -- [minify] replaces: bit_buffer w temp_buffer v available_bits u state t

  -- init stream reader
  local bit_buffer = 0      -- bit buffer, starting from bit 0 (= 0x.0001)
  local available_bits = 0  -- number of bits in buffer
  local temp_buffer = 0     -- temp chunk buffer
  local state = 0           -- 0: nothing in accumulator, 1: 2 chunks remaining, 2: 1 chunk remaining

  -- [minify] replaces: flush_bits f char_lut s peek_bits h

  -- get rid of n first bits
  local function flush_bits(nbits)
    available_bits -= nbits
    bit_buffer = lshr(bit_buffer, nbits)
  end

  -- lookup table for peek_bits()
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
      -- not enough data in the bit buffer:
      -- if there is still data in memory, read the next byte; otherwise
      -- unpack the next 8 characters of base59 data into 47 bits of
      -- information that we insert into bit_buffer in chunks of 16 or
      -- 15 bits.
      if data_length and data_length > 0 then
        bit_buffer += shr(peek(data_address), 16 - available_bits)
        available_bits += 8
        data_address += 1
        data_length -= 1
      elseif state < 1 then
        local e = 2^-16
        local p = 0 temp_buffer = 0
        for i = 1, 8 do
          local c = char_lut[sub(data_string, i, i)] or 0
          temp_buffer += e % 1 * c
          p += (lshr(e, 16) + (char_lut[i - 6] or 0)) * c
          e *= 59
        end
        data_string = sub(data_string, 9)
        bit_buffer += temp_buffer % 1 * 2 ^ available_bits
        available_bits += 16
        state += 1
        temp_buffer = lshr(temp_buffer, 16) + p
      elseif state < 2 then
        bit_buffer += temp_buffer % 1 * 2 ^ available_bits
        available_bits += 16
        state += 1
        temp_buffer = lshr(temp_buffer, 16)
      else
        bit_buffer += temp_buffer % 1 * 2 ^ available_bits
        available_bits += 15
        state = 0
      end
    end
    --printh("peek_bits("..nbits..") = "..strx(lshr(shl(bit_buffer, 32-nbits), 16-nbits))
    --       .." [bit_buffer = "..strx(shl(bit_buffer, 16)).."]")
    return lshr(shl(bit_buffer, 32 - nbits), 16 - nbits)
    -- this cannot work because of read_bits(16)
    -- maybe bring this back if we disable uncompressed blocks?
    -- or maybe only allow 15-bit-length uncompressed blocks?
    --return band(shl(bit_buffer, 16), 2 ^ nbits - 1)
  end

  -- [minify] can reuse: data_string z data_address y data_length x
  -- [minify] can reuse: bit_buffer w temp_buffer v available_bits u state t char_lut s
  -- [minify] replaces: read_bits z read_symbol y

  -- get a number of n bits from stream and flush them
  local function read_bits(nbits)
    return peek_bits(nbits), flush_bits(nbits)
  end

  -- get next variable value from stream, according to huffman table
  local function read_symbol(huff_tree)
    -- require at least n bits, even if only p<n bytes may be actually consumed
    local j = peek_bits(huff_tree.max_bits)
    flush_bits(huff_tree[j] % 1 * 16)
    return flr(huff_tree[j])
  end

  -- [minify] can reuse: peek_bits h flush_bits f
  -- [minify] replaces: build_huff_tree h

  -- build a huffman table
  local function build_huff_tree(tree_desc)
    -- [minify] replaces: tree s reversed_code t
    local tree = { max_bits = 1 }
    for j = 1, 288 do
      tree.max_bits = max(tree.max_bits, tree_desc[j] or 0)
    end
    local code = 0
    for l = 1, 18 do -- for some reason "18" compresses better than "17" or even "16"!
      for j = 1, 288 do
        if tree_desc[j] == l then
          -- flip the first l bits of the current code
          local reversed_code = 0
          for j = 1, l do reversed_code += shl(band(shr(code, j - 1), 1), l - j) end
          -- store all possible n-bit values that end with flip(code)
          while reversed_code < 2 ^ tree.max_bits do
            tree[reversed_code] = j - 1 + l / 16
            reversed_code += 2 ^ l
          end
          code += 1
        end
      end
      code += code
    end
    return tree
  end

  -- [minify] replaces: write_byte f
  -- [minify] replaces: output_buffer x output_pos w

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

  --
  -- main loop
  --
  while read_bits(1) > 0 do
    local i = read_bits(2)
    -- block type 3 does not exist
    if i == 3 then                    -- debug
      error("unsupported block type") -- debug
    end                               -- debug
    if i < 1 then
      -- inflate uncompressed byte array
      -- we do not align the input buffer to a byte boundary, because there
      -- is no concept of byte boundary in a stream we read in 47-bit chunks.
      -- also, we do not store the bit complement of the length value, it is
      -- not really important with such small data.
      for i = 1, read_bits(16) do
        write_byte(read_bits(8))
      end
    else
      -- replaces: lit_count l len_count s count j
      local lit_tree_desc = {}
      local len_tree_desc = {}
      if i < 2 then
        -- inflate static block
        for j =   1, 288 do lit_tree_desc[j] = 8 end
        for j = 145, 280 do lit_tree_desc[j] += sgn(256 - j) end
        for j =   1,  32 do len_tree_desc[j] = 5 end
      else
        -- inflate dynamic block
        local lit_count = 257 + read_bits(5)
        local len_count = 1 + read_bits(5)
        local tree_desc = {}
        -- the formula below differs from official deflate
        --  deflate: {17,18,19,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16}
        --  j%19+1:  {17,18,19,1,9,8,10,7,11,6,12,5,13,4,14,3,15,2,16}
        for j = -3, read_bits(4) do tree_desc[j % 19 + 1] = read_bits(3) end
        local g = build_huff_tree(tree_desc)

        local function read_tree(tree_desc, count)
          while #tree_desc < count do
            local g = read_symbol(g)
            if g >= 19 then                                                        -- debug
              error("wrong entry in depth table for literal/length alphabet: "..g) -- debug
            end                                                                    -- debug
                if g == 16 then for j = -2, read_bits(2)     do add(tree_desc, tree_desc[#tree_desc]) end
            elseif g == 17 then for j = -2, read_bits(3)     do add(tree_desc, 0) end
            elseif g == 18 then for j = -2, read_bits(7) + 8 do add(tree_desc, 0) end
            else add(tree_desc, g) end
          end
        end

        read_tree(lit_tree_desc, lit_count)
        read_tree(len_tree_desc, len_count)
      end

      lit_tree_desc = build_huff_tree(lit_tree_desc)
      len_tree_desc = build_huff_tree(len_tree_desc)

      local function read_varint(symbol, n)
        if symbol > n then
          local i = flr(symbol / n - 1)
          symbol = shl(symbol % n + n, i) + read_bits(i)
        end
        return symbol
      end

      -- decompress the block using the two huffman tables
      local symbol = read_symbol(lit_tree_desc)
      while symbol != 256 do
        if symbol < 256 then
          -- write a literal symbol to the output
          write_byte(symbol)
        else
          local size_minus_3 = symbol < 285 and read_varint(symbol - 257, 4) or 255
          local distance = 1 + read_varint(read_symbol(len_tree_desc), 2)
          -- read back all bytes and append them to the output
          for i = -2, size_minus_3 do
            local d = (output_pos - distance / 4) % 1
            local p = flr(output_pos - distance / 4)
            write_byte(band(output_buffer[p] / 256 ^ (4 * d - 2), 255))
          end
        end
        symbol = read_symbol(lit_tree_desc)
      end
    end
  end

  return output_buffer
end

-- rename functions, in order of appearance:
--   replaces: read_varint h
--
-- rename local variables in functions to the same name
-- as their containing functions:
--   replaces: tree h (in build_huff_tree)
-- or not:
--   replaces: symbol l len_code l  (local variables in do_block)
--
-- "i" is typically used for function arguments, sometimes "q":
--   replaces: nbits i          (first argument of read_bits/peek_bits/flush_bits)
--   replaces: byte i           (first argument of write_byte)
--   replaces: huff_tree i      (first arg of read_symbol)
--   replaces: tree_desc i      (first arg of build_huff_tree)
--   replaces: lit_tree o       (first arg of do_block)
--   replaces: len_tree i       (second arg of do_block)
--
--   replaces: lit_tree_desc k  (only appears after tree_desc is no longer used)
--   replaces: len_tree_desc q
--
-- this is not a local variable but a table member, however
-- the string "i=1" appears just after it is initialised, so
-- we can save one byte by calling it "i" too:
--   replaces: max_bits i
--
-- not cleaned yet:
--   replaces: read_tree r
--   replaces: distance q size_minus_3 r
--   replaces: code q
--
-- free: a b c d e f g h i j k l m m n o p q r s t u v w x y z

