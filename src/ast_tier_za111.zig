// Rhyos Labs - Ephor
// ZA111 returned-stack-reference: the AST tier's memory rule.
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

//! ZA111 (returned-stack-reference) lives here, split out of
//! ast_tier.zig so each half stays under the 256 KiB AST-tier input cap
//! (EPH-I0601; raised from 64 KiB by EPH-I1300): the file implementing
//! the rule must stay analyzable.
//! ast_tier.zig owns the parse and the per-file pipeline. This file
//! Owns the ZA111 analysis, its type index, and its collection passes.
//! The fn-body walker lives in ast_tier_za111_walk.zig (EPH-I0046).
//! Only `buildTypeIndex`, `Za111Ctx`, and `analyzeFileZa111` export.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const types = @import("types.zig");
const walk = @import("ast_tier_za111_walk.zig");

const Issue = types.Issue;
const Walker = walk.Walker;
const CaptureRecord = walk.CaptureRecord;
const ComptimeRange = walk.ComptimeRange;
const insideComptime = walk.insideComptime;
const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;
const OptIndex = Ast.Node.OptionalIndex;

// ZA111: returned-stack-reference
// ============================================================================
//
// Compiler-gap evidence (zig 0.16.0 probes):
//   CAUGHT: return &var_local;  MISSED: &var.field, &var[i], var[lo..hi],
//   &param, &param.field, &var.slice_field, &var.ptr_field, &opt.?,
//   const p = &var; return p, and the bare &var store.  SAFE:
//   comptime consts/params/var (string-builder idiom).
// ZA111 covers exactly the MISSED forms. The bare-var return form is
// Skipped so ephor never duplicates a hard compile error. (Slot-address
// rows re-verified 2026-08-23, EPH-I0590.)
//
// Precision: a chained address-of fires only when every hop provably
// stays inside the stack frame. A pointer/slice hop is caller memory
// (safe) while hops remain behind it. An unresolvable hop is SILENT.
// Escape (EPH-I0046): a return and an out-param store escape by
// construction. A labeled-block value fires only when a consumer
// Provably escapes (a return of the block, an out-param store of it,
// or an alias chain from its binding), so in-function consumption (the
// sig merlin.zig shape) and discarded statements stay silent.
// Deferred: runtime-known const locals (needs comptime-provenance),
// global-var stores, non-param field stores, destructured chains, and
// the no-rebind var binding (hard compile errors never echoed). The
// Element-mutated var slice binding compiles but stays silent without
// a rebind (EPH-I0046).

const RULE_ZA111 = types.RULE_RETURNED_STACK_REF;

/// A `var` local: always a runtime stack slot.
const StackLocal = struct {
    name: []const u8,
    /// Provably an array type — only arrays slice as stack storage.
    provably_array: bool,
    /// Pointer/slice-typed: `&ptr.x` addresses caller memory, not the
    /// stack slot.
    is_pointer: bool,
    /// Explicit type annotation (or the init's explicit type), .none
    /// when inferred and unprovable.
    type_node: OptIndex,
};

/// A by-value function parameter: its slot lives on the stack frame.
const Param = struct {
    name: []const u8,
    is_pointer: bool,
    type_node: OptIndex,
    /// Provably an array type — slicing an array param points into the
    /// param's stack slot. Slicing a slice/pointer copies caller memory
    /// (EPH-I0046).
    provably_array: bool = false,
};

/// A `const p = &x...;` binding: p's value points into root's stack slot.
/// `var` aliases (EPH-I0046) compile only when rebound — the no-rebind
/// shape is a hard compile error, never echoed — and fire only when
/// every rebind RHS stays stack-rooted.
const Alias = struct {
    name: []const u8,
    root: []const u8,
    /// The resolving init: decl init for const, last rebind RHS for var.
    init: OptIndex = .none,
    is_var: bool = false,
    decl_tok: u32 = 0,
    /// Set when the rebind adjudication or the fixpoint drops the alias.
    /// aliasRoot skips dropped entries (EPH-I0046).
    dropped: bool = false,
};

/// A `const/var s = arr[a..b];` binding whose sliced root is a provable
/// stack array (EPH-I0046). Var bindings follow the pointer-alias rebind
/// rule: no rebind (compile error) or a non-array rebind RHS drops.
const SliceBinding = struct {
    name: []const u8,
    root: []const u8,
    is_var: bool = false,
    decl_tok: u32 = 0,
};

/// A resolved payload capture (EPH-I0046): name, stack root binding,
/// and the body token range that scopes the name.
const Capture = struct {
    name: []const u8,
    root: []const u8,
    is_param: bool = false,
    first_tok: u32,
    last_tok: u32,
};

