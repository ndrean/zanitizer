//! Zig bindings for Facebook Yoga layout engine
//!
//! Wraps the C API from <yoga/Yoga.h>

pub const c = @cImport({
    @cInclude("yoga/Yoga.h");
});

// Re-export core types
pub const Node = c.YGNodeRef;
pub const Config = c.YGConfigRef;
pub const Value = c.YGValue;

// Enums
pub const Direction = c.YGDirection;
pub const FlexDirection = c.YGFlexDirection;
pub const Justify = c.YGJustify;
pub const Align = c.YGAlign;
pub const PositionType = c.YGPositionType;
pub const Wrap = c.YGWrap;
pub const Overflow = c.YGOverflow;
pub const Display = c.YGDisplay;
pub const Edge = c.YGEdge;
pub const MeasureMode = c.YGMeasureMode;
pub const NodeType = c.YGNodeType;

// --- Node lifecycle ---

pub fn nodeNew() Node {
    return c.YGNodeNew();
}

pub fn nodeNewWithConfig(config: Config) Node {
    return c.YGNodeNewWithConfig(config);
}

pub fn nodeFree(node: Node) void {
    c.YGNodeFree(node);
}

pub fn nodeFreeRecursive(node: Node) void {
    c.YGNodeFreeRecursive(node);
}

// --- Tree management ---

pub fn insertChild(parent: Node, child: Node, index: usize) void {
    c.YGNodeInsertChild(parent, child, index);
}

pub fn getChildCount(node: Node) usize {
    return c.YGNodeGetChildCount(node);
}

pub fn getChild(node: Node, index: usize) Node {
    return c.YGNodeGetChild(node, index);
}

// --- Layout calculation ---

pub fn calculateLayout(node: Node, width: f32, height: f32, direction: c_uint) void {
    c.YGNodeCalculateLayout(node, width, height, direction);
}

pub const Undefined: f32 = @bitCast(@as(u32, 0x7FC00000)); // NaN

// --- Layout results ---

pub fn getLeft(node: Node) f32 {
    return c.YGNodeLayoutGetLeft(node);
}

pub fn getTop(node: Node) f32 {
    return c.YGNodeLayoutGetTop(node);
}

pub fn getWidth(node: Node) f32 {
    return c.YGNodeLayoutGetWidth(node);
}

pub fn getHeight(node: Node) f32 {
    return c.YGNodeLayoutGetHeight(node);
}

// --- Style setters ---

pub fn setFlexDirection(node: Node, dir: c_uint) void {
    c.YGNodeStyleSetFlexDirection(node, dir);
}

pub fn setJustifyContent(node: Node, justify: c_uint) void {
    c.YGNodeStyleSetJustifyContent(node, justify);
}

pub fn setAlignItems(node: Node, val: c_uint) void {
    c.YGNodeStyleSetAlignItems(node, val);
}

pub fn setAlignSelf(node: Node, val: c_uint) void {
    c.YGNodeStyleSetAlignSelf(node, val);
}

pub fn setFlexWrap(node: Node, wrap: c_uint) void {
    c.YGNodeStyleSetFlexWrap(node, wrap);
}

pub fn setFlexGrow(node: Node, grow: f32) void {
    c.YGNodeStyleSetFlexGrow(node, grow);
}

pub fn setFlexShrink(node: Node, shrink: f32) void {
    c.YGNodeStyleSetFlexShrink(node, shrink);
}

pub fn setDisplay(node: Node, display: c_uint) void {
    c.YGNodeStyleSetDisplay(node, display);
}

pub fn setPositionType(node: Node, pos_type: c_uint) void {
    c.YGNodeStyleSetPositionType(node, pos_type);
}

pub fn setWidth(node: Node, width: f32) void {
    c.YGNodeStyleSetWidth(node, width);
}

pub fn setWidthPercent(node: Node, width: f32) void {
    c.YGNodeStyleSetWidthPercent(node, width);
}

pub fn setWidthAuto(node: Node) void {
    c.YGNodeStyleSetWidthAuto(node);
}

pub fn setHeight(node: Node, height: f32) void {
    c.YGNodeStyleSetHeight(node, height);
}

pub fn setHeightPercent(node: Node, height: f32) void {
    c.YGNodeStyleSetHeightPercent(node, height);
}

pub fn setHeightAuto(node: Node) void {
    c.YGNodeStyleSetHeightAuto(node);
}

pub fn setMinWidth(node: Node, width: f32) void {
    c.YGNodeStyleSetMinWidth(node, width);
}

pub fn setMinHeight(node: Node, height: f32) void {
    c.YGNodeStyleSetMinHeight(node, height);
}

pub fn setMaxWidth(node: Node, width: f32) void {
    c.YGNodeStyleSetMaxWidth(node, width);
}

