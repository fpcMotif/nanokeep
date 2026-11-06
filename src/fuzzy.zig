const std = @import("std");

const max_query = 32;
const max_text = 128;
const max_typos = 2;
const neg: i32 = -(1 << 28);

const per_char = 16;
const word_bonus = 10;
const camel_bonus = 7;
const run_bonus = 4;
const gap_start = 1;
const typo_cost = 40;

fn bonus(text: []const u8, j: usize) i32 {
    if (j == 0) return word_bonus;
    const prev = text[j - 1];
    if (std.mem.indexOfScalar(u8, " -_./()[]:", prev) != null) return word_bonus;
    if (std.ascii.isLower(prev) and std.ascii.isUpper(text[j])) return camel_bonus;
    return 0;
}

fn absent(query: []const u8, text: []const u8) usize {
    var have: [256]bool = @splat(false);
    for (text) |c| have[std.ascii.toLower(c)] = true;
    var missing: usize = 0;
    for (query) |c| missing += @intFromBool(!have[std.ascii.toLower(c)]);
    return missing;
}

pub fn score(query_in: []const u8, text_in: []const u8) ?i32 {
    if (query_in.len == 0) return 0;
    const query = query_in[0..@min(query_in.len, max_query)];
    const text = text_in[0..@min(text_in.len, max_text)];
    const typos = @min((query.len - 1) / 4, max_typos);
    if (text.len == 0 or absent(query, text) > typos) return null;

    const q = query.len;
    const Layers = [max_typos + 1][max_query + 1]i32;
    var run: Layers = @splat(@splat(neg));
    var chunk: Layers = @splat(@splat(0));
    var best: Layers = @splat(@splat(neg));
    for (0..typos + 1) |s| best[s][0] = 0;
    skipTypos(&best, typos, q);
    for (text, 0..) |raw, j| {
        const c = std.ascii.toLower(raw);
        const b = bonus(text, j);
        for (0..typos + 1) |s| {
            var i = q;
            while (i > 0) : (i -= 1) {
                if (std.ascii.toLower(query[i - 1]) != c) {
                    run[s][i] = neg;
                    continue;
                }
                const first: i32 = if (i == 1) 2 else 1;
                const cost: i32 = if (i == 1) 0 else gap_start;
                const jump = best[s][i - 1] - cost + b * first;
                const run_chunk = @max(chunk[s][i - 1], b);
                const stay = run[s][i - 1] + @max(run_bonus, run_chunk);
                if (stay >= jump) {
                    run[s][i] = stay + per_char;
                    chunk[s][i] = run_chunk;
                } else {
                    run[s][i] = jump + per_char;
                    chunk[s][i] = b;
                }
                best[s][i] = @max(best[s][i], run[s][i]);
            }
        }
        skipTypos(&best, typos, q);
        for (0..typos + 1) |s| {
            for (1..q) |i| best[s][i] -|= 1;
        }
    }
    var top: i32 = neg;
    for (0..typos + 1) |s| top = @max(top, best[s][q]);
    if (top <= neg / 2) return null;
    return top - @as(i32, @intCast(text_in.len / 8));
}

pub fn frecency(now: i64, last_seen: i64, picks: u32) i32 {
    const age = now - last_seen;
    const day = std.time.s_per_day;
    const recent: i32 = if (last_seen == 0) 0 else if (age < std.time.s_per_hour) 24 else if (age < day) 16 else if (age < 7 * day) 8 else if (age < 30 * day) 4 else 0;
    return recent + 4 * @as(i32, @intCast(@min(picks, 8)));
}

fn skipTypos(best: anytype, typos: usize, q: usize) void {
    for (1..typos + 1) |s| {
        for (1..q + 1) |i| best[s][i] = @max(best[s][i], best[s - 1][i - 1] - typo_cost);
    }
}