/// Per-function collected state for ZA111.
const FnScan = struct {
    locals: std.ArrayListUnmanaged(StackLocal) = .empty,
    aliases: std.ArrayListUnmanaged(Alias) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    slice_bindings: std.ArrayListUnmanaged(SliceBinding) = .empty,
    captures: std.ArrayListUnmanaged(Capture) = .empty,

    fn deinit(self: *FnScan, a: Allocator) void {
        self.locals.deinit(a);
        self.aliases.deinit(a);
        self.params.deinit(a);
        self.slice_bindings.deinit(a);
        self.captures.deinit(a);
    }

    fn localByName(self: *const FnScan, name: []const u8) ?StackLocal {
        for (self.locals.items) |l| {
            if (mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    fn aliasRoot(self: *const FnScan, name: []const u8) ?[]const u8 {
        for (self.aliases.items) |al| {
            if (al.dropped) continue;
            if (mem.eql(u8, al.name, name)) return al.root;
        }
        return null;
    }

    fn sliceBindingRoot(self: *const FnScan, name: []const u8) ?[]const u8 {
        for (self.slice_bindings.items) |sb| {
            if (mem.eql(u8, sb.name, name)) return sb.root;
        }
        return null;
    }

    fn paramByName(self: *const FnScan, name: []const u8) ?Param {
        for (self.params.items) |p| {
            if (mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

// ============================================================================
// Same-file type index (field-type resolution for chained address-of)
// ============================================================================
//
// `&v.words[i]` is stack UB when `words` is an array field but safe when
// it is a slice field — the syntax is identical, only the field type
// differs. This index maps type names to their container declarations so
// chain hops can be resolved. It is deliberately not a semantic layer:
// only same-file, name-resolvable types participate. Everything else is
// .unknown and the caller stays silent.

const TypeIndex = struct {
    /// name -> declared containers, each with its lexical scope, scoped
    /// per fn (EPH-I0592): a fn-local type shadows a same-named
    /// file-scope type inside its function. Sibling blocks still
    /// collide (later declaration wins) — a documented
    /// over-approximation.
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TypeEntry)) = .empty,

    pub fn deinit(self: *TypeIndex, a: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(a);
        self.map.deinit(a);
    }

    /// The container a chain in `body` resolves `name` against: the
    /// innermost fn-local scope containing `body`, else the file-scope
    /// declaration. Same-scope duplicates are a compile error in real
    /// code. The later wins for determinism.
    fn lookup(
        self: *const TypeIndex,
        tree: *const Ast,
        name: []const u8,
        body: NodeIndex,
    ) ?TypeEntry {
        const entries = self.map.get(name) orelse return null;
        const body_first = tree.firstToken(body);
        const body_last = tree.lastToken(body);
        var scoped: ?TypeEntry = null;
        var scoped_len: u32 = 0;
        var file_scope: ?TypeEntry = null;
        for (entries.items) |entry| {
            const sb = entry.scope_body orelse {
                file_scope = entry;
                continue;
            };
            if (!bodyInside(tree, sb, body_first, body_last)) continue;
            const len = tree.lastToken(sb) - tree.firstToken(sb);
            if (scoped == null or len <= scoped_len) {
                scoped = entry;
                scoped_len = len;
            }
        }
        return scoped orelse file_scope;
    }
};

/// One indexed type declaration plus its lexical scope: a container
/// (`const S = struct/union/enum {...};`) or a type alias (`const
/// V = [4]u32;`, `const P = *S;` — EPH-I0046: alias-indexed array
/// chains like `&v[i]` used to resolve unknown and stay silent).
const TypeEntry = struct {
    container: ?NodeIndex = null,
    /// The aliased type expression node when this entry is an alias.
    alias_type: OptIndex = .none,
    /// The innermost fn body containing the declaration, null at file
    /// scope. See TypeIndex for the block-scope over-approximation.
    scope_body: ?NodeIndex,
};

/// True when `body`'s token range sits inside scope `sb` (or is `sb`
/// itself): the scope's declarations are visible from the body.
fn bodyInside(tree: *const Ast, sb: NodeIndex, body_first: u32, body_last: u32) bool {
    return body_first >= tree.firstToken(sb) and body_last <= tree.lastToken(sb);
}

/// The container-declaration tag set lives in the walker module, shared
/// with isBoundaryTag there (the B75/B76 split mirrored the list across
/// the two files. It lives there once, EPH-I1232).
fn isContainerDeclTag(tag: Ast.Node.Tag) bool {
    return walk.isContainerDeclTag(tag);
}

/// Index every `const Name = struct/union/enum {...};` in the file,
/// including fn-local ones (EPH-I0592). Type aliases join the index
/// too: alias-typed chains used to resolve unknown (EPH-I0046).
pub fn buildTypeIndex(a: Allocator, tree: *const Ast) !TypeIndex {
    var idx = TypeIndex{};
    errdefer idx.deinit(a);
    var bodies: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer bodies.deinit(a);
    var i: usize = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const node: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(node) != .fn_decl) continue;
        try bodies.append(a, tree.nodeData(node).node_and_node[1]);
    }
    i = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const node: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        const vd = tree.fullVarDecl(node) orelse continue;
        if (!mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        const scope_body = innermostFnBody(tree, bodies.items, tree.firstToken(node));
        const entry: TypeEntry = if (isContainerDeclTag(tree.nodeTag(init)))
            .{ .container = init, .scope_body = scope_body }
        else if (isTypeExprTag(tree.nodeTag(init)))
            .{ .alias_type = init.toOptional(), .scope_body = scope_body }
        else
            continue;
        const name = tree.tokenSlice(vd.ast.mut_token + 1);
        const gop = try idx.map.getOrPut(a, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, entry);
    }
    return idx;
}

/// True for a bare TYPE expression: the shapes a `const V = <type>;`
/// alias can carry — array/pointer/optional types and type names.
/// Array and struct INIT values (`[4]u32{...}`, `S{...}`) are not
/// types and must not index (EPH-I0046).
fn isTypeExprTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .array_type,
        .array_type_sentinel,
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type_bit_range,
        .optional_type,
        .identifier,
        => true,
        else => false,
    };
}

/// The innermost fn body whose token range contains `tok`, null at
/// file scope.
fn innermostFnBody(tree: *const Ast, bodies: []const NodeIndex, tok: u32) ?NodeIndex {
    var found: ?NodeIndex = null;
    var found_len: u32 = 0;
    for (bodies) |body| {
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        if (tok <= first or tok >= last) continue;
        const len = last - first;
        if (found == null or len < found_len) {
            found = body;
            found_len = len;
        }
    }
    return found;
}

/// The declared type node of a container field, when resolvable.
fn fieldTypeNode(tree: *const Ast, container: NodeIndex, field: []const u8) ?NodeIndex {
    var buf: [2]NodeIndex = undefined;
    const cd = tree.fullContainerDecl(&buf, container) orelse return null;
    for (cd.ast.members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field, .container_field_init, .container_field_align => {},
            else => continue,
        }
        const name = tree.tokenSlice(tree.nodeMainToken(member));
        if (!mem.eql(u8, name, field)) continue;
        const cf = tree.fullContainerField(member) orelse return null;
        return cf.ast.type_expr.unwrap();
    }
    return null;
}

/// One step of chain resolution through a type expression.
const TypeStep = union(enum) {
    /// Pointer/slice: everything beyond is caller-owned memory.
    safe,
    /// Named type: resolvable further via the TypeIndex.
    named: []const u8,
    /// `[N]T` — an index hop stays inside the stack slot.
    array_elem: NodeIndex,
    /// `?T` — an unwrap hop stays inside the stack slot.
    optional_payload: NodeIndex,
    /// Unprovable from the AST — the caller stays silent.
    unknown,
};

fn classifyTypeNode(tree: *const Ast, node: NodeIndex) TypeStep {
    if (isPointerTypeExpr(tree, node)) return .safe;
    switch (tree.nodeTag(node)) {
        .identifier => {
            return .{ .named = tree.tokenSlice(tree.nodeMainToken(node)) };
        },
        .array_type, .array_type_sentinel => {
            const at = tree.fullArrayType(node) orelse return .unknown;
            return .{ .array_elem = at.ast.elem_type };
        },
        .optional_type => {
            return .{ .optional_payload = tree.nodeData(node).node };
        },
        else => return .unknown,
    }
}

fn stepThroughHop(sctx: ScanCtx, cur: TypeStep, hop: Hop) TypeStep {
    switch (cur) {
        .safe, .unknown => return cur,
        .array_elem => |elem| return stepThroughIndex(sctx, elem, hop),
        .optional_payload => |payload| return stepThroughUnwrap(sctx, payload, hop),
        .named => |name| return stepThroughNamed(sctx, name, hop),
    }
}

fn stepThroughIndex(sctx: ScanCtx, elem: NodeIndex, hop: Hop) TypeStep {
    if (hop != .index) return .unknown;
    return classifyTypeNode(sctx.tree, elem);
}

fn stepThroughUnwrap(sctx: ScanCtx, payload: NodeIndex, hop: Hop) TypeStep {
    if (hop != .unwrap) return .unknown;
    return classifyTypeNode(sctx.tree, payload);
}

/// The named-type hop: a container field lookup, or — for a type
/// alias — the same hop applied to the aliased type (`&v[i]` with
/// `v: V`, `V = [4]u32` — EPH-I0046). Cycles are compile errors in
/// real code.
fn stepThroughNamed(sctx: ScanCtx, name: []const u8, hop: Hop) TypeStep {
    const entry = sctx.tidx.lookup(sctx.tree, name, sctx.body) orelse return .unknown;
    if (entry.alias_type.unwrap()) |at| {
        const flat = flattenAlias(sctx, at, 0);
        return stepThroughHop(sctx, classifyTypeNode(sctx.tree, flat), hop);
    }
    const container = entry.container orelse return .unknown;
    return stepThroughField(sctx, container, hop);
}

fn stepThroughField(sctx: ScanCtx, container: NodeIndex, hop: Hop) TypeStep {
    if (hop != .field) return .unknown;
    const ft = fieldTypeNode(sctx.tree, container, hop.field) orelse return .unknown;
    return classifyTypeNode(sctx.tree, ft);
}

/// Resolve an alias chain (`const A = B; const B = [4]u32;`) to its
/// final type node, bounded by the alias-table size (cycles are compile
/// errors in real code. The bound makes adversarial input terminate).
fn flattenAlias(sctx: ScanCtx, node: NodeIndex, depth: usize) NodeIndex {
    if (depth >= 64) return node;
    if (sctx.tree.nodeTag(node) != .identifier) return node;
    const name = sctx.tree.tokenSlice(sctx.tree.nodeMainToken(node));
    const entry = sctx.tidx.lookup(sctx.tree, name, sctx.body) orelse return node;
    const at = entry.alias_type.unwrap() orelse return node;
    return flattenAlias(sctx, at, depth + 1);
}

const ChainSafety = enum { unsafe, safe, unknown };

/// The `.safe` verdict for one hop: safe only while hops remain after
/// it. A final-hop `.safe` addresses the slot that stores the
/// pointer/slice value itself, inside the stack copy (EPH-I0590).
fn safeVerdict(hi: usize) ChainSafety {
    return if (hi == 0) .unsafe else .safe;
}