pub fn setMaxHeight(node: Node, height: f32) void {
    c.YGNodeStyleSetMaxHeight(node, height);
}

pub fn setPadding(node: Node, edge: c_uint, value: f32) void {
    c.YGNodeStyleSetPadding(node, edge, value);
}

pub fn setMargin(node: Node, edge: c_uint, value: f32) void {
    c.YGNodeStyleSetMargin(node, edge, value);
}

pub fn setBorder(node: Node, edge: c_uint, value: f32) void {
    c.YGNodeStyleSetBorder(node, edge, value);
}

pub fn setPosition(node: Node, edge: c_uint, value: f32) void {
    c.YGNodeStyleSetPosition(node, edge, value);
}

pub fn setGap(node: Node, gutter: c_uint, value: f32) void {
    c.YGNodeStyleSetGap(node, gutter, value);
}

pub fn setAspectRatio(node: Node, ratio: f32) void {
    c.YGNodeStyleSetAspectRatio(node, ratio);
}

// --- Measure function for text nodes ---

pub fn setMeasureFunc(node: Node, func: c.YGMeasureFunc) void {
    c.YGNodeSetMeasureFunc(node, func);
}

pub fn setNodeType(node: Node, node_type: c_uint) void {
    c.YGNodeSetNodeType(node, node_type);
}

pub fn setContext(node: Node, ctx: ?*anyopaque) void {
    c.YGNodeSetContext(node, ctx);
}

pub fn getContext(node: Node) ?*anyopaque {
    return c.YGNodeGetContext(node);
}

pub fn markDirty(node: Node) void {
    c.YGNodeMarkDirty(node);
}

// --- Config ---

pub fn configNew() Config {
    return c.YGConfigNew();
}

pub fn configFree(config: Config) void {
    c.YGConfigFree(config);
}

pub fn configSetUseWebDefaults(config: Config, enabled: bool) void {
    c.YGConfigSetUseWebDefaults(config, enabled);
}

pub fn configSetPointScaleFactor(config: Config, factor: f32) void {
    c.YGConfigSetPointScaleFactor(config, factor);
}

// --- Constants ---
pub const FLEX_DIRECTION_ROW = c.YGFlexDirectionRow;
pub const FLEX_DIRECTION_ROW_REVERSE = c.YGFlexDirectionRowReverse;
pub const FLEX_DIRECTION_COLUMN = c.YGFlexDirectionColumn;
pub const FLEX_DIRECTION_COLUMN_REVERSE = c.YGFlexDirectionColumnReverse;

pub const JUSTIFY_FLEX_START = c.YGJustifyFlexStart;
pub const JUSTIFY_CENTER = c.YGJustifyCenter;
pub const JUSTIFY_FLEX_END = c.YGJustifyFlexEnd;
pub const JUSTIFY_SPACE_BETWEEN = c.YGJustifySpaceBetween;
pub const JUSTIFY_SPACE_AROUND = c.YGJustifySpaceAround;

pub const ALIGN_AUTO = c.YGAlignAuto;
pub const ALIGN_FLEX_START = c.YGAlignFlexStart;
pub const ALIGN_CENTER = c.YGAlignCenter;
pub const ALIGN_FLEX_END = c.YGAlignFlexEnd;
pub const ALIGN_STRETCH = c.YGAlignStretch;

pub const EDGE_LEFT = c.YGEdgeLeft;
pub const EDGE_TOP = c.YGEdgeTop;
pub const EDGE_RIGHT = c.YGEdgeRight;
pub const EDGE_BOTTOM = c.YGEdgeBottom;
pub const EDGE_ALL = c.YGEdgeAll;
pub const EDGE_HORIZONTAL = c.YGEdgeHorizontal;
pub const EDGE_VERTICAL = c.YGEdgeVertical;

pub const WRAP_NO_WRAP = c.YGWrapNoWrap;
pub const WRAP_WRAP = c.YGWrapWrap;

pub const DISPLAY_FLEX = c.YGDisplayFlex;
pub const DISPLAY_NONE = c.YGDisplayNone;

pub const POSITION_RELATIVE = c.YGPositionTypeRelative;
pub const POSITION_ABSOLUTE = c.YGPositionTypeAbsolute;

pub const DIRECTION_LTR = c.YGDirectionLTR;

pub const NODE_TYPE_DEFAULT = c.YGNodeTypeDefault;
pub const NODE_TYPE_TEXT = c.YGNodeTypeText;

pub const MEASURE_MODE_UNDEFINED = c.YGMeasureModeUndefined;
pub const MEASURE_MODE_EXACTLY = c.YGMeasureModeExactly;
pub const MEASURE_MODE_AT_MOST = c.YGMeasureModeAtMost;
