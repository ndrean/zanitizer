//! zexplorer: Zig wrapper of the C library lexbor, HTML parsing and manipulation

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// QuickJS-ng bindings
// ============================================================================
pub const qjs = @cImport({
    @cInclude("quickjs.h");
});

pub const curl = @import("curl");
// Import wrapper for cleaner QuickJS API
pub const wrapper = @import("wrapper.zig");
pub const dom_bridge = @import("dom_bridge.zig");
// DOM class ID for QuickJS opaque object wrapping
// Initialized by DOMBridge.init(), used by generated bindings
// Note: This is a pointer to the actual var in dom_bridge.zig
// Access with z.dom_class_id.* in generated code
// pub const dom_class_id = &dom_bridge.dom_class_id;
// Mailbox for inter-thread communication (Worker pattern)
pub const Mailbox = @import("mailbox.zig").Mailbox;
pub const utils = @import("utils.zig");
pub const events = @import("events.zig");

// Event handling functions: implemented in dom_bridge.zig
pub const addEventListener = dom_bridge.addEventListener;
pub const dispatchEvent = dom_bridge.dispatchEvent;
pub const removeEventListener = dom_bridge.removeEventListener;

// Re-export wrapper constants - use these instead of creating values manually
// This avoids std.mem.zeroes() code smell and provides compile-time constants
pub const jsException = wrapper.EXCEPTION;
pub const jsNull = wrapper.NULL;
pub const jsUndefined = wrapper.UNDEFINED;
pub const jsTrue = wrapper.TRUE;
pub const jsFalse = wrapper.FALSE;

// TODO: check if these are needed
pub fn isUndefined(val: qjs.JSValue) bool {
    return qjs.JS_IsUndefined(val);
}
pub fn isNull(val: qjs.JSValue) bool {
    return qjs.JS_IsNull(val);
}
pub fn isException(val: qjs.JSValue) bool {
    return qjs.JS_IsException(val);
}
pub fn isFunction(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    return qjs.JS_IsFunction(ctx, val);
}

// ======================================================================
// Lexbor core modules
// ======================================================================
const lxb = @import("modules/core.zig");
const css = @import("modules/css_selectors.zig");
const chunks = @import("modules/chunks.zig");
const tag = @import("modules/html_tags.zig");
const specs = @import("modules/html_spec.zig");
const Type = @import("modules/node_types.zig");
const search = @import("modules/simple_search.zig");
const serialize = @import("modules/serializer.zig");
const cleaner = @import("modules/cleaner.zig");
const attrs = @import("modules/attributes.zig");
const walker = @import("modules/walker.zig");
const classes = @import("modules/class_list.zig");
const frag_temp = @import("modules/fragment_template.zig");
const norm = @import("modules/normalize.zig");
const text = @import("modules/text_content.zig");
const sanitize = @import("modules/sanitizer.zig");
const parse = @import("modules/parsing.zig");
const colours = @import("modules/colours.zig");
const html_spec = @import("modules/html_spec.zig");
const styles = @import("modules/styles.zig");

// ================================================================================

// Re-export commonly used types
pub const Err = @import("errors.zig").LexborError;

//===================================================================================
// General Status codes & constants & definitions

pub const _CONTINUE: c_int = 0;
pub const _STOP: c_int = 1;
pub const _OK: usize = 0;

// from lexbor source: /tag/const.h
pub const LXB_TAG_TEMPLATE: u32 = 179; // From lexbor source
pub const LXB_TAG_STYLE: u32 = 171;
pub const LXB_TAG_SCRIPT: u32 = 162;

pub const LXB_DOM_NODE_TYPE_ELEMENT: u32 = 1;
pub const LXB_DOM_NODE_TYPE_TEXT: u32 = 3;
pub const LXB_DOM_NODE_TYPE_COMMENT: u32 = 8;

pub const LXB_DOM_NODE_TYPE_DOCUMENT = 9;
pub const LXB_DOM_NODE_TYPE_FRAGMENT = 11;
pub const LXB_DOM_NODE_TYPE_UNKNOWN = 0;

//=================================================================================
// Opaque lexbor structs

pub const DomDocument = opaque {};
// pub const HTMLDocument = opaque {};
pub const HTMLDocument = opaque {
    // treat HTMLDocument as a DomDocument (lxb_dom_document_t is the first member of lxb_html_document_t)
    pub inline fn asDom(self: *HTMLDocument) *DomDocument {
        return @ptrCast(self);
    }
};
pub const DomNode = opaque {};
pub const HTMLElement = opaque {};
pub const Comment: type = opaque {};
pub const DocumentFragment = opaque {};
pub const HTMLTemplateElement = opaque {};
pub const DomAttr = opaque {};
pub const DomCollection = opaque {};

