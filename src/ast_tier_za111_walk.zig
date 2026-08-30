// Rhyos Labs - Ephor
// ZA111 walker: the AST body-walk machinery, split out of
// ast_tier_za111.zig to keep both halves under the 64 KiB AST-tier
// input cap (EPH-I0601, EPH-I0046). This file owns the fn-body DFS and
// the node records. The rule file owns collection and classification.
// Copyright (C) 2025 Rhyos Labs LLC
// SPDX-License-Identifier: MIT

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;
const OptIndex = Ast.Node.OptionalIndex;

/// A payload capture recorded during the walk (EPH-I0046).
pub const CaptureRecord = struct {
    name: []const u8,
    is_ptr: bool,
    root: NodeIndex,
    is_for: bool,
    first_tok: u32,
    last_tok: u32,
};

/// The token range of one `comptime` expression (EPH-I0046): every
/// address inside a comptime block is static-safe, so escape checks
/// skip anchors within one.
pub const ComptimeRange = struct {
    first: u32,
    last: u32,
};

/// True when a token sits inside any recorded comptime range.
pub fn insideComptime(ranges: []const ComptimeRange, tok: u32) bool {
    for (ranges) |r| {
        if (tok >= r.first and tok <= r.last) return true;
    }
    return false;
}

// Body walker
// ============================================================================
//
// Children are reached through the tree's typed full.* helpers plus a
// per-tag shape switch. Nested container declarations are a hard
// boundary: their methods are separate functions, reached by the
// file-wide fn_decl scan.
//
// Coverage policy: an unlisted tag pushes no children — false negative
// at worst, never a crash or false positive. `await` needs no arm (async
// removed in 0.15, EPH-I0596). `assign_destructure` pushes its lhs
// bindings so destructured var names enter FnScan (EPH-I0596).
pub const Walker = struct {
    a: Allocator,
    tree: *const Ast,
    stack: std.ArrayListUnmanaged(NodeIndex) = .empty,
    var_decls: std.ArrayListUnmanaged(NodeIndex) = .empty,
    returns: std.ArrayListUnmanaged(NodeIndex) = .empty,
    /// Labeled-block breaks with a value operand (`break :blk &x;`,
    /// EPH-I0046): these records resolve the block's value. Only a
    /// Consumer that provably escapes adjudicates (the block itself
    /// never fires).
    breaks: std.ArrayListUnmanaged(NodeIndex) = .empty,
    /// Plain `=` assignments: out-param escapes and var-alias rebinds
    /// resolve through them (EPH-I0046).
    assigns: std.ArrayListUnmanaged(NodeIndex) = .empty,
    /// Payload captures (`if (o) |*p|`, `for (&a) |*p|`,
    /// `while (o) |*p|` — EPH-I0046, EPH-I1184).
    captures: std.ArrayListUnmanaged(CaptureRecord) = .empty,
    /// `comptime` expression token ranges (EPH-I0046): escape checks
    /// skip anchors inside one — comptime addresses are static-safe.
    comptime_ranges: std.ArrayListUnmanaged(ComptimeRange) = .empty,

    pub fn deinit(self: *Walker) void {
        self.stack.deinit(self.a);
        self.var_decls.deinit(self.a);
        self.returns.deinit(self.a);
        self.breaks.deinit(self.a);
        self.assigns.deinit(self.a);
        self.captures.deinit(self.a);
        self.comptime_ranges.deinit(self.a);
    }

    fn push(self: *Walker, node: NodeIndex) !void {
        try self.stack.append(self.a, node);
    }

    fn pushOpt(self: *Walker, node: OptIndex) !void {
        try self.push(node.unwrap() orelse return);
    }

    fn pushAll(self: *Walker, nodes: []const NodeIndex) !void {
        for (nodes) |n| try self.push(n);
    }

    /// DFS over one function body, recording var decls, returns, value
    /// breaks, plain assigns, and payload captures.
    pub fn run(self: *Walker, body: NodeIndex) !void {
        try self.push(body);
        while (self.stack.pop()) |node| {
            try self.recordNode(node);
            try self.pushChildren(node);
        }
    }

    /// Record the node kind the analysis passes consume (EPH-I0046).
    fn recordNode(self: *Walker, node: NodeIndex) !void {
        switch (self.tree.nodeTag(node)) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try self.var_decls.append(self.a, node);
            },
            .@"return" => try self.returns.append(self.a, node),
            .@"break" => {
                const operand = self.tree.nodeData(node).opt_token_and_opt_node[1];
                if (operand != .none) try self.breaks.append(self.a, node);
            },
            .assign => try self.assigns.append(self.a, node),
            .@"comptime" => try self.comptime_ranges.append(self.a, .{
                .first = self.tree.firstToken(node),
                .last = self.tree.lastToken(node),
            }),
            else => {},
        }
    }

    fn pushChildren(self: *Walker, node: NodeIndex) !void {
        const tag = self.tree.nodeTag(node);
        if (isBoundaryTag(tag)) return;
        if (try self.pushCompositeStmt(node)) return;
        if (try self.pushCompositeExpr(node)) return;
        try self.pushShaped(node);
    }

    /// Record a payload capture from an if/for/while (EPH-I0046,
    /// EPH-I1184). A pointer capture binds a pointer INTO the capture
    /// root's storage (the optional's or array's slot). The body token
    /// range scopes the name so a same-named outer binding stays
    /// resolvable.
    fn recordCapture(
        self: *Walker,
        payload_token: ?Ast.TokenIndex,
        root: NodeIndex,
        is_for: bool,
        body: NodeIndex,
    ) !void {
        const ptok = payload_token orelse return;
        // The payload token is the `*` itself for a pointer capture. The
        // Binding name is the next token (verified against Parse.zig:
        // payload_token = payload_pipe + 1).
        const raw = self.tree.tokenSlice(ptok);
        const is_ptr = mem.eql(u8, raw, "*");
        const name = if (is_ptr) self.tree.tokenSlice(ptok + 1) else raw;
        try self.captures.append(self.a, .{
            .name = name,
            .is_ptr = is_ptr,
            .root = root,
            .is_for = is_for,
            .first_tok = self.tree.firstToken(body),
            .last_tok = self.tree.lastToken(body),
        });
    }

    /// Composite statement constructs, via the tree's typed helpers. Each
    /// family helper handles its tag set and returns false otherwise.
    fn pushCompositeStmt(self: *Walker, node: NodeIndex) !bool {
        if (try self.pushVarDeclStmt(node)) return true;
        if (try self.pushLoopStmt(node)) return true;
        if (try self.pushSwitchStmt(node)) return true;
        if (try self.pushSwitchCaseStmt(node)) return true;
        if (try self.pushBlockStmt(node)) return true;
        return false;
    }

    /// Var-decl statements: the type and init nodes push as children.
    fn pushVarDeclStmt(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .local_var_decl and tag != .simple_var_decl and
            tag != .aligned_var_decl) return false;
        const vd = self.tree.fullVarDecl(node) orelse return true;
        try self.pushOpt(vd.ast.type_node);
        try self.pushOpt(vd.ast.init_node);
        return true;
    }

    /// The if/while/for family: each arm records its payload capture
    /// (EPH-I0046) and pushes condition, body, and the optional else.
    fn pushLoopStmt(self: *Walker, node: NodeIndex) !bool {
        switch (self.tree.nodeTag(node)) {
            .if_simple, .@"if" => try self.pushIf(node),
            .while_simple, .while_cont, .@"while" => try self.pushWhile(node),
            .for_simple, .@"for" => try self.pushFor(node),
            else => return false,
        }
        return true;
    }

    /// Switch statements: the condition and the case nodes push.
    fn pushSwitchStmt(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .@"switch" and tag != .switch_comma) return false;
        const s = self.tree.fullSwitch(node) orelse return true;
        try self.push(s.ast.condition);
        try self.pushAll(s.ast.cases);
        return true;
    }

    /// Switch-case statements: the values and the target expression push.
    fn pushSwitchCaseStmt(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .switch_case_one and tag != .switch_case and
            tag != .switch_case_inline_one and tag != .switch_case_inline) return false;
        const c = self.tree.fullSwitchCase(node) orelse return true;
        try self.pushAll(c.ast.values);
        try self.push(c.ast.target_expr);
        return true;
    }

    /// Block statements: the block's statements push as children.
    fn pushBlockStmt(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .block and tag != .block_semicolon and
            tag != .block_two and tag != .block_two_semicolon) return false;
        var buf: [2]NodeIndex = undefined;
        try self.pushAll(self.tree.blockStatements(&buf, node) orelse return true);
        return true;
    }

    /// The if arm: record the payload capture (EPH-I0046) and push the
    /// condition, then-arm, and optional else.
    fn pushIf(self: *Walker, node: NodeIndex) !void {
        const f = self.tree.fullIf(node) orelse return;
        try self.recordCapture(f.payload_token, f.ast.cond_expr, false, f.ast.then_expr);
        try self.push(f.ast.cond_expr);
        try self.push(f.ast.then_expr);
        try self.pushOpt(f.ast.else_expr);
    }

    /// The for arm: single-input loops record the payload capture
    /// (EPH-I0046), then the inputs and body push like the other loops.
    fn pushFor(self: *Walker, node: NodeIndex) !void {
        const f = self.tree.fullFor(node) orelse return;
        if (f.ast.inputs.len == 1) {
            try self.recordCapture(f.payload_token, f.ast.inputs[0], true, f.ast.then_expr);
        }
        try self.pushAll(f.ast.inputs);
        try self.push(f.ast.then_expr);
        try self.pushOpt(f.ast.else_expr);
    }

    /// The while arm: records the payload capture with the if-capture
    /// rooting rule — the pointer binds into the condition operand's own
    /// slot (EPH-I1184) — then pushes condition, continue, body, else.
    fn pushWhile(self: *Walker, node: NodeIndex) !void {
        const w = self.tree.fullWhile(node) orelse return;
        try self.recordCapture(w.payload_token, w.ast.cond_expr, false, w.ast.then_expr);
        try self.push(w.ast.cond_expr);
        try self.pushOpt(w.ast.cont_expr);
        try self.push(w.ast.then_expr);
        try self.pushOpt(w.ast.else_expr);
    }

    /// Composite expression constructs, via the tree's typed helpers.
    fn pushCompositeExpr(self: *Walker, node: NodeIndex) !bool {
        switch (self.tree.nodeTag(node)) {
            .call, .call_comma, .call_one, .call_one_comma => try self.pushCall(node),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => try self.pushBuiltinCall(node),
            .struct_init,
            .struct_init_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_one,
            .struct_init_one_comma,
            => try self.pushStructInit(node),
            .array_init,
            .array_init_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_one,
            .array_init_one_comma,
            => try self.pushArrayInit(node),
            .slice_open, .slice, .slice_sentinel => try self.pushSlice(node),
            .array_type, .array_type_sentinel => try self.pushArrayType(node),
            else => return false,
        }
        return true;
    }

    fn pushCall(self: *Walker, node: NodeIndex) !void {
        var buf: [1]NodeIndex = undefined;
        const c = self.tree.fullCall(&buf, node) orelse return;
        try self.push(c.ast.fn_expr);
        try self.pushAll(c.ast.params);
    }

    fn pushBuiltinCall(self: *Walker, node: NodeIndex) !void {
        var buf: [2]NodeIndex = undefined;
        try self.pushAll(self.tree.builtinCallParams(&buf, node) orelse return);
    }

    fn pushStructInit(self: *Walker, node: NodeIndex) !void {
        var buf: [2]NodeIndex = undefined;
        const s = self.tree.fullStructInit(&buf, node) orelse return;
        try self.pushOpt(s.ast.type_expr);
        try self.pushAll(s.ast.fields);
    }

    fn pushArrayInit(self: *Walker, node: NodeIndex) !void {
        var buf: [2]NodeIndex = undefined;
        const ai = self.tree.fullArrayInit(&buf, node) orelse return;
        try self.pushOpt(ai.ast.type_expr);
        try self.pushAll(ai.ast.elements);
    }

    fn pushSlice(self: *Walker, node: NodeIndex) !void {
        const s = self.tree.fullSlice(node) orelse return;
        try self.push(s.ast.sliced);
        try self.push(s.ast.start);
        try self.pushOpt(s.ast.end);
        try self.pushOpt(s.ast.sentinel);
    }

    fn pushArrayType(self: *Walker, node: NodeIndex) !void {
        const at = self.tree.fullArrayType(node) orelse return;
        try self.push(at.ast.elem_count);
        try self.pushOpt(at.ast.sentinel);
        try self.push(at.ast.elem_type);
    }

    /// Destructured `var` bindings are stack slots and must enter FnScan
    /// through their lhs patterns. The patterns carry no type node, so
    /// their chains resolve silent under the precision policy (EPH-I0596).
    fn pushDestructure(self: *Walker, node: NodeIndex) !void {
        const d = self.tree.assignDestructure(node);
        try self.pushAll(d.ast.variables);
        try self.push(d.ast.value_expr);
    }

    /// Children of the `extra_and_node` tags: plain pointer types push
    /// their elem type. `assign_destructure` pushes lhs bindings plus
    /// the value (EPH-I0596).
    fn pushShapedTail(self: *Walker, node: NodeIndex) !void {
        const data = self.tree.nodeData(node);
        if (self.tree.nodeTag(node) == .assign_destructure) {
            try self.pushDestructure(node);
            return;
        }
        try self.push(data.extra_and_node[1]);
    }

    /// Simple expressions: children follow directly from the tag's fixed
    /// data shape. Unlisted tags are leaves for this walk's purposes.
    fn pushShaped(self: *Walker, node: NodeIndex) !void {
        if (try self.pushShapedBinary(node)) return;
        if (try self.pushShapedAccess(node)) return;
        if (try self.pushShapedUnary(node)) return;
        if (try self.pushShapedControl(node)) return;
        if (try self.pushShapedJump(node)) return;
        if (try self.pushShapedPtr(node)) return;
    }

    /// Access-shaped children (field access, unwrap, grouping): one child
    /// in node_and_token[0].
    fn pushShapedAccess(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .field_access and tag != .unwrap_optional and
            tag != .grouped_expression) return false;
        try self.push(self.tree.nodeData(node).node_and_token[0]);
        return true;
    }

    /// Unary-prefix children: one child in data.node.
    fn pushShapedUnary(self: *Walker, node: NodeIndex) !bool {
        switch (self.tree.nodeTag(node)) {
            .address_of,
            .deref,
            .bool_not,
            .negation,
            .negation_wrap,
            .bit_not,
            .optional_type,
            .@"try",
            .@"comptime",
            .@"defer",
            .@"suspend",
            .@"resume",
            .@"nosuspend",
            => try self.push(self.tree.nodeData(node).node),
            else => return false,
        }
        return true;
    }

    /// Control-shaped children: return pushes its optional operand,
    /// errdefer and anyframe_type their token-and-node slot.
    fn pushShapedControl(self: *Walker, node: NodeIndex) !bool {
        const data = self.tree.nodeData(node);
        switch (self.tree.nodeTag(node)) {
            .@"return" => try self.pushOpt(data.opt_node),
            .@"errdefer" => try self.push(data.opt_token_and_node[1]),
            .anyframe_type => try self.push(data.token_and_node[1]),
            else => return false,
        }
        return true;
    }

    /// Jump children: break/continue carry an optional operand.
    fn pushShapedJump(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        if (tag != .@"break" and tag != .@"continue") return false;
        try self.pushOpt(self.tree.nodeData(node).opt_token_and_opt_node[1]);
        return true;
    }

    /// Pointer-type and destructure children (extra_and_node shapes):
    /// aligned/sentinel push the optional align/sentinel plus the elem.
    /// plain/sized/destructure push their tail (EPH-I0596).
    fn pushShapedPtr(self: *Walker, node: NodeIndex) !bool {
        const data = self.tree.nodeData(node);
        switch (self.tree.nodeTag(node)) {
            .ptr_type_aligned, .ptr_type_sentinel => {
                const opt, const elem = data.opt_node_and_node;
                try self.pushOpt(opt);
                try self.push(elem);
            },
            .ptr_type, .ptr_type_bit_range, .assign_destructure => {
                try self.pushShapedTail(node);
            },
            else => return false,
        }
        return true;
    }

    /// Binary operators, assignments, ranges, catch/orelse, error unions —
    /// all `node_and_node` (verified against Parse.zig's operTable).
    fn pushShapedBinary(self: *Walker, node: NodeIndex) !bool {
        const tag = self.tree.nodeTag(node);
        const data = self.tree.nodeData(node);
        if (binary_like_tags.contains(tag)) {
            const lhs, const rhs = data.node_and_node;
            try self.push(lhs);
            try self.push(rhs);
            return true;
        }
        // `lhs..rhs` and open `lhs..` — the end is optional (shape is
        // node_and_opt_node, NOT node_and_node. Verified against
        // Parse.zig forPrefix).
        if (tag == .for_range) {
            const lhs, const rhs = data.node_and_opt_node;
            try self.push(lhs);
            try self.pushOpt(rhs);
            return true;
        }
        return false;
    }
};

