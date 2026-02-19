#!/bin/ksh
# Bug: typeset combined with compound-associative field expansion
# crashes under set -o nounset.
#
# Expected: typeset var="${REG[key].field}" should work identically to
#   typeset var; var="${REG[key].field}"
#
# Actual: "typeset: : invalid variable name" error under nounset
#
# Tested on: ksh93u+m 93u+m/1.1.0-alpha 2026-02-09

set -o nounset

typeset -C -A REG
REG[foo]=(path="/tmp" source="http://example.com" branch="main")

# This works fine:
print "Test 1: split declaration + assignment"
typeset val1
val1="${REG[foo].path}"
print "  val1=$val1"  # /tmp

# This crashes with "typeset: : invalid variable name"
print "Test 2: combined typeset + compound field expansion"
typeset val2="${REG[foo].path}"
print "  val2=$val2"  # never reached

print "DONE"
