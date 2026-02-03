const BindingSpec = @import("template_gen.zig").BindingSpec;

pub const bindings = [_]BindingSpec{

    // Document methods (Static on document object)
    .{
        .name = "parseHTML",
        .kind = .static, // Static on Document
        .zig_func_name = "z.parseHTML", // The wrapper that defaults options
        .args = &.{ .allocator, .string },
        .return_type = .error_owned_document,
    },
    .{
        .name = "documentRoot",
        .zig_func_name = "z.documentRoot",
        .kind = .static,
        .args = &.{.document},
        .return_type = .optional_node,
    },
    .{
        .name = "createElement",
        .zig_func_name = "z.createElement",
        .kind = .method,
        .args = &.{ .this_document, .string },
        .return_type = .element, // Returns !*HTMLElement
        .prop_this = .this_document,
    },

    .{
        .name = "createTextNode",
        .zig_func_name = "z.createTextNode",
        .kind = .method,
        .args = &.{ .this_document, .string },
        .return_type = .node, // Returns !*DomNode
        .prop_this = .this_document,
    },
    .{
        .name = "createComment",
        .zig_func_name = "z.createCommentNode",
        .kind = .method,
        .args = &.{ .this_document, .string },
        .return_type = .node, // Returns !*DomNode
        .prop_this = .this_document,
    },
    .{
        .name = "createDocumentFragment",
        .zig_func_name = "z.createDocumentFragmentNode",
        .kind = .method,
        .args = &.{.this_document}, // No string argument
        .return_type = .node, // Returns !*DomNode
        .prop_this = .this_document,
    },
    .{
        .name = "getElementById",
        .zig_func_name = "z.getElementById",
        .kind = .method,
        .args = &.{ .this_document, .string },
        .return_type = .optional_element,
        .prop_this = .this_document,
    },
    // createRange is manually implemented in dom_bridge.zig (returns JS Range object)

    // DOMParser.parseFromString: TODO
    .{
        .name = "parseFromString",
        .kind = .method,
        .zig_func_name = "z.DOMParser.parseFromString",
        .args = &.{ .this_parser, .string },
        .return_type = .error_owned_document, // Returns !*HTMLDocument
        .prop_this = .this_parser,
    },
    .{
        .name = "type",
        .kind = .property,
        .getter = "z.events.getType",
        .setter = "", // Read-Only
        .prop_this = .this_event, // You need to add this enum or generic handling
        .prop_type = .string_zc,
    },
    .{
        .name = "bubbles",
        .kind = .property,
        .getter = "z.events.getBubbles",
        .setter = "", // Read-Only
        .prop_this = .this_event,
        .prop_type = .boolean,
    },
    .{
        .name = "defaultPrevented",
        .kind = .property,
        .getter = "z.events.getDefaultPrevented",
        .setter = "", // Read-Only
        .prop_this = .this_event,
        .prop_type = .boolean,
    },
    .{
        .name = "target",
        .kind = .property,
        .getter = "z.events.getTarget",
        .setter = "", // Read-Only
        .prop_this = .this_event,
        .prop_type = .optional_node,
    },
    .{
        .name = "currentTarget",
        .kind = .property,
        .getter = "z.events.getCurrentTarget",
        .setter = "", // Read-Only
        .prop_this = .this_event,
        .prop_type = .optional_node,
    },
    .{
        .name = "stopPropagation",
        .kind = .method,
        .zig_func_name = "z.events.stopPropagation",
        .args = &.{.this_event},
        .return_type = .void_type,
        .prop_this = .this_event,
    },
    .{
        .name = "preventDefault",
        .kind = .method,
        .zig_func_name = "z.events.preventDefault",
        .args = &.{.this_event},
        .return_type = .void_type,
        .prop_this = .this_event,
    },
    // Node/Element methods (Prototype methods)
    .{
        .name = "addEventListener",
        .zig_func_name = "z.addEventListener",
        .kind = .method,
        // Pass Context first, then 'this' (Node), then Event Name, then Function
        .args = &.{ .context, .dom_bridge, .this_node, .string, .callback },
        .return_type = .void_with_error,
        .prop_this = .this_node,
    },
    .{
        .name = "removeEventListener",
        .zig_func_name = "z.removeEventListener",
        .kind = .method,
        .args = &.{ .context, .dom_bridge, .this_node, .string, .callback },
        .return_type = .void_with_error,
        .prop_this = .this_node,
    },
    // Optional: Dispatch for manual testing
    .{
        .name = "dispatchEvent",
        .zig_func_name = "z.dispatchEvent",
        .kind = .method,
        .args = &.{ .context, .dom_bridge, .this_node, .js_value },
        .return_type = .error_boolean,
        .prop_this = .this_node,
    },
    .{
        .name = "cloneNode",
        .zig_func_name = "z.cloneNode",
        .kind = .method,
        .args = &.{ .this_node, .boolean }, // deep: bool
        .return_type = .optional_node,
        .prop_this = .this_node,
    },

    .{
        .name = "appendChild",
        .zig_func_name = "z.appendChild",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .void_type,
    },
    // insertBefore is manually implemented in dom_bridge.zig
    // because it needs special handling for optional refChild parameter

    .{
        .name = "remove",
        .zig_func_name = "z.removeNode",
        .kind = .method,
        .args = &.{.this_node},
        .return_type = .void_type,
    },
    .{
        .name = "removeChild",
        .zig_func_name = "z.removeChild",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .optional_node,
    },
    .{
        .name = "replaceChild",
        .zig_func_name = "z.replaceChild",
        .kind = .method,
        .args = &.{ .this_node, .node, .node },
        .return_type = .optional_node,
    },
    .{
        .name = "contains",
        .zig_func_name = "z.contains",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .boolean,
    },
    .{
        .name = "compareDocumentPosition",
        .zig_func_name = "z.compareDocumentPosition",
        .kind = .method,
        .args = &.{ .this_node, .node },
        .return_type = .uint32, // u16 fits in uint32
    },
    .{
        .name = "setAttribute",
        .zig_func_name = "z.setAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string, .string },
        .return_type = .void_with_error,
        .prop_this = .this_element,
    },
    .{
        .name = "getAttribute",
        .zig_func_name = "z.getAttribute_zc",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .optional_string,
    },
    .{
        .name = "removeAttribute",
        .zig_func_name = "z.removeAttribute",
        .kind = .method,
        .args = &.{ .this_element, .string },
        .return_type = .void_with_error,
    },

    // Element
    .{
        .name = "setHTML",
        .kind = .method,
        .zig_func_name = "z.setHTML", // Wrapper handling mode string
        .args = &.{ .allocator, .this_element, .string }, // element, html
        .return_type = .void_with_error,
    },
    .{
        .name = "getHTML",
        .kind = .method,
        .zig_func_name = "z.getHTML",
        .args = &.{ .allocator, .this_element }, // (allocator, this)
        .return_type = .error_string,
    },

    // Properties (getters/setters)
    // TODO
    .{
        .name = "parentNode",
        .kind = .property,
        .getter = "z.parentNode",
        .setter = "", // Read-Only
        .prop_this = .this_node,
        .prop_type = .optional_node,
    },
    .{
        .name = "ownerDocument",
        .kind = .property,
        .getter = "z.ownerDocument",
        .setter = "", // Read-Only
        .prop_this = .this_node,
        .prop_type = .document,
    },
    // .{
    //     .name = "childNodes",
    //     .kind = .property,
    //     .getter = "z.childNodes",
    //     .prop_this = .this_node,
    //     .return_type = .node_list, // Returns ArrayList(*DomNode) -> NodeList
    // },
    .{
        .name = "body",
        .kind = .property,
        .getter = "z.bodyElement", // Uses your new helper
        .setter = "", // EMPTY = Read-Only (no js_set_body generated)
        .prop_type = .optional_element, // Returns ?*HTMLElement
        .prop_this = .this_document, // Strict check for Document
    },

    .{
        .name = "textContent",
        .kind = .property,
        .getter = "z.textContent_zc", // New Helper
        .setter = "z.setContentAsText", // New Helper
        .prop_type = .string_zc, // Returns ![]u8, Setter takes string
        .prop_this = .this_node, // Works on any Node (Text, Element, etc.)
    },
    .{
        .name = "nodeValue",
        .kind = .property,
        .getter = "z.nodeValue_zc",
        .setter = "z.setNodeValue",
        .prop_type = .string_zc,
        .prop_this = .this_node,
    },
    .{
        // CharacterData.data - alias for nodeValue (used by Preact for text updates)
        .name = "data",
        .kind = .property,
        .getter = "z.nodeValue_zc",
        .setter = "z.setNodeValue",
        .prop_type = .string_zc,
        .prop_this = .this_node,
    },
    .{
        .name = "innerText",
        .kind = .property,
        .getter = "z.textContent_zc", // Alias to textContent
        .setter = "z.setContentAsText",
        .prop_type = .string_zc,
        .prop_this = .this_node,
    },

    .{
        .name = "innerHTML",
        .kind = .property,
        .getter = "z.innerHTML",
        .setter = "z.setInnerHTML",
        .prop_type = .error_string, // returns ![]u8
        .prop_this = .this_element,
    },

    .{
        .name = "content",
        .kind = .property,
        .getter = "z.getTemplateContentAsNode",
        .setter = "", // Read-Only
        .prop_type = .optional_node,
        .prop_this = .this_element,
    },
    .{
        .name = "nextSibling",
        .kind = .property,
        .getter = "z.nextSibling",
        .setter = "", // Read-Only
        .prop_type = .optional_node,
        .prop_this = .this_node,
    },
    .{
        .name = "previousSibling",
        .kind = .property,
        .getter = "z.previousSibling",
        .setter = "", // Read-Only
        .prop_type = .optional_node,
        .prop_this = .this_node,
    },
    .{
        .name = "firstChild",
        .kind = .property,
        .getter = "z.firstChild",
        .setter = "", // Read-Only
        .prop_type = .optional_node,
        .prop_this = .this_node,
    },

    .{
        .name = "lastChild",
        .zig_func_name = "z.lastChild",
        .kind = .property,
        .getter = "z.lastChild",
        .setter = "", // Read-Only
        .prop_type = .optional_node,
        .prop_this = .this_node,
    },
    .{
        .name = "firstElementChild",
        .kind = .property,
        .getter = "z.firstElementChild",
        .setter = "",
        .prop_type = .optional_element, // Returns ?*HTMLElement
        .prop_this = .this_node, // [FIX] Available on Document, Fragment, and Element
    },
    .{
        .name = "nextElementSibling",
        .kind = .property,
        .getter = "z.nextElementSibling",
        .setter = "", // Read-Only
        .prop_type = .optional_element,
        .prop_this = .this_element,
    },
    .{
        .name = "lastElementChild",
        .kind = .property,
        .getter = "z.lastElementChild",
        .setter = "", // Read-Only
        .prop_type = .optional_element,
        .prop_this = .this_element,
    },
    .{
        .name = "className",
        .kind = .property,
        .getter = "z.className",
        .setter = "z.setClassName",
        .prop_type = .string_zc,
        .prop_this = .this_element,
    },
    .{
        .name = "namespaceURI",
        .kind = .property,
        .getter = "z.namespaceURI_zc",
        .setter = "", // Read-Only
        .prop_type = .string_zc,
        .prop_this = .this_element,
    },
    .{
        .name = "classList",
        .kind = .property,
        .getter = "", // Generator handles it
        .setter = "", // Read-only property (the list itself is read-only, content is mutable)
        .prop_type = .dom_token_list, // <--- Triggers our new template
        .prop_this = .this_element,
    },
    .{
        .name = "dataset",
        .kind = .property,
        .getter = "", // Generator handles it via exotic methods
        .setter = "", // Read-only (the map itself, content is mutable via proxy)
        .prop_type = .dom_string_map, // <--- Triggers DOMStringMap template
        .prop_this = .this_element,
    },
    // .{
    //     .name = "children",
    //     .kind = .property,
    //     .getter = "z.children",
    //     .setter = "", // Read-Only
    //     .prop_type = .element_list, <--- Not yet implemented
    //     .prop_this = .this_element,
    // },
    .{
        .name = "disabled",
        .kind = .boolean_attribute,
        .zig_func_name = "", // Not needed, uses generic logic
        .args = &.{}, // Not needed
        .return_type = .void_type, // Not needed
    },
    .{
        .name = "hidden",
        .kind = .boolean_attribute,
        .zig_func_name = "",
        .args = &.{},
        .return_type = .void_type,
    },
    .{
        .name = "checked", // TODO !! normally for <input> elements only!
        .kind = .boolean_attribute,
        .zig_func_name = "",
        .args = &.{},
        .return_type = .void_type,
    },
    .{ .name = "id", .kind = .string_attribute },
    .{ .name = "title", .kind = .string_attribute },
    .{ .name = "lang", .kind = .string_attribute },
    .{ .name = "dir", .kind = .string_attribute },
    .{ .name = "role", .kind = .string_attribute },
    .{ .name = "nonce", .kind = .string_attribute },
    .{
        .name = "outerHTML",
        .kind = .property,
        .getter = "z.outerHTML",
        .setter = "z.setOuterHTMLSimple",
        .prop_type = .error_string,
        .prop_this = .this_element,
    },
    // Add more bindings: 'id', 'className', 'children', etc.
};
