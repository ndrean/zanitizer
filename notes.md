# Notes

**Update lexbor**:

```sh
git submodule update --remote vendor/lexbor_src_master
```

**Leaks**: lexbor + Zig

```sh
MallocStackLogging=1 leaks -atExit -- cat dirty.html | ./zig-out/bin/zan -
```

**search in `lexbor` built static**: to check if primitives are exported, you can use:

```sh
nm vendor/lexbor_src_master/build/liblexbor_static.a | grep " T " | grep -i "serialize"
```

Directly in the source code:

```sh
find vendor/lexbor_src_master/source -name "*.h" | xargs grep -l "lxb_html_seralize_tree_cb"

grep -r "lxb_html_serialize_tree_cb" vendor/lexbor_src_master/source/lexbor/
```