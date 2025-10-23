-- Atlas for the deck
local up_atlas = SMODS.Atlas{
    key = 'Up Up Up',
    path = 'UpUpUp.png',
    atlas = 'Up Up Up',
    px = 68/2,
    py = 92/2,
}:register()

-- Atlas for the deck
local up_atlas = SMODS.Atlas{
    key = 'UpUpSleve',
    path = 'UpUpSleve.png',
    atlas = 'UpUpSleve',
    px = 73/2,
    py = 95/2,
}:register()

-- Config defaults
local cfg = SMODS.current_mod.config
if cfg.multiply_on_blind == nil then
    cfg.multiply_on_blind = false
end
if cfg.affect_probabilities == nil then
    cfg.affect_probabilities = false
end
cfg.multiplier_value = tonumber(cfg.multiplier_value) or 2
cfg.multiplier_value = math.max(0, math.min(10, cfg.multiplier_value))
cfg.multiplier_value = math.floor(cfg.multiplier_value * 2 + 0.5) / 2

-- Slider helpers
local function round_to_step(value, step, min_val)
    if not step or step <= 0 then
        return value
    end
    min_val = min_val or 0
    local units = (value - min_val) / step
    local rounded_units = math.floor(units + 0.5)
    return min_val + rounded_units * step
end

local function clamp(value, min_val, max_val)
    if value < min_val then
        return min_val
    end
    if value > max_val then
        return max_val
    end
    return value
end

local function enforce_slider_value(e, rt, callback_name, should_invoke_callback)
    if not (e and rt and rt.ref_table and rt.ref_value) then
        return false
    end

    local slider_bar = e.children and e.children[1]
    local min_val = rt.min or 0
    local max_val = rt.max or 1
    local decimals = tonumber(rt.decimal_places) or 0
    if decimals < 0 then
        decimals = 0
    end

    local current = rt.ref_table[rt.ref_value]
    if current == nil then
        return false
    end

    local stepped = round_to_step(current, rt.step, min_val)
    local new_value = clamp(stepped, min_val, max_val)
    local formatted = string.format("%." .. decimals .. "f", new_value)
    local numeric_value = tonumber(formatted) or new_value
    local changed = numeric_value ~= current

    if changed then
        rt.ref_table[rt.ref_value] = numeric_value
    end

    rt.text = formatted

    if slider_bar and slider_bar.T and max_val ~= min_val then
        local width = rt.w or (e and e.T and e.T.w) or 0
        local ratio = (numeric_value - min_val) / (max_val - min_val)
        slider_bar.T.w = ratio * width
        slider_bar.config.w = slider_bar.T.w
    end

    if should_invoke_callback and callback_name and changed then
        local cb = G.FUNCS and G.FUNCS[callback_name]
        if cb then
            cb(rt)
        end
    end

    if rt.post_round then
        rt.post_round(rt, changed)
    end

    return changed
end

local slider_patch_applied = false
local restart_requested = false
local up_sleeve = nil
local ensure_up_sleeve_registered
local processed_contexts = setmetatable({}, {__mode = "k"})
local processed_hands = setmetatable({}, {__mode = "k"})

local function mark_restart_needed()
    if not restart_requested then
        restart_requested = true
        if SMODS then
            SMODS.full_restart = math.max(SMODS.full_restart or 0, 1)
        end
    end
end

local positive_key_patterns = {
    "mult",
    "chip",
    "xchip",
    "xmult",
    "payout",
    "bonus",
    "value",
    "amount",
    "reward",
    "profit",
    "interest",
    "dollar",
    "money",
    "income",
    "draw",
    "hand",
    "discard",
    "joker",
    "slot",
}

local negative_key_patterns = {
    "cost",
    "price",
}

local probability_key_patterns = {
    "odds",
    "chance",
    "prob",
    "percent",
    "rate",
    "luck",
}

local function should_scale_number(key, value)
    if value == 0 then
        return false
    end
    if value == 1 and (key == 'x_mult' or key == 'x_chips') then
        return false
    end

    if type(key) ~= 'string' then
        return math.abs(value) >= 2
    end

    local lower = string.lower(key)
    if not cfg.affect_probabilities then
        for _, pattern in ipairs(probability_key_patterns) do
            if lower:find(pattern, 1, true)
                or (pattern == 'rate' and lower:find('cost', 1, true))
            then
                return false
            end
        end
    end

    for _, pattern in ipairs(negative_key_patterns) do
        if lower:find(pattern, 1, true) then
            return false
        end
    end
    for _, pattern in ipairs(positive_key_patterns) do
        if lower:find(pattern, 1, true) then
            return true
        end
    end

    return math.abs(value) >= 1
end

