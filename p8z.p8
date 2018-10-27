pico-8 cartridge // http://www.pico-8.com
version 16
__lua__

function inflate(data)
  local reverse = {}

  -- init reverse array
  for i=0,255 do
    local k=0
    for j=0,7 do k+=band(i,2^j)*128/4^j end
    reverse[i] = k
  end

  local pos = 1     -- input char buffer index
  local sb = 0      -- bit buffer, starting from bit 0 (= 0x.0001)
  local sn = 0      -- number of bits in buffer
  local out = {}    -- output array
  local outpos = 0  -- output position

  -- get rid of n first bits
  local function flb(n)
    sn -= n
    sb = shr(sb,n)
  end

  local function pkb(n)
    while sn < n do
      sb += shr(data[pos],16-sn)
      pos += 1
      sn += 8
    end
    return band(shl(sb,16),2^n-1)
  end

  -- get a number of n bits from stream
  local function getb(n)
    return pkb(n),flb(n)
  end

  -- get next variable value from stream, according to huffman table
  local function getv(t)
    -- require at least n bits, even if only p<n bytes may be actually consumed
    pkb(t.nbits)
    -- reverse using a 16-bit word
    -- fixme: maybe we could get rid of reversing in the encoder?
    local h = reverse[band(shl(sb,16),255)]
    local l = reverse[band(shl(sb,8),255)]
    local v = band(shr(256*h+l,16-t.nbits),2^t.nbits-1)
    flb(t[v]%16)
    return flr(t[v]/16)
  end

  local function write(n)
    local d = (outpos)%1  -- the parentheses here help compressing the code!
    local p = flr(outpos)
    out[p]=n*256^(4*d-2)+(out[p]or 0)
    outpos+=1/4
  end

  local function readback(p)
    local d = (outpos+p/4)%1
    local p = flr(outpos+p/4)
    return band(out[p]/256^(4*d-2),255)
  end

  -- build a huffman table
  local function mkhuf(d)
    local bl_count = {}
    local t = {nbits=1}
    for i=1,17 do
      bl_count[i] = 0
    end
    for i=1,#d do
      local n = d[i]
      t.nbits = max(t.nbits,n)
      bl_count[n+1] += 2
    end
    local code = 0
    local next_code = {}
    for i=1,t.nbits do
      next_code[i] = code
      code += code + bl_count[i+1]
    end
    for i=1,#d do
      local len = d[i]
      if len > 0 then
        local code0 = shl(next_code[len],t.nbits-len)
        next_code[len] += 1
        local code1 = shl(next_code[len],t.nbits-len)
        if code1 > shl(1,t.nbits) then -- debug
          error("code error")          -- debug
        end                            -- debug
        for j=code0,code1-1 do
          t[j] = (i-1)*16 + len
        end
      end
    end
    return t
  end

  local function do_block(t1,t2)
    local lit
    repeat
      lit = getv(t1)
      if lit < 256 then
        write(lit)
      elseif lit > 256 then
        lit -= 257
        local nbits = 0
        local size = 3
        local dist = 1
        if lit < 8 then
          size += lit
        elseif lit < 28 then
          nbits = flr(lit/4-1)
          size += shl(lit%4+4,nbits)
          size += getb(nbits)
        else
          size = 258
        end
        local v = getv(t2)
        if v < 4 then
          dist += v
        else
          nbits = flr(v/2-1)
          dist += shl(v%2+2,nbits)
          dist += getb(nbits)
        end
        for n = 1,size do
          write(readback(-dist))
        end
      end
    until lit == 256
  end

  local methods = {}

  -- inflate dynamic block
  methods[2] = function()
    local d = {}
    local hlit = 257 + getb(5)
    local hdist = 1 + getb(5)
    local hclen = 4 + getb(4)
    for i=1,19 do
      -- the formula below differs from the original deflate
      d[(i+15)%19+1] = i>hclen and 0 or getb(3)
    end
    local t = mkhuf(d)
    d = {}
    local d2 = {}
    local c = 0
    while #d+#d2<hlit+hdist do
      local v = getv(t)
      if v >= 19 then                                                        -- debug
        error("wrong entry in depth table for literal/length alphabet: "..v) -- debug
      end                                                                    -- debug
      if v < 16 then
        c = v
        add(#d<hlit and d or d2,c)
      else
        local nbt = {2,3,7}
        local n = 3 + getb(nbt[v-15])
        if v != 16 then
          c = 0
        end
        if v == 18 then
          n += 8
        end
        for j=1,n do
          add(#d<hlit and d or d2,c)
        end
      end
    end
    do_block(mkhuf(d),mkhuf(d2))
  end

  -- inflate static block
  methods[1] = function()
    local d = {}
    for i=1,288 do d[i]=8 end
    for i=145,280 do d[i]+=sgn(256-i) end
    local d2 = {}
    for i=1,32 do d2[i]=5 end
    do_block(mkhuf(d),mkhuf(d2))
  end

  -- inflate uncompressed byte array
  methods[0] = function()
    -- align input buffer to byte (as per spec)
    -- fixme: we could omit this!
    flb(sn%8)
    local len = getb(16)
    if sn > 0 then                                                   -- debug
      error("unexpected.. should be zero remaining bits in buffer.") -- debug
    end                                                              -- debug
    local nlen = getb(16)
    if bxor(len,nlen) != 0xffff then    -- debug
      error("len and nlen don't match") -- debug
    end                                 -- debug
    for i=0,len-1 do
      write(data[pos+i])
    end
    pos += len
  end

  -- block type 3 does not exist
  methods[3] = function()           -- debug
    error("unsupported block type") -- debug
  end                               -- debug

  repeat
    local last = getb(1)
    methods[getb(2)]()
  until last == 1
  flb(sn%8)  -- debug (no need to flush!)

  return out
end