/// Tags whose data is `node_and_node` (binary ops, assignments, ranges,
/// catch/orelse, error unions — verified against Parse.zig's operTable).
const binary_like_tags = blk: {
    var set = std.EnumSet(Ast.Node.Tag).initEmpty();
    const tags = [_]Ast.Node.Tag{
        .assign,          .assign_mul,      .assign_div,      .assign_mod,
        .assign_add,      .assign_sub,      .assign_shl,      .assign_shl_sat,
        .assign_shr,      .assign_bit_and,  .assign_bit_xor,  .assign_bit_or,
        .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat,
        .assign_add_sat,  .assign_sub_sat,  .equal_equal,     .bang_equal,
        .less_than,       .greater_than,    .less_or_equal,   .greater_or_equal,
        .mul,             .div,             .mod,             .array_mult,
        .mul_wrap,        .mul_sat,         .add,             .sub,
        .array_cat,       .add_wrap,        .sub_wrap,        .add_sat,
        .sub_sat,         .shl,             .shl_sat,         .shr,
        .bit_and,         .bit_xor,         .bit_or,          .bool_and,
        .bool_or,         .@"orelse",       .@"catch",        .merge_error_sets,
        .switch_range,    .error_union,     .array_access,
    };
    for (tags) |t| set.insert(t);
    break :blk set;
};