local function scale_numeric_fields(tbl, factor, seen, root_card)
    if type(tbl) ~= 'table' then
        return
    end
    seen = seen or {}
    if seen[tbl] then
        return
    end
    seen[tbl] = true

    for key, value in pairs(tbl) do
        local value_type = type(value)
        if value_type == 'number' then
            if should_scale_number(key, value) then
                tbl[key] = value * factor
            end
        elseif value_type == 'table' and key ~= 'consumeable' and value ~= root_card then
            scale_numeric_fields(value, factor, seen, root_card)
        end
    end
end

local function has_round_timer(tbl, seen)
    if type(tbl) ~= 'table' then
        return false
    end
    seen = seen or {}
    if seen[tbl] then
        return false
    end
    seen[tbl] = true

    for key, value in pairs(tbl) do
        if type(key) == 'string' then
            local lower = string.lower(key)
            if lower:find('round', 1, true) and type(value) == 'number' then
                return true
            end
        end
        if type(value) == 'table' and has_round_timer(value, seen) then
            return true
        end
    end

    return false
end

local function multiply_joker_values(card, factor)
    if not card or not card.ability then
        return false
    end
    if factor == 1 then
        return false
    end
    if card.ability.immutable then
        return false
    end
    if has_round_timer(card.ability) then
        return false
    end

    if ensure_up_sleeve_registered then ensure_up_sleeve_registered() end

    scale_numeric_fields(card.ability, factor, {}, card)
    if card.ability.consumeable then
        scale_numeric_fields(card.ability.consumeable, factor, {}, card)
    end

    if card.set_cost then
        card:set_cost()
    end

    return true
end

local function format_multiplier_text(multiplier)
    if math.abs(multiplier - math.floor(multiplier + 0.5)) < 1e-9 then
        return string.format("x%d", math.floor(multiplier + 0.5))
    end
    if math.abs(multiplier * 10 - math.floor(multiplier * 10 + 0.5)) < 1e-9 then
        return string.format("x%.1f", multiplier)
    end
    return string.format("x%.2f", multiplier)
end

local function apply_multiplier_to_jokers(factor)
    if not (G and G.jokers and G.jokers.cards) then
        return
    end

    local any_applied = false
    for _, card in ipairs(G.jokers.cards) do
        local changed = multiply_joker_values(card, factor)
        if changed then
            any_applied = true
            if card.juice_up then
                card:juice_up(0.5, 0.4)
            end
        end
    end

    if any_applied then
        card_eval_status_text(
            G.jokers,
            'jokers',
            nil,
            nil,
            nil,
            {
                message = format_multiplier_text(factor),
                colour = G.C.RED,
            }
        )
    end
end

local function apply_multiplier(in_sleeve_scope, context)
    if not context then
        return
    end

    local is_eval = context.context == 'eval'
    local is_final = context.final_scoring_step or context.context == 'final_scoring_step'

    if not ((is_eval and not in_sleeve_scope) or (is_final and in_sleeve_scope)) then
        return
    end

    if type(context) == 'table' then
        if processed_contexts[context] then
            return
        end
        if not processed_contexts[context] then
            processed_contexts[context] = {}
        end
        if processed_contexts[context][in_sleeve_scope and "sleeve" or "deck"] then
            return
        end
        processed_contexts[context][in_sleeve_scope and "sleeve" or "deck"] = true

        if not in_sleeve_scope and is_eval and type(context.full_hand) == 'table' then
            if processed_hands[context.full_hand] then
                return
            end
            processed_hands[context.full_hand] = true
        end
    end

    if cfg.multiply_on_blind then
        local last_blind = G and G.GAME and G.GAME.last_blind
        if not (last_blind and last_blind.boss) then
            return
        end
    end

    local multiplier = cfg.multiplier_value or 1
    if math.abs(multiplier - 1) < 1e-9 then
        return
    end

    apply_multiplier_to_jokers(multiplier)
end

local function ensure_slider_step_patch()
    if slider_patch_applied then
        return
    end

    if not (G and G.FUNCS and G.FUNCS.slider and G.FUNCS.slider_descreet) then
        return
    end

    slider_patch_applied = true
    local base_slider = G.FUNCS.slider
    local base_slider_descreet = G.FUNCS.slider_descreet

    G.FUNCS.slider = function(e)
        local slider_bar = e and e.children and e.children[1]
        local rt = slider_bar and slider_bar.config and slider_bar.config.ref_table
        local suppressed_callback

        if rt and rt.step and rt.step > 0 and rt.callback then
            suppressed_callback = rt.callback
            rt.callback = nil
        end

        base_slider(e)

        if rt then
            if suppressed_callback then
                rt.callback = suppressed_callback
            end
            enforce_slider_value(e, rt, suppressed_callback, suppressed_callback ~= nil)
        end
    end

    G.FUNCS.slider_descreet = function(e, per)
        local slider_bar = e and e.children and e.children[1]
        local rt = slider_bar and slider_bar.config and slider_bar.config.ref_table

        base_slider_descreet(e, per)

        if rt then
            local should_call_cb = rt.step and rt.step > 0 and rt.callback ~= nil
            enforce_slider_value(e, rt, rt.callback, should_call_cb)
        end
    end
