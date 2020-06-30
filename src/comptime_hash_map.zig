const std = @import("std");
const hash_map = std.hash_map;
const testing = std.testing;
const math = std.math;

/// A comptime hashmap constructed with automatically selected hash and eql functions.
pub fn AutoComptimeHashMap(comptime K: type, comptime V: type) type {
    return ComptimeHashMap(K, V, hash_map.getAutoHashFn(K), hash_map.getAutoEqlFn(K));
}

/// Builtin hashmap for strings as keys.
pub fn ComptimeStringHashMap(comptime V: type) type {
    return ComptimeHashMap([]const u8, V, hash_map.hashString, hash_map.eqlString);
}

/// A hashmap which is constructed at compile time from constant values.
/// Intended to be used as a faster lookup table.
pub fn ComptimeHashMap(comptime K: type, comptime V: type, comptime hash: fn (key: K) u32, comptime eql: fn (a: K, b: K) bool) type {
    const Entry = struct {
        distance_from_start_index: usize = 0,
        key: K = undefined,
        val: V = undefined,
        used: bool = false,
    };

    return struct {
        max_distance_from_start_index: usize,
        entries: []const Entry,

        pub fn init(comptime values: var) @This() {
            const globals = comptime blk: {
                std.debug.assert(values.len != 0);
                @setEvalBranchQuota(1000 * values.len);

                // ensure that the hash map will be at most 60% full
                const size = math.ceilPowerOfTwo(usize, values.len * 5 / 3) catch unreachable;
                var slots = [1]Entry{.{}} ** size;

                var max_distance_from_start_index = 0;

                slot_loop: for (values) |kv| {
                    var key: K = kv.@"0";
                    var value: V = kv.@"1";

                    const start_index = @as(usize, hash(key)) & (size - 1);

                    var roll_over = 0;
                    var distance_from_start_index = 0;
                    while (roll_over < size) : ({
                        roll_over += 1;
                        distance_from_start_index += 1;
                    }) {
                        const index = (start_index + roll_over) & (size - 1);
                        const entry = &slots[index];

                        if (entry.used and !eql(entry.key, key)) {
                            if (entry.distance_from_start_index < distance_from_start_index) {
                                // robin hood to the rescue
                                const tmp = slots[index];
                                max_distance_from_start_index = math.max(max_distance_from_start_index, distance_from_start_index);
                                entry.* = .{
                                    .used = true,
                                    .distance_from_start_index = distance_from_start_index,
                                    .key = key,
                                    .val = value,
                                };
                                key = tmp.key;
                                value = tmp.val;
                                distance_from_start_index = tmp.distance_from_start_index;
                            }
                            continue;
                        }

                        max_distance_from_start_index = math.max(distance_from_start_index, max_distance_from_start_index);
                        entry.* = .{
                            .used = true,
                            .distance_from_start_index = distance_from_start_index,
                            .key = key,
                            .val = value,
                        };
                        continue :slot_loop;
                    }
                    unreachable; // put into a full map
                }

                break :blk .{
                    .slots = slots,
                    .max_distance_from_start_index = max_distance_from_start_index,
                };
            };
            return @This(){
                .max_distance_from_start_index = globals.max_distance_from_start_index,
                .entries = &globals.slots,
            };
        }

        pub fn has(self: *const @This(), key: K) bool {
            return self.get(key) != null;
        }

        pub fn get(self: *const @This(), key: K) ?*const V {
            const sizeMask = self.entries.len - 1;
            const start_index = @as(usize, hash(key)) & sizeMask;
            {
                var roll_over: usize = 0;
                while (roll_over <= self.max_distance_from_start_index) : (roll_over += 1) {
                    const index = (start_index + roll_over) & sizeMask;
                    const entry = &self.entries[index];

                    if (!entry.used) return null;
                    if (eql(entry.key, key)) return &entry.val;
                }
            }
            return null;
        }
    };
}

pub fn main() void {
    {
        const map = ComptimeStringHashMap(usize).init(.{
            .{ "foo", 1 },
            .{ "bar", 2 },
            .{ "baz", 3 },
            .{ "quux", 4 },
        });

        testing.expect(map.has("foo"));
        testing.expect(map.has("bar"));
        testing.expect(!map.has("zig"));
        testing.expect(!map.has("ziguana"));

        testing.expect(map.get("baz").?.* == 3);
        testing.expect(map.get("quux").?.* == 4);
        testing.expect(map.get("nah") == null);
        testing.expect(map.get("...") == null);
    }

    {
        const map = AutoComptimeHashMap(usize, []const u8).init(.{
            .{ 1, "foo" },
            .{ 2, "bar" },
            .{ 3, "baz" },
            .{ 45, "quux" },
        });

        testing.expect(map.has(1));
        testing.expect(map.has(2));
        testing.expect(!map.has(4));
        testing.expect(!map.has(1_000_000));

        testing.expectEqualStrings("foo", map.get(1).?.*);
        testing.expectEqualStrings("bar", map.get(2).?.*);
        testing.expect(map.get(4) == null);
        testing.expect(map.get(4_000_000) == null);
    }
}