/// Whether a chained address-of provably stays inside the stack frame.
/// Hops are stored outermost-first, so resolution walks them in
/// reverse (root-adjacent hop first).
fn resolveChainSafety(sctx: ScanCtx, info: ChainInfo, root_type: OptIndex) ChainSafety {
    if (info.overflow) return .unknown;
    const root_node = root_type.unwrap() orelse return .unknown;
    var cur = classifyTypeNode(sctx.tree, root_node);
    var hi = info.hop_count;
    while (hi > 0) {
        hi -= 1;
        cur = stepThroughHop(sctx, cur, info.hops[hi]);
        switch (cur) {
            // Pointer/slice terminates the walk safely only while hops
            // remain after it: the address then points BEHIND the
            // pointer/slice (EPH-I0590).
            .safe => return safeVerdict(hi),
            .unknown => return .unknown,
            else => {},
        }
    }
    return .unsafe;
}

// ============================================================================
// ZA111 collection passes
// ============================================================================

/// Unwrap parenthesized expressions: `return (&x);` is `return &x;`.
fn unwrapGroup(tree: *const Ast, node: NodeIndex) NodeIndex {
    var cur = node;
    while (tree.nodeTag(cur) == .grouped_expression) {
        cur = tree.nodeData(cur).node_and_token[0];
    }
    return cur;
}

/// One hop of an address-of chain.
const Hop = union(enum) {
    field: []const u8,
    /// `@field(parent, expr)` with a non-literal field name: the hop
    /// cannot resolve a field type, so chains through it stay unknown
    /// (EPH-I0046, the tigerbeetle forest.zig:875 shape).
    dynamic_field,
    index,
    unwrap,
};

/// Peeled address-of chain: `s.a[i].?` roots at `s` with hops
/// outermost-first (resolution walks them in reverse). Chains longer
/// than the buffer are unresolvable. A `@unionInit(U, "f", ...)` root
/// records the union type instead of a name (EPH-I0046).
const ChainInfo = struct {
    root: []const u8 = "",
    root_type_node: OptIndex = .none,
    hops: [8]Hop = undefined,
    hop_count: usize = 0,
    overflow: bool = false,
};

/// Peel one chain hop, advancing `cur` past it. null ends the chain.
/// `@field(parent, "name")` peels as a field hop on `parent`
/// (EPH-I0046): a literal field name resolves the field type, a
/// non-literal one records dynamic_field.
fn peelHop(tree: *const Ast, cur: *NodeIndex) ?Hop {
    cur.* = unwrapGroup(tree, cur.*);
    switch (tree.nodeTag(cur.*)) {
        .field_access => {
            const tok = tree.nodeData(cur.*).node_and_token[1];
            cur.* = tree.nodeData(cur.*).node_and_token[0];
            return .{ .field = tree.tokenSlice(tok) };
        },
        .unwrap_optional => {
            cur.* = tree.nodeData(cur.*).node_and_token[0];
            return .unwrap;
        },
        .array_access => {
            cur.* = tree.nodeData(cur.*).node_and_node[0];
            return .index;
        },
        else => return peelBuiltinHop(tree, cur),
    }
}

/// The @field arm of peelHop, isolated so the tag switch stays flat
/// (EPH-I0046): the parent continues the chain, the field name decides
/// resolvability.
fn peelBuiltinHop(tree: *const Ast, cur: *NodeIndex) ?Hop {
    switch (tree.nodeTag(cur.*)) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    const name = tree.tokenSlice(tree.nodeMainToken(cur.*));
    if (!mem.eql(u8, name, "@field")) return null;
    var buf: [2]NodeIndex = undefined;
    const params = tree.builtinCallParams(&buf, cur.*) orelse return null;
    if (params.len != 2) return null;
    cur.* = params[0];
    const fname = unwrapGroup(tree, params[1]);
    if (tree.nodeTag(fname) != .string_literal) return .dynamic_field;
    const lit = tree.tokenSlice(tree.nodeMainToken(fname));
    return .{ .field = lit[1 .. lit.len - 1] };
}

fn chainInfo(tree: *const Ast, start: NodeIndex) ChainInfo {
    var info = ChainInfo{};
    var cur = start;
    while (peelHop(tree, &cur)) |hop| {
        if (info.hop_count >= info.hops.len) {
            info.overflow = true;
        } else {
            info.hops[info.hop_count] = hop;
            info.hop_count += 1;
        }
    }
    if (tree.nodeTag(cur) == .identifier) {
        info.root = tree.tokenSlice(tree.nodeMainToken(cur));
        return info;
    }
    // @unionInit roots a stack temporary (EPH-I0046): record the union
    // type so resolution can walk its fields.
    if (tree.nodeTag(cur) == .builtin_call or tree.nodeTag(cur) == .builtin_call_two) {
        const name = tree.tokenSlice(tree.nodeMainToken(cur));
        if (mem.eql(u8, name, "@unionInit")) {
            var buf: [2]NodeIndex = undefined;
            const params = tree.builtinCallParams(&buf, cur) orelse return info;
            if (params.len >= 1) info.root_type_node = params[0].toOptional();
        }
    }
    return info;
}

/// Params whose address is provably static or unprovable are
/// excluded: comptime params and comptime-only types live in constant
/// memory. anytype params cannot be proven runtime from the AST.
fn collectParams(
    a: Allocator,
    sctx: ScanCtx,
    proto: NodeIndex,
    scan: *FnScan,
) !void {
    const tree = sctx.tree;
    var buf: [1]NodeIndex = undefined;
    const fp = tree.fullFnProto(&buf, proto) orelse return;
    var it = fp.iterate(tree);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) continue;
        const name_tok = param.name_token orelse continue;
        if (param.comptime_noalias) |t| {
            if (mem.eql(u8, tree.tokenSlice(t), "comptime")) continue;
        }
        var is_pointer = false;
        var provably_array = false;
        var type_node: OptIndex = .none;
        if (param.type_expr) |te| {
            if (isComptimeOnlyType(tree, te)) continue;
            is_pointer = isPointerTypeExpr(tree, te);
            provably_array = typeNodeIsArray(sctx, te);
            type_node = te.toOptional();
        }
        try scan.params.append(a, .{
            .name = tree.tokenSlice(name_tok),
            .is_pointer = is_pointer,
            .type_node = type_node,
            .provably_array = provably_array,
        });
    }
}

/// True when a type expression is provably an array: direct `[N]T` or
/// an alias chain ending at one (`const V = [4]u32;` — EPH-I0046).
/// Everything else stays false, the FN-only direction.
fn typeNodeIsArray(sctx: ScanCtx, node: NodeIndex) bool {
    const flat = flattenAlias(sctx, node, 0);
    return switch (sctx.tree.nodeTag(flat)) {
        .array_type, .array_type_sentinel => true,
        else => false,
    };
}

fn isComptimeOnlyType(tree: *const Ast, node: NodeIndex) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const comptime_types = [_][]const u8{ "comptime_int", "comptime_float", "type" };
    for (comptime_types) |ct| {
        if (mem.eql(u8, name, ct)) return true;
    }
    return false;
}

/// True when a type expression is a pointer/slice type (`*T`, `[]T`,
/// `[*]T`, plus align/sentinel/bitrange variants). Optional-wrapped
/// pointers stay false: `&opt.?` addresses the payload inside the
/// optional's own stack slot, so it remains escapable.
fn isPointerTypeExpr(tree: *const Ast, node: NodeIndex) bool {
    return switch (tree.nodeTag(node)) {
        .ptr_type, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type_bit_range => true,
        else => false,
    };
}

/// Phase 1: all `var` locals — always runtime stack slots. `const`
/// locals are only tracked as aliases (a comptime-known const lives
/// in static memory).
fn collectLocals(
    a: Allocator,
    tree: *const Ast,
    decls: []const NodeIndex,
    scan: *FnScan,
) !void {
    for (decls) |node| {
        const vd = tree.fullVarDecl(node) orelse continue;
        if (!mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "var")) continue;
        // `comptime var` lives in static memory (the comptime string-
        // builder idiom) — its address never refers to the stack frame.
        if (vd.comptime_token != null) continue;
        try scan.locals.append(a, .{
            .name = tree.tokenSlice(vd.ast.mut_token + 1),
            .provably_array = isArrayVarDecl(tree, vd),
            .is_pointer = isPointerVarDecl(tree, vd, scan),
            .type_node = varDeclTypeNode(tree, vd),
        });
    }
}

