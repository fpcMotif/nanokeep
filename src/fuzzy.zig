const std = @import("std");

const max_query = 32;
const max_text = 128;
const max_typos = 2;
const unreached: i32 = -(1 << 28);
const unmatched = unreached / 2;

const per_char = 16;
const word_bonus = 10;
const camel_bonus = 7;
const run_bonus = 4;
const gap_start = 1;
const typo_cost = 40;
const chars_per_length_point = 8;

const Scores = [max_typos + 1][max_query + 1]i32;

fn bonus(text: []const u8, j: usize) i32 {
    if (j == 0) return word_bonus;
    const prev = text[j - 1];
    if (std.mem.indexOfScalar(u8, " -_./()[]:", prev) != null) return word_bonus;
    if (std.ascii.isLower(prev) and std.ascii.isUpper(text[j])) return camel_bonus;
    return 0;
}

fn lettersMissing(query: []const u8, text: []const u8) usize {
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
    if (text.len == 0 or lettersMissing(query, text) > typos) return null;

    const q = query.len;
    var ending_here: Scores = @splat(@splat(unreached));
    var run_start_bonus: Scores = @splat(@splat(0));
    var best: Scores = @splat(@splat(unreached));
    for (0..typos + 1) |s| best[s][0] = 0;
    skipTypos(&best, typos, q);
    for (text, 0..) |raw, j| {
        const c = std.ascii.toLower(raw);
        const b = bonus(text, j);
        for (0..typos + 1) |s| {
            var i = q;
            while (i > 0) : (i -= 1) {
                if (std.ascii.toLower(query[i - 1]) != c) {
                    ending_here[s][i] = unreached;
                    continue;
                }
                const first_letter: i32 = if (i == 1) 2 else 1;
                const cost: i32 = if (i == 1) 0 else gap_start;
                const jump = best[s][i - 1] - cost + b * first_letter;
                const kept_bonus = @max(run_start_bonus[s][i - 1], b);
                const stay = ending_here[s][i - 1] + @max(run_bonus, kept_bonus);
                if (stay >= jump) {
                    ending_here[s][i] = stay + per_char;
                    run_start_bonus[s][i] = kept_bonus;
                } else {
                    ending_here[s][i] = jump + per_char;
                    run_start_bonus[s][i] = b;
                }
                best[s][i] = @max(best[s][i], ending_here[s][i]);
            }
        }
        skipTypos(&best, typos, q);
        for (0..typos + 1) |s| {
            for (1..q) |i| best[s][i] -|= 1;
        }
    }
    var matched: i32 = unreached;
    for (0..typos + 1) |s| matched = @max(matched, best[s][q]);
    if (matched <= unmatched) return null;
    return matched - @as(i32, @intCast(text_in.len / chars_per_length_point));
}

fn skipTypos(best: *Scores, typos: usize, q: usize) void {
    for (1..typos + 1) |s| {
        for (1..q + 1) |i| best[s][i] = @max(best[s][i], best[s - 1][i - 1] - typo_cost);
    }
}
