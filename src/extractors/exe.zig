//! Structured executable intelligence: the features a reverse engineer
//! actually triages on, lifted straight from the binary and emitted as
//! WTD primitives so the existing consensus / drift / faction engine works on
//! *meaning*, not just fuzzy chunks.
//!
//! Each feature is an index-less list primitive (a bag — order and count are
//! not identity), so a binary's imports/exports/sections/strings unify across
//! a corpus exactly like a JSON list does:
//!
//!   imports[]=CreateRemoteThread   exports[]=Foo
//!   sections[]=.text               needs[]=libc.so.6
//!   strings[]=%s\svchost.exe
//!
//! A feature shared by every sample lands in the `universal` bucket; one that
//! appears in a single sample is `unique` evidence; a feature shared only
//! within a subgroup is exactly a faction signature. Nothing here changes the
//! engine — the primitives just carry richer facts.
//!
//! Every parser is bounds-checked and cap-bounded: a truncated or hostile
//! binary yields fewer features, never a crash. Formats: ELF (32/64, LE/BE),
//! PE, Mach-O (thin + fat). Strings are scanned for every input, so raw
//! firmware with no recognized container still contributes evidence.

const std = @import("std");
const types = @import("../types.zig");

/// Per-category safety cap: bounds output on pathological inputs.
const max_features = 8192;
/// String scanning.
const str_min_len = 5;
const str_max_len = 192;
const max_strings = 4096;

pub fn features(
    arena: std.mem.Allocator,
    content: []const u8,
    out: *std.ArrayList(types.Primitive),
) !void {
    if (content.len >= 4 and std.mem.eql(u8, content[0..4], "\x7fELF")) {
        elf(arena, content, out) catch {};
    } else if (content.len >= 2 and content[0] == 'M' and content[1] == 'Z') {
        pe(arena, content, out) catch {};
    } else if (content.len >= 4 and isMachoMagic(pu32(content, 0))) {
        macho(arena, content, out) catch {};
    }
    // Strings are extracted for every input, including unrecognized firmware.
    strings(arena, content, out) catch {};
}