/// The best available type node for a var local: the explicit annotation,
/// or the type of an explicitly-typed init (`var s = S{...}`).
fn varDeclTypeNode(tree: *const Ast, vd: Ast.full.VarDecl) OptIndex {
    if (vd.ast.type_node != .none) return vd.ast.type_node;
    const init = vd.ast.init_node.unwrap() orelse return .none;
    var buf: [2]NodeIndex = undefined;
    if (tree.fullStructInit(&buf, init)) |si| return si.ast.type_expr;
    if (tree.fullArrayInit(&buf, init)) |ai| return ai.ast.type_expr;
    return .none;
}

/// Pointer-ness of a var local: explicit pointer annotation, an
/// address-of init (`var p = &x;`), or an inferred copy from a known
/// pointer binding (`var q = p;`). Other inferred types stay by-value
/// — the FN-only direction.
fn isPointerVarDecl(tree: *const Ast, vd: Ast.full.VarDecl, scan: *const FnScan) bool {
    if (vd.ast.type_node.unwrap()) |t| return isPointerTypeExpr(tree, t);
    const init = vd.ast.init_node.unwrap() orelse return false;
    const e = unwrapGroup(tree, init);
    if (tree.nodeTag(e) == .address_of) return true;
    if (tree.nodeTag(e) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(e));
    if (scan.paramByName(name)) |p| return p.is_pointer;
    // Local-to-local inference needs source order (use-before-decl is
    // impossible, so the source of the copy is always earlier). The
    // caller sorts decls by first token before this pass.
    if (scan.localByName(name)) |l| return l.is_pointer;
    return false;
}

fn declTokenLessThan(tree: *const Ast, a: NodeIndex, b: NodeIndex) bool {
    return tree.firstToken(a) < tree.firstToken(b);
}

/// Sort declarations into source order: the walker discovers them in
/// DFS pop order. Pointer inference and alias resolution rely on
/// use-before-decl ordering.
fn sortDeclsBySource(tree: *const Ast, decls: []NodeIndex) void {
    std.sort.pdq(NodeIndex, decls, tree, declTokenLessThan);
}

fn isArrayVarDecl(tree: *const Ast, vd: Ast.full.VarDecl) bool {
    if (vd.ast.type_node.unwrap()) |t| {
        switch (tree.nodeTag(t)) {
            .array_type, .array_type_sentinel => return true,
            else => {},
        }
    }
    const init = vd.ast.init_node.unwrap() orelse return false;
    return switch (tree.nodeTag(init)) {
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        => true,
        else => false,
    };
}

/// Bundled immutable context for the collection passes (keeps ≤4 params).
const ScanCtx = struct {
    tree: *const Ast,
    tidx: *const TypeIndex,
    /// The fn body under analysis: scopes TypeIndex lookups (EPH-I0592).
    body: NodeIndex,
    /// Value-breaks recorded by the walker (EPH-I0046): the block
    /// itself never fires — only a proven escape adjudicates.
    breaks: []const NodeIndex = &.{},
    /// Comptime expression ranges: a break inside one is static-safe
    /// and excluded from block-value resolution (EPH-I0046).
    comptime_ranges: []const ComptimeRange = &.{},
};

/// Phase 2: pointer aliases (`const p = &x...;` and the rebound `var
/// p` forms, EPH-I0046). Fixed-point over the decl list so transitive
/// aliases (`const q = p;`) resolve regardless of discovery order.
/// Bounded by one round per declaration.
fn collectAliases(
    a: Allocator,
    sctx: ScanCtx,
    decls: []const NodeIndex,
    scan: *FnScan,
) !void {
    var progress = true;
    var rounds: usize = 0;
    while (progress and rounds <= decls.len) : (rounds += 1) {
        progress = false;
        for (decls) |node| {
            if (try tryCollectAlias(a, sctx, node, scan)) progress = true;
        }
    }
}

fn tryCollectAlias(
    a: Allocator,
    sctx: ScanCtx,
    node: NodeIndex,
    scan: *FnScan,
) !bool {
    const tree = sctx.tree;
    const vd = tree.fullVarDecl(node) orelse return false;
    const is_var = mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "var");
    if (!is_var and !mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return false;
    const name = tree.tokenSlice(vd.ast.mut_token + 1);
    if (scan.aliasRoot(name) != null) return false;
    const init = vd.ast.init_node.unwrap() orelse return false;
    const root = aliasTarget(sctx, scan, init) orelse return false;
    try scan.aliases.append(a, .{
        .name = name,
        .root = root,
        .init = init.toOptional(),
        .is_var = is_var,
        .decl_tok = tree.firstToken(node),
    });
    return true;
}

/// Source-order sort for plain assign records (the walker discovers
/// them in pop order, reverse of source).
fn assignTokLessThan(tree: *const Ast, a: AssignRecord, b: AssignRecord) bool {
    return tree.firstToken(a.node) < tree.firstToken(b.node);
}

/// One plain `=` assign: the node plus its lhs/rhs operand nodes.
const AssignRecord = struct {
    node: NodeIndex,
    lhs: NodeIndex,
    rhs: NodeIndex,
};

/// Source-ordered assign records (EPH-I0046). Fixed cap, FN-only on
/// overflow: an invisible assign can only keep a var alias silent,
/// never a false fire.
const AssignList = struct {
    items: [64]AssignRecord = undefined,
    len: usize = 0,

    fn slice(self: *const AssignList) []const AssignRecord {
        return self.items[0..self.len];
    }
};

/// Build source-ordered assign records for the rebind passes (EPH-I0046).
fn collectAssignRecords(tree: *const Ast, assigns: []const NodeIndex) AssignList {
    var out = AssignList{};
    for (assigns) |node| {
        if (out.len >= out.items.len) break;
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        out.items[out.len] = .{ .node = node, .lhs = lhs, .rhs = rhs };
        out.len += 1;
    }
    std.sort.pdq(AssignRecord, out.items[0..out.len], tree, assignTokLessThan);
    return out;
}

/// The last rebind RHS of a var alias, or null (EPH-I0046). A
/// never-rebound `var p = &x;` is a hard compile error the rule
/// never echoes, so the alias drops.
fn lastRebindRhs(
    tree: *const Ast,
    assigns: []const AssignRecord,
    name: []const u8,
    decl_tok: u32,
) ?NodeIndex {
    var found: ?NodeIndex = null;
    for (assigns) |rec| {
        if (tree.firstToken(rec.node) <= decl_tok) continue;
        const lhs = unwrapGroup(tree, rec.lhs);
        if (tree.nodeTag(lhs) != .identifier) continue;
        if (!mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), name)) continue;
        found = rec.rhs;
    }
    return found;
}

/// Adjudicate var aliases against their rebinds, then re-resolve
/// every alias root against the surviving set (EPH-I0046): no rebind
/// drops (compile-error shape), a non-stack rebind RHS drops, and a
/// root naming a dropped alias drops too (transitive,
/// fixpoint-bounded).
fn resolveAliasRebinds(sctx: ScanCtx, scan: *FnScan, records: *const AssignList) void {
    for (scan.aliases.items) |*al| {
        if (!al.is_var) continue;
        const rhs = lastRebindRhs(sctx.tree, records.slice(), al.name, al.decl_tok) orelse {
            al.dropped = true;
            continue;
        };
        al.init = rhs.toOptional();
    }
    var rounds: usize = 0;
    while (reresolveAliasRoots(sctx, scan) and rounds <= scan.aliases.items.len) : (rounds += 1) {}
    var i: usize = 0;
    while (i < scan.aliases.items.len) {
        if (scan.aliases.items[i].dropped) {
            scan.aliases.items[i] = scan.aliases.items[scan.aliases.items.len - 1];
            scan.aliases.items.len -= 1;
        } else {
            i += 1;
        }
    }
}

/// One fixpoint round: re-resolve every surviving alias root against
/// the current set, dropping the unresolvable. Returns true when
/// anything changed.
fn reresolveAliasRoots(sctx: ScanCtx, scan: *FnScan) bool {
    var changed = false;
    for (scan.aliases.items) |*al| {
        if (al.dropped) continue;
        const init = al.init.unwrap() orelse {
            al.dropped = true;
            changed = true;
            continue;
        };
        const root = aliasTarget(sctx, scan, init) orelse {
            al.dropped = true;
            changed = true;
            continue;
        };
        if (mem.eql(u8, al.root, root)) continue;
        al.root = root;
        changed = true;
    }
    return changed;
}