pub const HtmlParser = opaque {};

pub const CssParser = opaque {};
pub const CssSelectors = opaque {};
pub const CssSelectorList = opaque {};
pub const CssSelectorSpecificity = opaque {};

pub const CssStyleParser = opaque {};
pub const CssStyleSheet = opaque {};

//==============================================================================================

pub const createDocument = lxb.createDocument;
pub const destroyDocument = lxb.destroyDocument;
pub const cleanDocument = lxb.cleanDocument;
pub const asDom = lxb.asDom;

// Direct access to parser functions
pub const insertHTML = parse.insertHTML;
pub const parseHTML = parse.parseHTML;
pub const parseHTMLUnsafe = parse.parseHTMLUnsafe;

pub const innerHTML = serialize.innerHTML;
pub const outerHTML = serialize.outerHTML;
pub const outerNodeHTML = serialize.outerNodeHTML;
pub const setInnerHTML = parse.setInnerHTML;
pub const setHTML = parse.setHTML;
pub const getHTML = serialize.getHTML;
pub const setOuterHTML = serialize.setOuterHTML;

// Parser engine for fragment & template processing
pub const DOMParser = parse.DOMParser;

pub const createElement = lxb.createElement;
pub const createElementWithAttrs = lxb.createElementWithAttrs;
pub const createTextNode = lxb.createTextNode;

pub const removeNode = lxb.removeNode;
pub const destroyNode = lxb.destroyNode;
// pub const destroyElement = lxb.destroyElement;

pub const documentRoot = lxb.documentRoot;
pub const ownerDocument = lxb.ownerDocument;
pub const bodyElement = lxb.bodyElement;
pub const bodyNode = lxb.bodyNode;
pub const documentBody = lxb.documentBody;

pub const cloneNode = lxb.cloneNode;
pub const importNode = lxb.importNode;

pub const elementToNode = lxb.elementToNode;
pub const nodeToElement = lxb.nodeToElement;
pub const objectToNode = lxb.objectToNode;

pub const nodeName = lxb.nodeName; // Allocated
pub const nodeName_zc = lxb.nodeName_zc; // Zero-copy
pub const tagName = lxb.tagName; // Allocated
pub const tagName_zc = lxb.tagName_zc; // Zero-copy
pub const qualifiedName = lxb.qualifiedName; // Allocated
pub const qualifiedName_zc = lxb.qualifiedName_zc; // Zero-copy

pub const isNodeEmpty = lxb.isNodeEmpty;
pub const isVoid = lxb.isVoid;
pub const isNodeTextEmpty = lxb.isTextNodeEmpty;
pub const isWhitespaceOnlyText = lxb.isWhitespaceOnlyText;

pub const NodeType = Type.NodeType;
pub const nodeType = Type.nodeType;
pub const nodeTypeName = Type.nodeTypeName;

pub const isTypeElement = Type.isTypeElement;
pub const isTypeComment = Type.isTypeComment;
pub const isTypeText = Type.isTypeText;
pub const isTypeDocument = Type.isTypeDocument;
pub const isTypeFragment = Type.isTypeFragment;

pub const HtmlTag = tag.HtmlTag;
pub const WhitespacePreserveTagSet = tag.WhitespacePreserveTagSet;

// from lexbor source: /tag/const.h

pub const stringToEnum = tag.stringToEnum;
pub const tagFromQualifiedName = tag.tagFromQualifiedName;
pub const tagFromElement = tag.tagFromElement;
pub const tagFromAnyElement = tag.tagFromAnyElement;
pub const matchesTagName = tag.matchesTagName;

// pub const ElementSpec = specs.ElementSpec;
pub const ElementSpecMap = specs.ElementSpecMap;
pub const getElementSpecFromElement = specs.getElementSpecFromElement;
pub const isVoidElementFromSpec = specs.isVoidElementFromSpec;
pub const validateElementAttributeFromElement = specs.validateElementAttributeFromElement;
pub const getAllowedAttributesFromElement = specs.getAllowedAttributesFromElement;
pub const isAttributeAllowedFast = specs.isAttributeAllowedFast;
pub const getElementSpecFast = specs.getElementSpecFast;
pub const isVoidElementEnum = specs.isVoidElementEnum;
pub const isAttributeAllowedEnum = specs.isAttributeAllowedEnum;
pub const getElementSpecByEnum = specs.getElementSpecByEnum;

pub const commentToNode = lxb.commentToNode;
pub const nodeToComment = lxb.nodeToComment;
pub const createComment = lxb.createComment;
// pub const destroyComment = lxb.destroyComment;

pub const commentContent = text.commentContent;
pub const commentContent_zc = text.commentContent_zc;

