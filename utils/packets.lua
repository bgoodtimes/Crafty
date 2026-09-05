local bit = require('bit')

-- Trimmed copy of xitools' packet parsers - only the synth-related packets that
-- crafty needs. Originally by lin.

local outboundStartSynth = {
    id = 0x096,
    name = 'Start Synth',
    parse = function(packet)
        local startSynth = {
            crystal = struct.unpack('H', packet, 0x06 + 1),
            crystalIdx = struct.unpack('B', packet, 0x08 + 1),
            ingredientCount = struct.unpack('B', packet, 0x09 + 1),
            ingredient = {},
            ingredientIdx = {},
        }

        for i=0, 7 do
            startSynth.ingredient[i] = struct.unpack('H', packet, 0x0A + (i * 2) + 1)
        end

        for i=0, 7 do
            startSynth.ingredientIdx[i] = struct.unpack('B', packet, 0x1A + (i * 2) + 1)
        end

        return startSynth
    end,
}

local inboundBasic = {
    id = 0x029,
    name = 'Basic',
    ---@param packet string
    parse = function(packet)
        local basic = {
            sender     = struct.unpack('i4', packet, 0x04 + 1),
            target     = struct.unpack('i4', packet, 0x08 + 1),
            param      = struct.unpack('i4', packet, 0x0C + 1),
            value      = struct.unpack('i4', packet, 0x10 + 1),
            sender_tgt = struct.unpack('i2', packet, 0x14 + 1),
            target_tgt = struct.unpack('i2', packet, 0x16 + 1),
            message    = struct.unpack('i2', packet, 0x18 + 1),
        }

        return basic
    end
}

local inboundSynthAnimation = {
    id = 0x030,
    name = 'Synth Animation',
    ---@param packet string
    parse = function(packet)
        local synthAnimation = {
            player = struct.unpack('I4', packet, 0x04 + 1),
            playerIdx = struct.unpack('H', packet, 0x08 + 1),
            effect = struct.unpack('H', packet, 0x0A + 1),
            param = struct.unpack('B', packet, 0x0C + 1),
            animation = struct.unpack('B', packet, 0x0D + 1),
        }

        return synthAnimation
    end
}

local inboundSynthResultPlayer = {
    id = 0x06F,
    name = 'Self Synth',
    ---@param packet string
    parse = function(packet)
        local selfSynth = {
            result = struct.unpack('B', packet, 0x04 + 1),
            quality = struct.unpack('b', packet, 0x05 + 1),
            count = struct.unpack('B', packet, 0x06 + 1),
            item = struct.unpack('H', packet, 0x08 + 1),
            lost = {
                [1] = struct.unpack('H', packet, 0x0A + 1),
                [2] = struct.unpack('H', packet, 0x0C + 1),
                [3] = struct.unpack('H', packet, 0x0E + 1),
                [4] = struct.unpack('H', packet, 0x10 + 1),
                [5] = struct.unpack('H', packet, 0x12 + 1),
                [6] = struct.unpack('H', packet, 0x14 + 1),
                [7] = struct.unpack('H', packet, 0x16 + 1),
                [8] = struct.unpack('H', packet, 0x18 + 1),
            },
            skill = {
                {
                    skillId = bit.band(struct.unpack('B', packet, 0x1A + 1), 63),
                    isSkillupAllowed = bit.band(struct.unpack('B', packet, 0x1A + 1), 40) == 40,
                    isDesynth = bit.band(struct.unpack('B', packet, 0x1A + 1), 80) == 80,
                },
                {
                    skillId = bit.band(struct.unpack('B', packet, 0x1B + 1), 63),
                    isSkillupAllowed = bit.band(struct.unpack('B', packet, 0x1B + 1), 40) == 40,
                    isDesynth = bit.band(struct.unpack('B', packet, 0x1B + 1), 80) == 80,
                },
                {
                    skillId = bit.band(struct.unpack('B', packet, 0x1C + 1), 63),
                    isSkillupAllowed = bit.band(struct.unpack('B', packet, 0x1C + 1), 40) == 40,
                    isDesynth = bit.band(struct.unpack('B', packet, 0x1C + 1), 80) == 80,
                },
                {
                    skillId = bit.band(struct.unpack('B', packet, 0x1D + 1), 63),
                    isSkillupAllowed = bit.band(struct.unpack('B', packet, 0x1D + 1), 40) == 40,
                    isDesynth = bit.band(struct.unpack('B', packet, 0x1D + 1), 80) == 80,
                },
            },
            skillup = {
                [1] = struct.unpack('B', packet, 0x1E + 1),
                [2] = struct.unpack('B', packet, 0x1F + 1),
                [3] = struct.unpack('B', packet, 0x20 + 1),
                [4] = struct.unpack('B', packet, 0x21 + 1),
            },
            crystal = struct.unpack('H', packet, 0x22 + 1),
        }

        return selfSynth
    end
}

local packets = {
    outbound = {
        startSynth = outboundStartSynth,
    },
    inbound = {
        basic = inboundBasic,
        synthAnimation = inboundSynthAnimation,
        synthResultPlayer = inboundSynthResultPlayer,
    },
}

return packets