/// The inner operand of an @as/@ptrCast builtin call, or null
/// (EPH-I0046). Shared by the return classifier and the alias
/// resolver: both peel the evasion layers to the address-of beneath.
fn peelCastBuiltin(tree: *const Ast, node: NodeIndex) ?NodeIndex {
    switch (tree.nodeTag(node)) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    var buf: [2]NodeIndex = undefined;
    const params = tree.builtinCallParams(&buf, node) orelse return null;
    if (mem.eql(u8, name, "@as")) {
        if (params.len != 2) return null;
        return unwrapGroup(tree, params[1]);
    }
    if (mem.eql(u8, name, "@ptrCast")) {
        if (params.len != 1) return null;
        return unwrapGroup(tree, params[0]);
    }
    return null;
}

/// The stack local or param an alias initializer points into, if
/// provable. A chained address resolved safe/unknown does not point
/// into the stack frame — no alias. Cast layers peel. A labeled-block
/// Switch resolves too (EPH-I0046, EPH-I1185).
fn aliasTarget(sctx: ScanCtx, scan: *const FnScan, init: NodeIndex) ?[]const u8 {
    var e = unwrapGroup(sctx.tree, init);
    while (true) {
        const tag = sctx.tree.nodeTag(e);
        if (tag == .address_of) return aliasAddressTarget(sctx, scan, e);
        if (tag == .identifier) {
            const name = sctx.tree.tokenSlice(sctx.tree.nodeMainToken(e));
            return scan.aliasRoot(name);
        }
        if (isLabeledBlockTag(tag)) return blockValueRoot(sctx, scan, e, .commit);
        if (tag == .@"switch" or tag == .switch_comma) return switchValueRoot(sctx, scan, e);
        e = peelCastBuiltin(sctx.tree, e) orelse return null;
    }
}