pub const textContent = text.textContent;
pub const textContent_zc = text.textContent_zc;
/// Note: not style aware.
pub const innerText = text.textContent_zc; // alias
pub const replaceText = text.replaceText;
pub const setContentAsText = text.setContentAsText;
pub const setTextContent = text.setTextContent;
pub const escapeHtml = text.escapeHtml;
pub const nodeValue_zc = text.nodeValue_zc;
pub const setNodeValue = text.setNodeValue;

// DOM based normalization
pub const isWhitespaceOnly = norm.isWhitespaceOnly;
pub const normalizeDOM = norm.normalizeDOM;
pub const normalizeDOMwithOptions = norm.normalizeDOMwithOptions;

pub const normalizeDOMForDisplay = norm.normalizeDOMForDisplay;

// String based normalization
pub const StringNormalizeOptions = cleaner.StringNormalizeOptions;

pub const normalizeHtmlString = cleaner.normalizeHtmlString;
pub const normalizeHtmlStringWithOptions = cleaner.normalizeHtmlStringWithOptions;

pub const normalizeText = cleaner.normalizeText;

pub const firstChild = lxb.firstChild;
pub const lastChild = lxb.lastChild;
pub const nextSibling = lxb.nextSibling;
pub const previousSibling = lxb.previousSibling;
pub const parentNode = lxb.parentNode;
pub const firstElementChild = lxb.firstElementChild;
pub const nextElementSibling = lxb.nextElementSibling;
pub const lastElementChild = lxb.lastElementChild;

pub const parentElement = lxb.parentElement;

pub const insertBefore = lxb.insertBefore;
pub const insertAfter = lxb.insertAfter;
pub const replaceAll = lxb.replaceAll;

pub const InsertPosition = lxb.InsertPosition;
pub const insertAdjacentElement = lxb.insertAdjacentElement;
pub const insertAdjacentHTML = lxb.insertAdjacentHTML;
pub const appendChild = lxb.appendChild;
pub const appendChildren = lxb.appendChildren;

pub const childNodes = lxb.childNodes;
pub const children = lxb.children;

//================================================================================
// Stream parser for chunk processing

pub const Stream = chunks.Stream;

//================================================================================
// Parser

//================================================================================
// Fragments & Template element
pub const FragmentContext = frag_temp.FragmentContext;

// fragments
pub const fragmentToNode = frag_temp.fragmentToNode;
pub const createDocumentFragment = frag_temp.createDocumentFragment;
pub const destroyDocumentFragment = frag_temp.destroyDocumentFragment;
pub const appendFragment = frag_temp.appendFragment;
// templates
pub const createTemplate = frag_temp.createTemplate;
pub const destroyTemplate = frag_temp.destroyTemplate;
pub const isTemplate = frag_temp.isTemplate;

pub const templateToNode = frag_temp.templateToNode;
pub const templateToElement = frag_temp.templateToElement;

pub const templateDocumentFragment = frag_temp.templateDocumentFragment;
pub const nodeToTemplate = frag_temp.nodeToTemplate;
pub const elementToTemplate = frag_temp.elementToTemplate;
// ---
pub const templateContent = frag_temp.templateContent;
pub const getTemplateContent = frag_temp.getTemplateContent;
pub const getTemplateContentAsNode = frag_temp.getTemplateContentAsNode;
pub const useTemplateElement = frag_temp.useTemplateElement;
pub const innerTemplateHTML = frag_temp.innerTemplateHTML;
pub const templateContentFirstElementChild = frag_temp.templateContentFirstElementChild;

// Debug printing utilities
pub const printDocStruct = serialize.printDocStruct;
pub const prettyPrint = serialize.prettyPrint;
pub const ppDoc = serialize.ppDoc;
//======================================================================================
// Colouring and syntax highlighting
pub const ElementStyles = colours.ElementStyles;
pub const SyntaxStyle = colours.SyntaxStyle;
pub const Style = colours.Style;
// pub const getStyleForElement = colours.getStyleForElement;
pub const getStyleForElementEnum = colours.getStyleForElementEnum;
pub const isKnownAttribute = colours.isKnownAttribute;
pub const isDangerousAttributeValue = colours.isDangerousAttributeValue;

//=========================================================================================
// Sanitizer

pub const SanitizeOptions = sanitize.SanitizeOptions;
pub const SanitizerOptions = sanitize.SanitizerOptions;
pub const sanitizeNode = sanitize.sanitizeNode;
pub const sanitizeWithOptions = sanitize.sanitizeWithOptions;
pub const sanitizeStrict = sanitize.sanitizeStrict;
pub const sanitizePermissive = sanitize.sanitizePermissive;