end

-- Dynamic deck definition
local up_back = SMODS.Back{
    name = "Up Up Up",
    key = "Up_Up_Up",
    atlas = "Up Up Up",
    pos = {x = 0, y = 0},
    loc_txt = {
        name = "Up Up Up",
        text = {"Placeholder"}, -- table required
    },
    calculate = function(self, back, context)
        apply_multiplier(false, context)
    end,
}

local function propagate_up_description()
    local global_game = rawget(_G, "G")
    if not (global_game and global_game.localization and global_game.localization.descriptions) then
        return
    end

    if up_back and up_back.process_loc_text then
        up_back:process_loc_text()
    end

    local registered_center = global_game.P_CENTERS and global_game.P_CENTERS[up_back.key]
    if registered_center and registered_center ~= up_back then
        registered_center.loc_txt = registered_center.loc_txt or {}
        registered_center.loc_txt.text = up_back.loc_txt.text
        if registered_center.process_loc_text then
            registered_center:process_loc_text()
        end
    end

    if global_game.GAME and global_game.GAME.viewed_back and global_game.GAME.viewed_back.effect and global_game.GAME.viewed_back.effect.center then
        local viewed_center = global_game.GAME.viewed_back.effect.center
        if viewed_center.key == up_back.key then
            viewed_center.loc_txt = viewed_center.loc_txt or {}
            viewed_center.loc_txt.text = up_back.loc_txt.text
            if viewed_center.process_loc_text then
                viewed_center:process_loc_text()
            end
            if global_game.FUNCS and global_game.FUNCS.RUN_SETUP_check_back and global_game.OVERLAY_MENU and global_game.OVERLAY_MENU.get_UIE_by_ID then
                local elem = global_game.OVERLAY_MENU:get_UIE_by_ID(up_back.name)
                if elem and elem.config then
                    elem.config.id = nil
                    pcall(global_game.FUNCS.RUN_SETUP_check_back, elem)
                end
            end
        end
    end

    if up_sleeve then
        up_sleeve.loc_txt = up_sleeve.loc_txt or {}
        up_sleeve.loc_txt.text = up_back.loc_txt.text
    end
end

local function refresh_up_description()
    local multiplier = cfg.multiplier_value or 2
    local event_name = cfg.multiply_on_blind and "Boss Blind" or "Round"
    up_back.loc_txt.text = {
        "Every {C:attention}" .. event_name .. " your jokers{}",
        "values are multiplied by{C:red} " .. multiplier .. "x{}"
    }
    propagate_up_description()
end

ensure_up_sleeve_registered = function()
    if up_sleeve then
        return
    end
    local sleeves_mod = rawget(_G, "CardSleeves")
    if not (sleeves_mod and sleeves_mod.Sleeve) then
        return
    end

    up_sleeve = sleeves_mod.Sleeve{
        key = "Harrzxzx_up_up_up",
        name = "Up Up Up Sleeve",
        atlas = "UpUpSleve",
        pos = {x = 2, y = 2},
        unlocked = true,
        loc_txt = {
            name = "Up Up Up Sleeve",
            text = up_back.loc_txt.text,
        },
        calculate = function(self, sleeve, context)
            apply_multiplier(true, context)
        end,
    }
end

local function on_multiplier_slider_post_round(_, changed)
    if changed then
        refresh_up_description()
        mark_restart_needed()
    end
end

local function on_multiply_toggle_changed()
    refresh_up_description()
    mark_restart_needed()
end

-- Immediately set proper text
refresh_up_description()
ensure_up_sleeve_registered()

-- In-game mod settings tab (slider snaps to 0.5 increments)
SMODS.current_mod.config_tab = function()
    ensure_slider_step_patch()
    ensure_up_sleeve_registered()

    return {
        n = G.UIT.ROOT,
        config = {
            align = "cm",
            padding = 0.05,
            colour = G.C.CLEAR,
        },
        nodes = {
            create_toggle({
                label = "Multiply on Boss Blinds only",
                ref_table = cfg,
                ref_value = "multiply_on_blind",
                callback = on_multiply_toggle_changed,
            }),
            create_toggle({
                label = "Affect Probabilities",
                ref_table = cfg,
                ref_value = "affect_probabilities",
                callback = on_multiply_toggle_changed,
            }),
            create_slider({
                label = "Multiplier Value",
                ref_table = cfg,
                ref_value = "multiplier_value",
                min = 0,
                max = 10,
                step = 0.5,
                decimal_places = 1,
                post_round = on_multiplier_slider_post_round,
            }),
        },
    }
end