/// The stack root a switch expression's value points into
/// (EPH-I1185): every prong must be a labeled block (group and cast
/// layers allowed) resolving to the same root. Else the switch stays
/// unresolvable (FN-only).
fn switchValueRoot(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?[]const u8 {
    const sw = sctx.tree.fullSwitch(node) orelse return null;
    var found: ?[]const u8 = null;
    for (sw.ast.cases) |case_node| {
        const c = sctx.tree.fullSwitchCase(case_node) orelse return null;
        // Peel groups and @as/@ptrCast layers down to the block.
        var e = unwrapGroup(sctx.tree, c.ast.target_expr);
        while (!isLabeledBlockTag(sctx.tree.nodeTag(e))) {
            e = peelCastBuiltin(sctx.tree, e) orelse return null;
        }
        const target = blockValueRoot(sctx, scan, e, .commit) orelse return null;
        if (found == null) {
            found = target;
            continue;
        }
        if (!mem.eql(u8, found.?, target)) return null;
    }
    return found;
}

fn isLabeledBlockTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

fn aliasAddressTarget(sctx: ScanCtx, scan: *const FnScan, amp: NodeIndex) ?[]const u8 {
    const info = chainInfo(sctx.tree, sctx.tree.nodeData(amp).node);
    if (info.root.len == 0) return null;
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (info.hop_count > 0 and !chainIsUnsafe(sctx, info, bind)) return null;
    return info.root;
}

/// The chain-relevant view of a binding (param or local).
const Bind = struct {
    is_pointer: bool,
    type_node: OptIndex,
    /// Bare `&param` is missed by Sema (flag). Bare `&var` is a hard
    /// compile error only at the return sink (store: silent, EPH-I1210).
    is_param: bool,
};

/// Resolve a chain-root identifier to its binding, params first.
fn bindForRoot(name: []const u8, scan: *const FnScan) ?Bind {
    if (scan.paramByName(name)) |p| {
        return .{ .is_pointer = p.is_pointer, .type_node = p.type_node, .is_param = true };
    }
    if (scan.localByName(name)) |l| {
        return .{ .is_pointer = l.is_pointer, .type_node = l.type_node, .is_param = false };
    }
    return null;
}

fn chainIsUnsafe(sctx: ScanCtx, info: ChainInfo, bind: Bind) bool {
    if (bind.is_pointer) return finalHopIsOwnSlot(sctx, info, bind);
    return resolveChainSafety(sctx, info, bind.type_node) == .unsafe;
}

/// The slot-address discrimination for pointer/slice roots (EPH-I1122):
/// a lone `.len`/`.ptr` field hop on a slice root addresses the pointer
/// value stored in the root's own stack slot, so the chain is unsafe.
/// Every other hop shape stays caller-owned memory and silent. The
/// `.many` arm is defensive only: `[*]T` carries no field access.
fn finalHopIsOwnSlot(sctx: ScanCtx, info: ChainInfo, bind: Bind) bool {
    if (info.hop_count != 1) return false;
    const field = switch (info.hops[0]) {
        .field => |f| f,
        else => return false,
    };
    if (!mem.eql(u8, field, "len") and !mem.eql(u8, field, "ptr")) return false;
    const tn = bind.type_node.unwrap() orelse return false;
    const pt = sctx.tree.fullPtrType(tn) orelse return false;
    return switch (pt.size) {
        .slice, .many => true,
        else => false,
    };
}

// ============================================================================
// ZA111 return classification + emission
// ============================================================================

/// How the stack reference escapes the function (EPH-I0046): through
/// a return, an out-param store, or a payload-capture return. The
/// labeled-block break form does not exist — the block's value fires
/// only when a consumer provably carries it out of the function.
const EscapeForm = enum { returned, out_param, capture };

const Finding = struct {
    /// Stack local or param the returned pointer/slice refers to.
    name: []const u8,
    /// Alias the pointer was returned through.
    via: ?[]const u8,
    is_slice: bool,
    is_param: bool = false,
    /// @unionInit-temporary roots carry no binding name (EPH-I0046).
    is_temporary: bool = false,
    escape: EscapeForm = .returned,
};

fn classifyReturn(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?Finding {
    const expr = sctx.tree.nodeData(node).opt_node.unwrap() orelse return null;
    const e = unwrapGroup(sctx.tree, expr);
    return switch (sctx.tree.nodeTag(e)) {
        .address_of => classifyAddressOf(sctx, scan, e),
        .slice_open, .slice, .slice_sentinel => classifySlice(sctx, scan, e),
        .identifier => classifyAliasReturn(sctx, scan, e),
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => blk: {
            break :blk classifyBuiltinReturn(sctx, scan, e);
        },
        .block, .block_semicolon => classifyBlockReturn(sctx, scan, e),
        .block_two, .block_two_semicolon => classifyBlockReturn(sctx, scan, e),
        else => null,
    };
}

/// A labeled block returned directly (EPH-I0046): the return IS the
/// escape, so the block's resolved stack value fires. A bare `&v`
/// break here is compiler-caught (probed 0.16.0) and stays silent.
fn classifyBlockReturn(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?Finding {
    const root = blockValueRoot(sctx, scan, node, .skip) orelse return null;
    return .{
        .name = root,
        .via = null,
        .is_slice = false,
        .is_param = scan.paramByName(root) != null,
    };
}

/// True when a value-break names the block's label (EPH-I1183):
/// unlabeled breaks and breaks naming an inner block stay out.
fn breakLabelMatches(tree: *const Ast, brk: NodeIndex, label_name: []const u8) bool {
    const brk_label = tree.nodeData(brk).opt_token_and_opt_node[0].unwrap() orelse return false;
    return mem.eql(u8, tree.tokenSlice(brk_label), label_name);
}

/// True when `target` matches a committed root, or no root is
/// committed yet (EPH-I1221): the first break always commits. Later
/// Breaks must match or the block has no single root.
fn sameRoot(committed: ?[]const u8, target: []const u8) bool {
    return if (committed) |root| mem.eql(u8, root, target) else true;
}

/// The stack root a labeled block's value provably points into, or
/// null. The value comes from the block's value-breaks: when every
/// break resolves to a stack root, the value is a stack pointer on
/// every path (EPH-I0046). A comptime-range break is static-safe and
/// excluded. An unresolvable break or DISTINCT cross-break roots make
/// the whole block unresolvable (FN-only, EPH-I1221): naming only the
/// last break would misattribute the escape. The block itself never
/// fires — only a consumer that provably escapes adjudicates, so the
/// sig merlin.zig shape and a discarded-statement block stay silent.
/// Label-aware (EPH-I1183): only breaks naming this block's label set
/// its value.
///
/// `bare`: the sink's BarePolicy — the return sink passes `.skip`
/// (compiler-caught, probed 0.16.0), the alias and store sinks pass
/// `.commit` (Sema-silent, probe-pinned, EPH-I1210). The field form
/// (`&v.a`) is Sema-silent everywhere and fires.
fn blockValueRoot(
    sctx: ScanCtx,
    scan: *const FnScan,
    block: NodeIndex,
    bare: BarePolicy,
) ?[]const u8 {
    const block_first = sctx.tree.firstToken(block);
    const block_last = sctx.tree.lastToken(block);
    // Unlabeled blocks carry no value-breaks (EPH-I1183).
    const label_tok = blockLabelToken(sctx.tree, block) orelse return null;
    const label_name = sctx.tree.tokenSlice(label_tok);
    var found: ?[]const u8 = null;
    for (sctx.breaks) |brk| {
        const tok = sctx.tree.firstToken(brk);
        if (tok < block_first or tok > block_last) continue;
        if (insideComptime(sctx.comptime_ranges, tok)) continue;
        if (!breakLabelMatches(sctx.tree, brk, label_name)) continue;
        const operand = sctx.tree.nodeData(brk).opt_token_and_opt_node[1].unwrap() orelse continue;
        const target = blockBreakTarget(sctx, scan, operand, bare) orelse return null;
        if (!sameRoot(found, target)) return null;
        found = target;
    }
    return found;
}

/// The label token naming a block (`blk:`), or null when unlabeled
/// (EPH-I1183): the identifier-colon pair before the lbrace.
fn blockLabelToken(tree: *const Ast, block: NodeIndex) ?Ast.TokenIndex {
    const lbrace = tree.nodeMainToken(block);
    if (!tree.isTokenPrecededByTags(lbrace, &.{ .identifier, .colon })) return null;
    return lbrace - 2;
}

/// A sink's bare-&var policy (ZA506, EPH-I1081): `.skip` keeps the
/// bare break silent, `.commit` resolves it to its root.
const BarePolicy = enum { skip, commit };

/// The stack root one labeled-block break operand points into, or
/// null. A direct address-of operand applies the sink's bare policy.
/// Any other shape resolves through the alias machinery (EPH-I0046).
fn blockBreakTarget(
    sctx: ScanCtx,
    scan: *const FnScan,
    operand: NodeIndex,
    bare: BarePolicy,
) ?[]const u8 {
    const e = unwrapGroup(sctx.tree, operand);
    if (sctx.tree.nodeTag(e) == .address_of) {
        const info = chainInfo(sctx.tree, sctx.tree.nodeData(e).node);
        if (info.root.len == 0) return null;
        const bind = bindForRoot(info.root, scan) orelse return null;
        if (info.hop_count == 0 and bare == .skip) return null;
        if (info.hop_count > 0 and !chainIsUnsafe(sctx, info, bind)) return null;
        return info.root;
    }
    return aliasTarget(sctx, scan, e);
}

/// `return @as(*u32, @ptrCast(&x));` — peel the cast evasion layers
/// and classify the address-of beneath (EPH-I0046). Other builtins
/// stay silent. The peel allows a bare `&x`: the compiler catches the
/// bare form, but @ptrCast hides it (probe-verified silent on 0.16.0).
fn classifyBuiltinReturn(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?Finding {
    var cur = node;
    while (true) {
        cur = unwrapGroup(sctx.tree, cur);
        switch (sctx.tree.nodeTag(cur)) {
            .address_of => return classifyAddressOfAllowBare(sctx, scan, cur),
            else => cur = peelCastBuiltin(sctx.tree, cur) orelse return null,
        }
    }
}

/// classifyAddressOf with the bare-local form allowed: inside a cast
/// peel the compiler's bare-&var check is evaded, so the bare form
/// fires (EPH-I0046).
fn classifyAddressOfAllowBare(sctx: ScanCtx, scan: *const FnScan, amp: NodeIndex) ?Finding {
    const info = chainInfo(sctx.tree, sctx.tree.nodeData(amp).node);
    if (info.root.len == 0) return classifyTemporaryAddressOf(sctx, info);
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (info.hop_count == 0) {
        return .{ .name = info.root, .via = null, .is_slice = false, .is_param = bind.is_param };
    }
    if (!chainIsUnsafe(sctx, info, bind)) return null;
    return .{ .name = info.root, .via = null, .is_slice = false, .is_param = bind.is_param };
}

fn classifyAddressOf(sctx: ScanCtx, scan: *const FnScan, amp: NodeIndex) ?Finding {
    const info = chainInfo(sctx.tree, sctx.tree.nodeData(amp).node);
    if (info.root.len == 0) return classifyTemporaryAddressOf(sctx, info);
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (info.hop_count == 0) {
        // Bare &var is a hard compile error (Zig Sema) — never echo it.
        if (!bind.is_param) return null;
        return .{ .name = info.root, .via = null, .is_slice = false, .is_param = true };
    }
    if (!chainIsUnsafe(sctx, info, bind)) return null;
    return .{ .name = info.root, .via = null, .is_slice = false, .is_param = bind.is_param };
}

/// A chain rooted at a `@unionInit(...)` temporary (EPH-I0046): the
/// union value materializes in a stack slot, so a chain whose hops
/// stay inside the slot is escapable. A pointer/slice field hop
/// leaves the slot. A bare `&@unionInit(...)` is an rvalue address
/// (a compile error) and stays silent.
fn classifyTemporaryAddressOf(sctx: ScanCtx, info: ChainInfo) ?Finding {
    if (info.hop_count == 0) return null;
    const tn = info.root_type_node.unwrap() orelse return null;
    if (resolveChainSafety(sctx, info, tn.toOptional()) != .unsafe) return null;
    return .{ .name = "temporary", .via = null, .is_slice = false, .is_temporary = true };
}

/// The stack array a slice expression provably slices, or null: an
/// identifier local/param with a provable array type, or a field chain
/// whose hops stay inside a by-value stack binding and end at an array
/// (EPH-I0046 — `holder.arr[0..2]`, array-param `a[0..2]`). Slicing a
/// slice or a pointee copies a caller-owned pointer.
fn sliceRoot(sctx: ScanCtx, scan: *const FnScan, sliced: NodeIndex) ?[]const u8 {
    const s = unwrapGroup(sctx.tree, sliced);
    if (sctx.tree.nodeTag(s) == .identifier) {
        return sliceIdentRoot(sctx, scan, s);
    }
    const info = chainInfo(sctx.tree, s);
    if (info.root.len == 0) return null;
    const bind = bindForRoot(info.root, scan) orelse return null;
    if (!sliceChainIsStack(sctx, info, bind)) return null;
    return info.root;
}

/// The identifier arm of sliceRoot (EPH-I0046): a local or param whose
/// type is a provable array.
fn sliceIdentRoot(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?[]const u8 {
    const name = sctx.tree.tokenSlice(sctx.tree.nodeMainToken(node));
    if (scan.localByName(name)) |l| {
        if (!l.provably_array) return null;
        return name;
    }
    if (scan.paramByName(name)) |p| {
        if (!p.provably_array) return null;
        return name;
    }
    return null;
}

/// True when a chain whose final use is a SLICE provably slices a stack
/// array: every hop must stay inside the root's slot and the last type
/// must be an array (EPH-I0046). A pointer/slice hop leaves the slot —
/// caller memory — and stays silent.
fn sliceChainIsStack(sctx: ScanCtx, info: ChainInfo, bind: Bind) bool {
    if (info.overflow or bind.is_pointer) return false;
    const root_node = bind.type_node.unwrap() orelse return false;
    var cur = classifyTypeNode(sctx.tree, root_node);
    var hi = info.hop_count;
    while (hi > 0) {
        hi -= 1;
        cur = stepThroughHop(sctx, cur, info.hops[hi]);
        if (!stepStaysInSlot(cur)) return false;
    }
    return switch (cur) {
        .array_elem => true,
        else => false,
    };
}

/// True while a resolution step keeps the address inside the root's
/// slot: arrays, optionals, and named types qualify. A pointer/slice
/// Hop or an unresolvable type leaves the slot.
fn stepStaysInSlot(cur: TypeStep) bool {
    return switch (cur) {
        .safe, .unknown => false,
        else => true,
    };
}

fn classifySlice(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?Finding {
    const s = sctx.tree.fullSlice(node) orelse return null;
    const root = sliceRoot(sctx, scan, s.ast.sliced) orelse return null;
    return .{
        .name = root,
        .via = null,
        .is_slice = true,
        .is_param = scan.paramByName(root) != null,
    };
}

fn classifyAliasReturn(sctx: ScanCtx, scan: *const FnScan, node: NodeIndex) ?Finding {
    const name = sctx.tree.tokenSlice(sctx.tree.nodeMainToken(node));
    // Payload captures first: a capture shadows any same-named outer
    // binding inside its body range (EPH-I0046).
    if (captureForReturn(sctx, scan, node, name)) |cap| {
        return .{
            .name = cap.root,
            .via = name,
            .is_slice = false,
            .is_param = cap.is_param,
            .escape = .capture,
        };
    }
    if (scan.aliasRoot(name)) |root| {
        return .{
            .name = root,
            .via = name,
            .is_slice = false,
            .is_param = scan.paramByName(root) != null,
        };
    }
    if (scan.sliceBindingRoot(name)) |root| {
        return .{
            .name = root,
            .via = name,
            .is_slice = true,
            .is_param = scan.paramByName(root) != null,
        };
    }
    return null;
}

/// The pointer capture a return operand names, when the reference sits
/// inside the capture's body range (EPH-I0046).
fn captureForReturn(
    sctx: ScanCtx,
    scan: *const FnScan,
    ident: NodeIndex,
    name: []const u8,
) ?Capture {
    const tok = sctx.tree.firstToken(ident);
    for (scan.captures.items) |cap| {
        if (!mem.eql(u8, cap.name, name)) continue;
        if (tok < cap.first_tok or tok > cap.last_tok) continue;
        return cap;
    }
    return null;
}

/// The root identifier of an assign lhs chain (deref/field/unwrap/
/// array-access hops peeled), or null for compound lhss (EPH-I0046).
/// `out.* = x` and `out.field = x` both root at `out`. Other shapes
/// stay unresolvable.
fn assignLhsRoot(tree: *const Ast, lhs: NodeIndex) ?[]const u8 {
    var cur = lhs;
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        cur = unwrapGroup(tree, cur);
        if (tree.nodeTag(cur) == .identifier) {
            return tree.tokenSlice(tree.nodeMainToken(cur));
        }
        cur = peelAssignLhsHop(tree, cur) orelse return null;
    }
    return null;
}

/// One lhs hop for assignLhsRoot: deref/field/unwrap/array-access
/// descend to their base operand. Anything else ends the peel.
fn peelAssignLhsHop(tree: *const Ast, cur: NodeIndex) ?NodeIndex {
    return switch (tree.nodeTag(cur)) {
        .deref => tree.nodeData(cur).node,
        .field_access, .unwrap_optional => tree.nodeData(cur).node_and_token[0],
        .array_access => tree.nodeData(cur).node_and_node[0],
        else => null,
    };
}

/// Out-param escape (EPH-I0046): `out.* = &local;` stores a stack
/// address into a pointer param's pointee — caller storage that
/// outlives the frame. The lhs must root at a pointer-typed param (a
/// by-value param's field write touches a local copy). The rhs must
/// Resolve to a stack root.
fn checkEscapeAssign(
    ctx: *const Za111Ctx,
    sctx: ScanCtx,
    scan: *const FnScan,
    node: NodeIndex,
) !void {
    const lhs, const rhs = sctx.tree.nodeData(node).node_and_node;
    const root_name = assignLhsRoot(sctx.tree, lhs) orelse return;
    const param = scan.paramByName(root_name) orelse return;
    if (!param.is_pointer) return;
    const target = assignRhsTarget(sctx, scan, rhs) orelse return;
    try emitZa111(ctx, node, .{
        .name = target,
        .via = null,
        .is_slice = false,
        .is_param = scan.paramByName(target) != null,
        .escape = .out_param,
    });
}

/// The stack root an out-store rhs points into. A labeled-block rhs
/// uses the alias posture (bare = .commit): the 0.16.0 probe shows
/// Sema stays silent on a bare `&var` break feeding a store, so the
/// bare form fires here (EPH-I1210) beside the field form (EPH-I0046).
/// Other shapes resolve via aliasTarget.
fn assignRhsTarget(sctx: ScanCtx, scan: *const FnScan, rhs: NodeIndex) ?[]const u8 {
    const e = unwrapGroup(sctx.tree, rhs);
    if (isLabeledBlockTag(sctx.tree.nodeTag(e))) return blockValueRoot(sctx, scan, e, .commit);
    return aliasTarget(sctx, scan, rhs);
}

/// Bundled inputs for the slice-binding collection (EPH-I0046): keeps
/// the collector within the parameter threshold.
const BindingCollectCtx = struct {
    a: Allocator,
    sctx: ScanCtx,
    records: AssignList,
};

/// Collect slice bindings (`const/var s = arr[a..b];` with a provable
/// stack-array root — EPH-I0046). Var bindings follow the pointer-alias
/// rebind rule: no rebind drops, a non-array rebind RHS drops. Slice
/// rebind RHSs resolve against locals and params only, which never
/// drop — one pass suffices.
fn collectSliceBindings(
    ctx: BindingCollectCtx,
    decls: []const NodeIndex,
    scan: *FnScan,
) !void {
    for (decls) |node| {
        try collectOneSliceBinding(ctx, node, scan);
    }
}

fn collectOneSliceBinding(ctx: BindingCollectCtx, node: NodeIndex, scan: *FnScan) !void {
    const tree = ctx.sctx.tree;
    const vd = tree.fullVarDecl(node) orelse return;
    const is_var = mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "var");
    if (!is_var and !mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "const")) return;
    const name = tree.tokenSlice(vd.ast.mut_token + 1);
    const init = vd.ast.init_node.unwrap() orelse return;
    const e = unwrapGroup(tree, init);
    if (!isSliceTag(tree.nodeTag(e))) return;
    var root = sliceRoot(ctx.sctx, scan, tree.fullSlice(e).?.ast.sliced) orelse return;
    if (is_var) {
        const rebind = lastRebindRhs(tree, ctx.records.slice(), name, tree.firstToken(node)) orelse
            return;
        const re = unwrapGroup(tree, rebind);
        if (!isSliceTag(tree.nodeTag(re))) return;
        root = sliceRoot(ctx.sctx, scan, tree.fullSlice(re).?.ast.sliced) orelse return;
    }
    try scan.slice_bindings.append(ctx.a, .{
        .name = name,
        .root = root,
        .is_var = is_var,
        .decl_tok = tree.firstToken(node),
    });
}

fn isSliceTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .slice_open, .slice, .slice_sentinel => true,
        else => false,
    };
}

/// Resolve the walker's capture records against the collected bindings
/// (EPH-I0046). By-value captures return values — skip. An if-capture
/// roots at the condition operand's own slot: any local or param
/// qualifies, pointer-typed included. A for-capture roots at the
/// input: `&arr` or a by-value provable array. Slice and pointer
/// Inputs iterate caller memory. Nested same-name captures resolve
/// first-match: both roots are stack bindings, so only the named root
/// can misattribute.
fn collectCaptures(
    a: Allocator,
    sctx: ScanCtx,
    records: []const CaptureRecord,
    scan: *FnScan,
) !void {
    for (records) |rec| {
        if (!rec.is_ptr) continue;
        const root_name = captureRootName(sctx, scan, rec) orelse continue;
        try scan.captures.append(a, .{
            .name = rec.name,
            .root = root_name,
            .is_param = scan.paramByName(root_name) != null,
            .first_tok = rec.first_tok,
            .last_tok = rec.last_tok,
        });
    }
}

fn captureRootName(sctx: ScanCtx, scan: *const FnScan, rec: CaptureRecord) ?[]const u8 {
    var root_node = unwrapGroup(sctx.tree, rec.root);
    if (rec.is_for and sctx.tree.nodeTag(root_node) == .address_of) {
        root_node = unwrapGroup(sctx.tree, sctx.tree.nodeData(root_node).node);
    }
    if (sctx.tree.nodeTag(root_node) != .identifier) return null;
    const name = sctx.tree.tokenSlice(sctx.tree.nodeMainToken(root_node));
    if (!rec.is_for) return if (bindForRoot(name, scan) != null) name else null;
    if (scan.localByName(name)) |l| return if (l.provably_array and !l.is_pointer) name else null;
    if (scan.paramByName(name)) |p| return if (p.provably_array and !p.is_pointer) name else null;
    return null;
}

pub const Za111Ctx = struct {
    a: Allocator,
    /// The parsed tree under analysis. The parse lives in ast_tier.zig
    /// (AstContext), keeping the split acyclic (EPH-I0601).
    tree: *const Ast,
    tidx: *const TypeIndex,
    path: []const u8,
    out: *std.ArrayListUnmanaged(Issue),
};

fn emitZa111(ctx: *const Za111Ctx, node: NodeIndex, f: Finding) !void {
    const what = if (f.is_param) "parameter" else "local";
    const msg = switch (f.escape) {
        .out_param => try std.fmt.allocPrint(ctx.a, "stored pointer to stack {s} " ++
            "'{s}' into an out parameter — its storage expires when the " ++
            "function returns", .{ what, f.name }),
        .capture => try std.fmt.allocPrint(ctx.a, "returned payload pointer refers " ++
            "to stack {s} '{s}' — its storage expires when the function " ++
            "returns", .{ what, f.name }),
        .returned => if (f.is_temporary)
            try std.fmt.allocPrint(ctx.a, "returned pointer refers to a stack " ++
                "temporary — its storage expires when the function returns", .{})
        else if (f.is_slice)
            try std.fmt.allocPrint(ctx.a, "returned slice refers to stack array " ++
                "'{s}' — its storage expires when the function returns", .{f.name})
        else if (f.via) |via|
            try std.fmt.allocPrint(ctx.a, "returned pointer '{s}' refers to stack {s} " ++
                "'{s}' — its storage expires when the function returns", .{ via, what, f.name })
        else
            try std.fmt.allocPrint(ctx.a, "returned pointer refers to stack {s} " ++
                "'{s}' — its storage expires when the function returns", .{ what, f.name }),
    };
    // On append failure the message must not leak (EPH-I0594).
    errdefer ctx.a.free(msg);
    const loc = ctx.tree.tokenLocation(0, ctx.tree.firstToken(node));
    try ctx.out.append(ctx.a, .{
        .file = ctx.path,
        .line = loc.line + 1,
        .col = loc.column + 1,
        .severity = .err,
        .rule = RULE_ZA111,
        .message = msg,
        .message_owned = true,
        .help = "copy the value out, heap-allocate it, " ++
            "or have the caller provide the buffer",
    });
}

fn analyzeOneFn(
    ctx: *const Za111Ctx,
    proto: NodeIndex,
    body: NodeIndex,
) !void {
    var walker = Walker{ .a = ctx.a, .tree = ctx.tree };
    defer walker.deinit();
    try walker.run(body);
    sortDeclsBySource(ctx.tree, walker.var_decls.items);

    const sctx = ScanCtx{
        .tree = ctx.tree,
        .tidx = ctx.tidx,
        .body = body,
        .breaks = walker.breaks.items,
        .comptime_ranges = walker.comptime_ranges.items,
    };
    var scan = FnScan{};
    defer scan.deinit(ctx.a);
    try collectParams(ctx.a, sctx, proto, &scan);
    try collectLocals(ctx.a, sctx.tree, walker.var_decls.items, &scan);
    try collectAliases(ctx.a, sctx, walker.var_decls.items, &scan);
    const records = collectAssignRecords(ctx.tree, walker.assigns.items);
    resolveAliasRebinds(sctx, &scan, &records);
    try collectSliceBindings(
        .{ .a = ctx.a, .sctx = sctx, .records = records },
        walker.var_decls.items,
        &scan,
    );
    try collectCaptures(ctx.a, sctx, walker.captures.items, &scan);

    for (walker.returns.items) |ret| {
        if (insideComptime(walker.comptime_ranges.items, ctx.tree.firstToken(ret))) continue;
        const f = classifyReturn(sctx, &scan, ret) orelse continue;
        try emitZa111(ctx, ret, f);
    }
    for (walker.assigns.items) |asgn| {
        if (insideComptime(walker.comptime_ranges.items, ctx.tree.firstToken(asgn))) continue;
        try checkEscapeAssign(ctx, sctx, &scan, asgn);
    }
}

pub fn analyzeFileZa111(ctx: *const Za111Ctx) !void {
    const tree = ctx.tree;
    var i: usize = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const node: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto, const body = tree.nodeData(node).node_and_node;
        try analyzeOneFn(ctx, proto, body);
    }
}