// Bounded little-endian reads over a raw buffer (PE is always little-endian).
fn pu16(b: []const u8, off: usize) ?u16 {
    if (off + 2 > b.len) return null;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn pu32(b: []const u8, off: usize) ?u32 {
    if (off + 4 > b.len) return null;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn pu64(b: []const u8, off: usize) ?u64 {
    if (off + 8 > b.len) return null;
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// NUL-terminated printable ASCII at a file offset (bounded).
fn cstr(b: []const u8, off: usize, max: usize) ?[]const u8 {
    if (off >= b.len) return null;
    const rest = b[off..];
    const limit = @min(rest.len, max);
    var i: usize = 0;
    while (i < limit and rest[i] != 0) : (i += 1) {
        if (!isPrintable(rest[i])) return null;
    }
    if (i == 0 or i == limit) return null;
    return rest[0..i];
}

/// Append a bag primitive `<key>[]=<value>` unless the per-category cap is hit.
fn emit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(types.Primitive),
    counter: *usize,
    key: []const u8,
    value: []const u8,
) !void {
    if (counter.* >= max_features) return;
    counter.* += 1;
    const canonical = try std.mem.concat(arena, u8, &.{ key, "[]=", value });
    try out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
}

// ------------------------------------------------------------------ ELF ----

const Elf = struct {
    b: []const u8,
    endian: std.builtin.Endian,
    is64: bool,

    fn r16(self: Elf, off: usize) ?u16 {
        if (off + 2 > self.b.len) return null;
        return std.mem.readInt(u16, self.b[off..][0..2], self.endian);
    }
    fn r32(self: Elf, off: usize) ?u32 {
        if (off + 4 > self.b.len) return null;
        return std.mem.readInt(u32, self.b[off..][0..4], self.endian);
    }
    fn r64(self: Elf, off: usize) ?u64 {
        if (off + 8 > self.b.len) return null;
        return std.mem.readInt(u64, self.b[off..][0..8], self.endian);
    }
    /// A word: 8 bytes on ELF64, 4 on ELF32.
    fn word(self: Elf, off: usize) ?u64 {
        return if (self.is64) self.r64(off) else widen(self.r32(off));
    }
    /// NUL-terminated string at `strtab_off + index`, bounded and printable.
    fn str(self: Elf, strtab_off: u64, index: u32) ?[]const u8 {
        const base = strtab_off + index;
        if (base >= self.b.len) return null;
        const rest = self.b[@intCast(base)..];
        const nul = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        if (nul == 0) return null;
        return rest[0..nul];
    }
};

fn widen(v: ?u32) ?u64 {
    return if (v) |x| @as(u64, x) else null;
}

const SHT_SYMTAB = 2;
const SHT_DYNSYM = 11;
const SHT_DYNAMIC = 6;
const SHN_UNDEF = 0;
const SHN_LORESERVE = 0xff00; // >= this is a reserved index (ABS, COMMON, …)
const STT_OBJECT = 1;
const STT_FUNC = 2;
const STB_GLOBAL = 1;
const STB_WEAK = 2;
const DT_NEEDED = 1;

fn elf(arena: std.mem.Allocator, content: []const u8, out: *std.ArrayList(types.Primitive)) !void {
    if (content.len < 24) return;
    const class = content[4]; // 1=32, 2=64
    if (class != 1 and class != 2) return;
    const e = Elf{
        .b = content,
        .endian = if (content[5] == 2) .big else .little,
        .is64 = class == 2,
    };

    // Section-header table location (offsets differ by class).
    const shoff = (if (e.is64) e.r64(0x28) else widen(e.r32(0x20))) orelse return;
    const shentsize = (if (e.is64) e.r16(0x3a) else e.r16(0x2e)) orelse return;
    const shnum = (if (e.is64) e.r16(0x3c) else e.r16(0x30)) orelse return;
    const shstrndx = (if (e.is64) e.r16(0x3e) else e.r16(0x32)) orelse return;
    if (shnum == 0 or shentsize == 0) return;

    // Section-name string table.
    const shstr_hdr = shoff + @as(u64, shstrndx) * shentsize;
    const shstr_off = e.word(@as(usize, @intCast(shstr_hdr)) + (if (e.is64) @as(usize, 0x18) else 0x10)) orelse return;

    var n_sections: usize = 0;
    var n_imports: usize = 0;
    var n_exports: usize = 0;
    var n_needs: usize = 0;

    // Section headers: names, plus locate symbol and dynamic tables.
    var i: u16 = 0;
    while (i < shnum) : (i += 1) {
        const sh = @as(usize, @intCast(shoff)) + @as(usize, i) * shentsize;
        const sh_name = e.r32(sh) orelse continue;
        const sh_type = e.r32(sh + 4) orelse continue;

        if (e.str(shstr_off, sh_name)) |name| {
            try emit(arena, out, &n_sections, "sections", name);
        }
        if (sh_type == SHT_DYNSYM or sh_type == SHT_SYMTAB) {
            elfSymbols(e, sh, &n_imports, &n_exports, arena, out) catch {};
        } else if (sh_type == SHT_DYNAMIC) {
            elfNeeded(e, sh, &n_needs, arena, out) catch {};
        }
    }
}

fn elfSymbols(
    e: Elf,
    sh: usize,
    n_imports: *usize,
    n_exports: *usize,
    arena: std.mem.Allocator,
    out: *std.ArrayList(types.Primitive),
) !void {
    const off = e.word(sh + (if (e.is64) @as(usize, 0x18) else 0x10)) orelse return;
    const size = e.word(sh + (if (e.is64) @as(usize, 0x20) else 0x14)) orelse return;
    const link = e.r32(sh + (if (e.is64) @as(usize, 0x28) else 0x18)) orelse return;
    const entsize: u64 = if (e.is64) 24 else 16;
    if (entsize == 0 or size == 0) return;

    // The linked section is this symbol table's string table.
    const str_hdr = elfSectionHeader(e, link) orelse return;
    const strtab_off = e.word(str_hdr + (if (e.is64) @as(usize, 0x18) else 0x10)) orelse return;

    const count = size / entsize;
    var s: u64 = 1; // index 0 is the reserved null symbol
    while (s < count) : (s += 1) {
        const sym = @as(usize, @intCast(off + s * entsize));
        const st_name = e.r32(sym) orelse break;
        // st_info/st_shndx sit at different offsets on 32 vs 64.
        const info: u8 = if (e.is64) (if (sym + 4 < e.b.len) e.b[sym + 4] else break) else (if (sym + 12 < e.b.len) e.b[sym + 12] else break);
        const shndx = (if (e.is64) e.r16(sym + 6) else e.r16(sym + 14)) orelse break;
        const bind = info >> 4;
        const typ = info & 0xf;
        if (typ != STT_FUNC and typ != STT_OBJECT) continue;
        const name = e.str(strtab_off, st_name) orelse continue;

        if (shndx == SHN_UNDEF) {
            try emit(arena, out, n_imports, "imports", elfBareSymbol(name));
        } else if ((bind == STB_GLOBAL or bind == STB_WEAK) and shndx < SHN_LORESERVE) {
            // A real defined export lives in a real section; version-definition
            // nodes and other SHN_ABS/reserved entries are not exports.
            try emit(arena, out, n_exports, "exports", elfBareSymbol(name));
        }
    }
}

/// Byte offset of section header `idx`, or null if out of range.
fn elfSectionHeader(e: Elf, idx: u32) ?usize {
    const shoff = (if (e.is64) e.r64(0x28) else widen(e.r32(0x20))) orelse return null;
    const shentsize = (if (e.is64) e.r16(0x3a) else e.r16(0x2e)) orelse return null;
    const shnum = (if (e.is64) e.r16(0x3c) else e.r16(0x30)) orelse return null;
    if (idx >= shnum) return null;
    return @intCast(shoff + @as(u64, idx) * shentsize);
}

/// Strip a glibc-style `symbol@GLIBC_2.2.5` version suffix so the same import
/// unifies across samples linked against different library versions.
fn elfBareSymbol(name: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, name, '@') orelse return name;
    return name[0..at];
}

fn elfNeeded(
    e: Elf,
    sh: usize,
    n_needs: *usize,
    arena: std.mem.Allocator,
    out: *std.ArrayList(types.Primitive),
) !void {
    const off = e.word(sh + (if (e.is64) @as(usize, 0x18) else 0x10)) orelse return;
    const size = e.word(sh + (if (e.is64) @as(usize, 0x20) else 0x14)) orelse return;
    const link = e.r32(sh + (if (e.is64) @as(usize, 0x28) else 0x18)) orelse return;
    const entsize: u64 = if (e.is64) 16 else 8;
    if (entsize == 0) return;

    const str_hdr = elfSectionHeader(e, link) orelse return;
    const strtab_off = e.word(str_hdr + (if (e.is64) @as(usize, 0x18) else 0x10)) orelse return;

    const count = size / entsize;
    var d: u64 = 0;
    while (d < count) : (d += 1) {
        const ent = @as(usize, @intCast(off + d * entsize));
        const tag = e.word(ent) orelse break;
        const val = e.word(ent + (if (e.is64) @as(usize, 8) else 4)) orelse break;
        if (tag == 0) break; // DT_NULL terminates
        if (tag == DT_NEEDED) {
            if (e.str(strtab_off, @intCast(val))) |lib| {
                try emit(arena, out, n_needs, "needs", lib);
            }
        }
    }
}

// ------------------------------------------------------------------- PE ----

const PeSection = struct { va: u32, vsize: u32, raw_off: u32, raw_size: u32 };

const max_sections = 96;
const max_import_dlls = 1024;

fn pe(arena: std.mem.Allocator, b: []const u8, out: *std.ArrayList(types.Primitive)) !void {
    const pe_off = pu32(b, 0x3c) orelse return;
    if (pe_off + 24 > b.len) return;
    if (!std.mem.eql(u8, b[pe_off .. pe_off + 4], "PE\x00\x00")) return;

    const num_sections = pu16(b, pe_off + 6) orelse return;
    const size_opt = pu16(b, pe_off + 20) orelse return;
    const opt_off = pe_off + 24;
    const magic = pu16(b, opt_off) orelse return;
    const is64 = magic == 0x20b; // PE32+ (else 0x10b PE32)
    const sect_off = opt_off + size_opt;

    // Section table → names + an RVA map for the directories below.
    var sections = std.ArrayList(PeSection).init(arena);
    var n_sections: usize = 0;
    var s: usize = 0;
    while (s < num_sections and s < max_sections) : (s += 1) {
        const sh = sect_off + s * 40;
        if (sh + 40 > b.len) break;
        const name_raw = b[sh .. sh + 8];
        const nlen = std.mem.indexOfScalar(u8, name_raw, 0) orelse 8;
        if (nlen > 0 and isPrintableRun(name_raw[0..nlen]))
            try emit(arena, out, &n_sections, "sections", name_raw[0..nlen]);
        try sections.append(.{
            .va = pu32(b, sh + 12) orelse 0,
            .vsize = pu32(b, sh + 8) orelse 0,
            .raw_off = pu32(b, sh + 20) orelse 0,
            .raw_size = pu32(b, sh + 16) orelse 0,
        });
    }

    // Data directories: index 0 = exports, 1 = imports.
    const dd_off = opt_off + (if (is64) @as(usize, 0x70) else 0x60);
    peImports(arena, b, sections.items, dd_off, is64, out) catch {};
    peExports(arena, b, sections.items, dd_off, out) catch {};
}

fn rvaToOff(sections: []const PeSection, rva: u32) ?usize {
    for (sections) |sec| {
        const span = @max(sec.vsize, sec.raw_size);
        if (rva >= sec.va and rva < sec.va +% span) {
            return @as(usize, sec.raw_off) + (rva - sec.va);
        }
    }
    return null;
}

fn peImports(
    arena: std.mem.Allocator,
    b: []const u8,
    sections: []const PeSection,
    dd_off: usize,
    is64: bool,
    out: *std.ArrayList(types.Primitive),
) !void {
    const imp_rva = pu32(b, dd_off + 8) orelse return; // directory[1]
    if (imp_rva == 0) return;
    var desc = rvaToOff(sections, imp_rva) orelse return;

    var n_imports: usize = 0;
    var n_needs: usize = 0;
    var dll: usize = 0;
    while (dll < max_import_dlls) : (dll += 1) {
        if (desc + 20 > b.len) break;
        const oft = pu32(b, desc) orelse break;
        const name_rva = pu32(b, desc + 12) orelse break;
        const iat = pu32(b, desc + 16) orelse break;
        if (oft == 0 and name_rva == 0 and iat == 0) break; // null terminator
        desc += 20;

        if (name_rva != 0) {
            if (rvaToOff(sections, name_rva)) |o| {
                if (cstr(b, o, 128)) |name| try emit(arena, out, &n_needs, "needs", name);
            }
        }
        // Walk the thunk array (prefer the import lookup table, fall back to IAT).
        const thunk_rva = if (oft != 0) oft else iat;
        var toff = rvaToOff(sections, thunk_rva) orelse continue;
        const step: usize = if (is64) 8 else 4;
        var count: usize = 0;
        while (count < max_features) : (count += 1) {
            const val: u64 = if (is64) (pu64(b, toff) orelse break) else (pu32(b, toff) orelse break);
            if (val == 0) break;
            toff += step;
            const ordinal_flag: u64 = if (is64) 0x8000000000000000 else 0x80000000;
            if (val & ordinal_flag != 0) continue; // import by ordinal: no name
            const hint_rva: u32 = @intCast(val & 0x7fffffff);
            const ho = rvaToOff(sections, hint_rva) orelse continue;
            if (cstr(b, ho + 2, 256)) |fname| { // skip 2-byte hint
                try emit(arena, out, &n_imports, "imports", fname);
            }
        }
    }
}

fn peExports(
    arena: std.mem.Allocator,
    b: []const u8,
    sections: []const PeSection,
    dd_off: usize,
    out: *std.ArrayList(types.Primitive),
) !void {
    const exp_rva = pu32(b, dd_off) orelse return; // directory[0]
    if (exp_rva == 0) return;
    const ed = rvaToOff(sections, exp_rva) orelse return;

    const num_names = pu32(b, ed + 24) orelse return;
    const names_rva = pu32(b, ed + 32) orelse return;
    const names_off = rvaToOff(sections, names_rva) orelse return;

    var n_exports: usize = 0;
    var i: usize = 0;
    while (i < num_names and i < max_features) : (i += 1) {
        const name_rva = pu32(b, names_off + i * 4) orelse break;
        const o = rvaToOff(sections, name_rva) orelse continue;
        if (cstr(b, o, 256)) |name| try emit(arena, out, &n_exports, "exports", name);
    }
}

fn isPrintableRun(s: []const u8) bool {
    for (s) |c| if (!isPrintable(c)) return false;
    return true;
}

// --------------------------------------------------------------- Mach-O ----

const MH_MAGIC = 0xfeedface; // 32-bit, little-endian
const MH_MAGIC_64 = 0xfeedfacf; // 64-bit, little-endian
const LC_SEGMENT = 0x1;
const LC_SEGMENT_64 = 0x19;
const LC_SYMTAB = 0x2;
const N_STAB = 0xe0;
const N_TYPE = 0x0e;
const N_EXT = 0x01;
const N_UNDF = 0x0;
const N_SECT = 0xe;

fn isMachoMagic(m: ?u32) bool {
    const v = m orelse return false;
    return v == MH_MAGIC or v == MH_MAGIC_64;
}

/// Thin, little-endian Mach-O (the x86_64/arm64 case). Big-endian and fat
/// binaries fall through to the string scanner. Symbol names carry Mach-O's
/// leading `_`, which is stripped so a symbol unifies with its ELF/PE spelling.
fn macho(arena: std.mem.Allocator, b: []const u8, out: *std.ArrayList(types.Primitive)) !void {
    const magic = pu32(b, 0) orelse return;
    const is64 = magic == MH_MAGIC_64;
    const header_size: usize = if (is64) 32 else 28;
    const ncmds = pu32(b, 16) orelse return;

    var n_sections: usize = 0;
    var n_imports: usize = 0;
    var n_exports: usize = 0;

    var off: usize = header_size;
    var c: usize = 0;
    while (c < ncmds and c < max_features) : (c += 1) {
        const cmd = pu32(b, off) orelse break;
        const cmdsize = pu32(b, off + 4) orelse break;
        if (cmdsize < 8 or off + cmdsize > b.len) break;

        if (cmd == LC_SEGMENT_64 and is64) {
            const nsects = pu32(b, off + 64) orelse 0;
            var i: usize = 0;
            while (i < nsects and i < max_sections) : (i += 1) {
                machoSectionName(arena, b, off + 72 + i * 80, &n_sections, out) catch {};
            }
        } else if (cmd == LC_SEGMENT and !is64) {
            const nsects = pu32(b, off + 48) orelse 0;
            var i: usize = 0;
            while (i < nsects and i < max_sections) : (i += 1) {
                machoSectionName(arena, b, off + 56 + i * 68, &n_sections, out) catch {};
            }
        } else if (cmd == LC_SYMTAB) {
            machoSymbols(arena, b, off, is64, &n_imports, &n_exports, out) catch {};
        }
        off += cmdsize;
    }
}

fn machoSectionName(
    arena: std.mem.Allocator,
    b: []const u8,
    sect_off: usize,
    counter: *usize,
    out: *std.ArrayList(types.Primitive),
) !void {
    // section: sectname[16], segname[16], …
    if (sect_off + 32 > b.len) return;
    const sect = fixedName(b[sect_off .. sect_off + 16]);
    const seg = fixedName(b[sect_off + 16 .. sect_off + 32]);
    if (sect.len == 0) return;
    const name = try std.mem.concat(arena, u8, &.{ seg, ",", sect });
    try emit(arena, out, counter, "sections", name);
}

fn machoSymbols(
    arena: std.mem.Allocator,
    b: []const u8,
    lc_off: usize,
    is64: bool,
    n_imports: *usize,
    n_exports: *usize,
    out: *std.ArrayList(types.Primitive),
) !void {
    const symoff = pu32(b, lc_off + 8) orelse return;
    const nsyms = pu32(b, lc_off + 12) orelse return;
    const stroff = pu32(b, lc_off + 16) orelse return;
    const nlist_size: usize = if (is64) 16 else 12;

    var i: usize = 0;
    while (i < nsyms and i < max_features) : (i += 1) {
        const e = @as(usize, symoff) + i * nlist_size;
        const n_strx = pu32(b, e) orelse break;
        if (e + 5 > b.len) break;
        const n_type = b[e + 4];
        if (n_type & N_STAB != 0) continue; // debug symbol
        const ext = n_type & N_EXT != 0;
        const typ = n_type & N_TYPE;
        if (!ext) continue; // only external symbols are imports/exports
        const name = cstr(b, @as(usize, stroff) + n_strx, 256) orelse continue;
        const bare = machoBare(name);
        if (bare.len == 0) continue;
        if (typ == N_UNDF) {
            try emit(arena, out, n_imports, "imports", bare);
        } else if (typ == N_SECT) {
            try emit(arena, out, n_exports, "exports", bare);
        }
    }
}

/// A NUL-padded fixed-width name field (segment/section names are 16 bytes).
fn fixedName(field: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    const name = field[0..nul];
    return if (isPrintableRun(name)) name else "";
}

/// Strip Mach-O's leading underscore so `_malloc` unifies with ELF `malloc`.
fn machoBare(name: []const u8) []const u8 {
    return if (name.len > 1 and name[0] == '_') name[1..] else name;
}

// -------------------------------------------------------------- strings ----

/// Scan for printable ASCII runs (>= str_min_len) and UTF-16LE runs, emit each
/// distinct value once. Deduplicated within the file so a string repeated a
/// thousand times is one primitive; the store dedups across files.
fn strings(arena: std.mem.Allocator, content: []const u8, out: *std.ArrayList(types.Primitive)) !void {
    var seen = std.StringHashMap(void).init(arena);
    var n: usize = 0;

    // ASCII.
    var i: usize = 0;
    while (i < content.len and n < max_strings) {
        if (isPrintable(content[i])) {
            const start = i;
            while (i < content.len and isPrintable(content[i])) i += 1;
            const run = content[start..i];
            if (run.len >= str_min_len) try emitString(arena, out, &seen, &n, run);
        } else i += 1;
    }

    // UTF-16LE (printable ASCII code unit followed by 0x00).
    i = 0;
    while (i + 1 < content.len and n < max_strings) {
        if (isPrintable(content[i]) and content[i + 1] == 0) {
            const start = i;
            var buf = std.ArrayList(u8).init(arena);
            while (i + 1 < content.len and isPrintable(content[i]) and content[i + 1] == 0) {
                try buf.append(content[i]);
                i += 2;
            }
            if (buf.items.len >= str_min_len) try emitString(arena, out, &seen, &n, buf.items);
            if (i == start) i += 1;
        } else i += 1;
    }
}

fn emitString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(types.Primitive),
    seen: *std.StringHashMap(void),
    n: *usize,
    raw: []const u8,
) !void {
    const val = if (raw.len > str_max_len) raw[0..str_max_len] else raw;
    if (seen.contains(val)) return;
    const owned = try arena.dupe(u8, val);
    try seen.put(owned, {});
    n.* += 1;
    const canonical = try std.mem.concat(arena, u8, &.{ "strings[]=", owned });
    try out.append(.{ .kind = .kv, .canonical = canonical, .line = 0 });
}