/// Container-declaration tags: the boundary set's container half, shared
/// with the type index in ast_tier_za111.zig. The B75/B76 split mirrored
/// this list across the two files. It lives here once (EPH-I1232).
pub fn isContainerDeclTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

/// Tags whose subtrees must not be entered during a fn-body walk.
fn isBoundaryTag(tag: Ast.Node.Tag) bool {
    if (isContainerDeclTag(tag)) return true;
    return isNonContainerBoundaryTag(tag);
}

/// The non-container boundary tags: declaration roots and the asm family.
fn isNonContainerBoundaryTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .root,
        .test_decl,
        .error_set_decl,
        .global_var_decl,
        .fn_decl,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .container_field,
        .container_field_init,
        .container_field_align,
        .asm_simple,
        .@"asm",
        .asm_input,
        .asm_output,
        => true,
        else => false,
    };
}

// ============================================================================
// Walker tests
// ============================================================================

test "container-decl tag set matches the boundary walk (EPH-I1232)" {
    try std.testing.expect(isContainerDeclTag(.container_decl));
    try std.testing.expect(isContainerDeclTag(.tagged_union_enum_tag_trailing));
    try std.testing.expect(!isContainerDeclTag(.fn_decl));
    try std.testing.expect(!isContainerDeclTag(.root));
}