test "walker: assign_destructure pushes lhs bindings (EPH-I0596)" {
    const a = std.testing.allocator;
    const src =
        \\const S = struct { a: u32 };
        \\fn f(pair: [2]S) void {
        \\    var x, var y = pair;
        \\    _ = x;
        \\    _ = y;
        \\}
    ;
    // This file stays acyclic, so the test parses directly (EPH-I0601).
    const zsource = try a.dupeZ(u8, src);
    defer a.free(zsource);
    var tree = try Ast.parse(a, zsource, .zig);
    defer tree.deinit(a);
    var body: ?NodeIndex = null;
    var i: usize = 1;
    while (i < tree.nodes.len) : (i += 1) {
        const n: NodeIndex = @enumFromInt(@as(u32, @intCast(i)));
        if (tree.nodeTag(n) == .fn_decl) {
            body = tree.nodeData(n).node_and_node[1];
        }
    }
    var walker = Walker{ .a = a, .tree = &tree };
    defer walker.deinit();
    try walker.run(body.?);
    // Both destructure lhs bindings must enter FnScan via the walker.
    var found_x = false;
    var found_y = false;
    for (walker.var_decls.items) |n| {
        const vd = tree.fullVarDecl(n).?;
        const name = tree.tokenSlice(vd.ast.mut_token + 1);
        found_x = found_x or mem.eql(u8, name, "x");
        found_y = found_y or mem.eql(u8, name, "y");
    }
    try std.testing.expect(found_x);
    try std.testing.expect(found_y);
}