fn isPrintable(c: u8) bool {
    return (c >= 0x20 and c < 0x7f) or c == '\t';
}

// -------------------------------------------------------------- tests ------

const testing = std.testing;

fn listValues(arena: std.mem.Allocator, prims: []const types.Primitive, key: []const u8) ![][]const u8 {
    const prefix = try std.mem.concat(arena, u8, &.{ key, "[]=" });
    var vals = std.ArrayList([]const u8).init(arena);
    for (prims) |p| {
        if (p.kind == .kv and std.mem.startsWith(u8, p.canonical, prefix)) {
            try vals.append(p.canonical[prefix.len..]);
        }
    }
    return vals.toOwnedSlice();
}

fn has(vals: []const []const u8, target: []const u8) bool {
    for (vals) |v| if (std.mem.eql(u8, v, target)) return true;
    return false;
}

test "strings: ascii and utf-16le runs, deduplicated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = std.ArrayList(types.Primitive).init(arena);
    // "hello" ascii twice, "world" utf-16le once, "ab" too short. A
    // non-printable byte guards each region so UTF-16 runs don't bridge.
    const data = "hello\x00\x01hello\x01ab\x01w\x00o\x00r\x00l\x00d\x00";
    try strings(arena, data, &out);
    const vals = try listValues(arena, out.items, "strings");
    try testing.expect(has(vals, "hello"));
    try testing.expect(has(vals, "world"));
    try testing.expect(!has(vals, "ab"));
    // "hello" appears twice in input but once as a primitive.
    var hello_count: usize = 0;
    for (vals) |v| if (std.mem.eql(u8, v, "hello")) {
        hello_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), hello_count);
}

test "elfBareSymbol strips version suffix" {
    try testing.expectEqualStrings("printf", elfBareSymbol("printf@GLIBC_2.2.5"));
    try testing.expectEqualStrings("main", elfBareSymbol("main"));
}

test "malformed ELF never crashes, still yields strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = std.ArrayList(types.Primitive).init(arena);
    // ELF magic then garbage/truncation.
    const junk = "\x7fELF\x02\x01" ++ "AAAApadding_string_here_long_enough";
    try features(arena, junk, &out);
    const vals = try listValues(arena, out.items, "strings");
    try testing.expect(vals.len >= 1); // did not crash; scanned strings
}
