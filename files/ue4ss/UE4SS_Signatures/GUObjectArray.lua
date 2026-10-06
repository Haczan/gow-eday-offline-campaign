-- GoW E-Day Steam, UE 5.6. Anchored in UObjectBase::AddObject.
-- The global holds an XOR-encoded FUObjectArray pointer, not an inline array.

local function ReadUInt64(Address)
    local Low = DerefToInt32(Address) & 0xFFFFFFFF
    local High = DerefToInt32(Address + 4) & 0xFFFFFFFF
    return Low | (High << 32)
end

function Register()
    return "0F BA EF 19 83 E0 FB 89 46 ?? 48 8B 0D ?? ?? ?? ?? 48 BB ?? ?? ?? ?? ?? ?? ?? ?? 48 33 CB 75 ?? B9 B8 00 00 00"
end

function OnMatchFound(MatchAddress)
    -- Verify the allocation call and its independent function entry before
    -- reading the singleton. A changed caller layout must fail closed.
    if (DerefToInt32(MatchAddress + 0x5C) & 0xFFFFFFFF) ~= 0xE8D68B48 then
        return nil
    end
    local AllocateCall = MatchAddress + 0x5F
    local AllocateObjectIndex = AllocateCall + 5 + DerefToInt32(AllocateCall + 1)
    if (DerefToInt32(AllocateObjectIndex) & 0xFFFFFFFF) ~= 0x245C8948
        or (DerefToInt32(AllocateObjectIndex + 5) & 0xFFFFFFFF) ~= 0x246C8948 then
        return nil
    end

    local EncodedPointerAddress = MatchAddress + 17 + DerefToInt32(MatchAddress + 13)
    local XorKey = ReadUInt64(MatchAddress + 19)
    local ObjectArray = ReadUInt64(EncodedPointerAddress) ~ XorKey

    -- The lazy singleton can still be uninitialized on an early scan.
    if ObjectArray < 0x10000 or ObjectArray > 0x00007FFFFFFFFFFF or (ObjectArray & 7) ~= 0 then
        return nil
    end
    return ObjectArray
end