// Unified HTML specification functions
pub const isElementAttributeAllowed = sanitize.isElementAttributeAllowed;

//============================================================================================
// Framework Attribute System

pub const FrameworkSpec = specs.FrameworkSpec;
pub const FRAMEWORK_SPECS = specs.FRAMEWORK_SPECS;
pub const isFrameworkAttribute = specs.isFrameworkAttribute;
pub const getFrameworkSpec = specs.getFrameworkSpec;
pub const isFrameworkAttributeSafe = specs.isFrameworkAttributeSafe;

// ============================================================================================
// CSS Styles integration functions

pub const initDocumentCSS = styles.initDocumentCSS;
pub const destroyDocumentCSS = styles.destroyDocumentCSS;
pub const createStylesheet = styles.createStylesheet;
pub const destroyStylesheet = styles.destroyStylesheet;
pub const parseStylesheet = styles.parseStylesheet;
pub const attachStylesheet = styles.attachStylesheet;
pub const attachElementStyles = styles.attachElementStyles;
pub const getComputedStyle = styles.getComputedStyle;
pub const createCssStyleParser = styles.createCssStyleParser;
pub const destroyCssStyleParser = styles.destroyCssStyleParser;
pub const setStyleProperty = styles.setStyleProperty;
pub const getInlineStyle = styles.getInlineStyle;
pub const parseElementStyle = styles.parseElementStyle;
pub const removeInlineStyleProperty = styles.removeInlineStyleProperty;

// ============================================================================================

//============================================================================================
// CSS selectors

pub const CssSelectorEngine = css.CssSelectorEngine;
// pub const createCssEngine = css.createCssEngine;

pub const querySelectorAll = css.querySelectorAll;
pub const querySelector = css.querySelector;
pub const filter = css.filter;
pub const matches = css.matches;
pub const closest = css.closest;

//============================================================================================
// Class & ClassList

pub const hasClass = classes.hasClass;
pub const classList_zc = classes.classList_zc;
pub const className = classes.classList_zc;
pub const classListAsString = classes.classListAsString;
// pub const classListAsString_zc = classes.classListAsString_zc;

pub const ClassList = classes.ClassList;
pub const classList = classes.classList;

//============================================================================================
// Attributes

pub const AttributePair = attrs.AttributePair;
pub const hasAttribute = attrs.hasAttribute;
pub const hasAttributes = attrs.hasAttributes;

pub const getAttribute = attrs.getAttribute;
pub const getAttribute_zc = attrs.getAttribute_zc;

pub const setAttribute = attrs.setAttribute;
pub const removeAttribute = attrs.removeAttribute;

pub const setAttributes = attrs.setAttributes;
pub const getAttributes_bf = attrs.getAttributes_bf;

pub const getElementId = attrs.getElementId;
pub const getElementId_zc = attrs.getElementId_zc;
pub const hasElementId = attrs.hasElementId;

//==========================================================================================
// Single Element Search functions - Simple Walk

pub const contains = search.contains;
pub const getElementById = search.getElementById;
pub const getElementByTag = search.getElementByTag;
pub const getElementByClass = search.getElementByClass;
pub const getElementByAttribute = search.getElementByAttribute;
pub const getElementByDataAttribute = search.getElementByDataAttribute;

//===========================================================================================
// Multiple Element Search Functions (Walker-based, returns slices)

pub const getElementsByClassName = search.getElementsByClassName;
pub const getElementsByTagName = search.getElementsByTagName;
pub const getElementsById = search.getElementsById;
pub const getElementsByAttribute = search.getElementsByAttribute;
pub const getElementsByName = search.getElementsByName;
pub const getElementsByAttributeName = search.getElementsByAttributeName;

//===========================================================================================
// Walker Search traversal functions

pub const simpleWalk = walker.simpleWalk;
pub const castContext = walker.castContext;
pub const genProcessAll = walker.genProcessAll;
pub const genSearchElement = walker.genSearchElement;
pub const genSearchElements = walker.genSearchElements;

//===========================================================================================
// Utilities
pub const stringContains = search.stringContains;
pub const stringEquals = search.stringEquals;

// ***************************************************************************
// Test all imported modules
// ****************************************************************************

const testing = std.testing;

test {
    std.testing.refAllDecls(@This());
}

pub fn get(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();

    var client: std.http.Client = .{
        .allocator = allocator,
    };
    defer client.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .response_writer = &allocating.writer,
    });

    std.debug.assert(response.status == .ok);
    return allocating.toOwnedSlice();
}

// Simple conditional print - always use debug print for reliability
pub const print = switch (builtin.mode) {
    .Debug => std.debug.print,
    else => std.debug.print,
};