test "blockValueRoot: distinct multi-break roots stay silent (EPH-I1221)" {
    const a = std.testing.allocator;
    const src =
        \\const S = struct { a: u32 };
        \\fn f(x: u32) *u32 {
        \\    var s = S{ .a = x };
        \\    var t = S{ .a = x + 1 };
        \\    return b: {
        \\        if (x > 0) break :b &s.a;
        \\        break :b &t.a;
        \\    };
        \\}
        \\fn g(x: u32) *u32 {
        \\    var s = S{ .a = x };
        \\    return b: {
        \\        if (x > 0) break :b &s.a;
        \\        break :b &s.a;
        \\    };
        \\}
    ;
    // This file stays acyclic, so the test drives the pipeline
    // directly (EPH-I0601).
    const zsource = try a.dupeZ(u8, src);
    defer a.free(zsource);
    var tree = try Ast.parse(a, zsource, .zig);
    defer tree.deinit(a);
    var tidx = try buildTypeIndex(a, &tree);
    defer tidx.deinit(a);
    var out: std.ArrayListUnmanaged(Issue) = .empty;
    defer types.deinitIssues(&out, a);
    const ctx = Za111Ctx{ .a = a, .tree = &tree, .tidx = &tidx, .path = "test.zig", .out = &out };
    try analyzeFileZa111(&ctx);
    // f's distinct roots (s vs t) stay silent. G's same-root breaks
    // Still fire once naming 's'.
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(mem.indexOf(u8, out.items[0].message, "'s'") != null);
    try std.testing.expect(mem.indexOf(u8, out.items[0].message, "'t'") == null);
}
