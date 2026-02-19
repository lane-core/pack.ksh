#!/bin/ksh
# Bug: Discipline functions defined on compound-associative arrays
# are silently accepted but never invoked.
#
# Expected: DISC_TEST.set should fire when subscripts are assigned
# Actual: Definition succeeds, but .set is never called
#
# Tested on: ksh93u+m 93u+m/1.1.0-alpha 2026-02-09

# Control: discipline on a simple compound variable (this works)
typeset -C SIMPLE=(val=0)
typeset -i simple_fired=0
function SIMPLE.set {
    (( simple_fired++ ))
}
SIMPLE.val=42
print "Simple compound discipline fired: $simple_fired time(s)"
# Expected: 1 (or more — ksh93 may fire on subfield sets)

# Bug case: discipline on compound-associative array
typeset -C -A COMPOUND
typeset -i compound_fired=0
function COMPOUND.set {
    (( compound_fired++ ))
}
COMPOUND[x]=(val=1)
COMPOUND[y]=(val=2)
COMPOUND[x].val=99
print "Compound-associative discipline fired: $compound_fired time(s)"
# Expected: 3 (or more)
# Actual: 0

if (( compound_fired == 0 )); then
    print ""
    print "BUG: .set discipline on typeset -C -A never fires"
    print "The function definition is silently accepted but has no effect"
fi
